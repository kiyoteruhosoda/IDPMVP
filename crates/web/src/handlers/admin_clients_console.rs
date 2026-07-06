//! クライアント（RP）管理のサーバレンダリング画面（web。ADR-0007 §4）。
//!
//! api の JSON 管理 API（`/admin/clients*`、`RequirePerms<IdpAdmin>`）を管理者の SSO Cookie 転送で呼び、
//! 結果を HTML に描画する。認可・データ操作・監査は api 側。web は画面と CSRF（`console_csrf_token`）のみ。
//! 利用者入力を HTML へ差し込む箇所はすべて [`escape`] を通す。`client_secret` は作成・再発行時に
//! その画面でのみ平文表示する。

use crate::admin_dto::{ClientCreatedView, ClientView};
use crate::api_client::AdminApiError;
use crate::cookies;
use crate::correlation::CorrelationId;
use crate::csrf::console_csrf_token;
use crate::handlers::admin_console::{
    forbidden_response, redirect_to_login, render_layout, resolve_admin, AdminResolution,
};
use crate::handlers::found;
use crate::html::escape;
use crate::i18n::{Locale, Messages};
use crate::state::WebState;
use axum::extract::{Extension, Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::Form;
use serde::Deserialize;
use serde_json::json;

const CLIENTS_PATH: &str = "/admin/console/clients";

/// 各ハンドラ冒頭の共通前処理: 管理者を解決し、user_id を返すか誘導 Response を返す。
macro_rules! admin_or_return {
    ($state:expr, $correlation:expr, $headers:expr) => {
        match resolve_admin($state, $correlation, $headers).await {
            AdminResolution::Ok(uid) => uid,
            AdminResolution::Reject(resp) => return resp,
        }
    };
}

// ── 一覧 ──────────────────────────────────────────────────────────────────────

pub async fn list(
    State(state): State<WebState>,
    Extension(correlation): Extension<CorrelationId>,
    headers: HeaderMap,
) -> Response {
    let admin = admin_or_return!(&state, &correlation, &headers);
    let result = state.api.list_clients(&correlation.0, &sso(&headers)).await;
    let messages = Messages::new(locale(&headers));
    match result {
        Ok(clients) => Html(render_list(&messages, &admin, &clients)).into_response(),
        Err(e) => map_data_error(&messages, &admin, &headers, e),
    }
}

// ── 新規登録フォーム ──────────────────────────────────────────────────────────

pub async fn new_form(
    State(state): State<WebState>,
    Extension(correlation): Extension<CorrelationId>,
    headers: HeaderMap,
) -> Response {
    let admin = admin_or_return!(&state, &correlation, &headers);
    let messages = Messages::new(locale(&headers));
    let csrf = csrf_from(&headers);
    Html(render_new_form(
        &messages,
        &admin,
        &csrf,
        &FormValues::default_new(),
        None,
    ))
    .into_response()
}

// ── 新規登録の実行 ────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct NewClientForm {
    pub app_name: String,
    pub client_type: String,
    pub redirect_uris: String,
    pub scopes: String,
    #[serde(default)]
    pub require_pkce: Option<String>,
    pub csrf_token: String,
}

pub async fn create(
    State(state): State<WebState>,
    Extension(correlation): Extension<CorrelationId>,
    headers: HeaderMap,
    Form(form): Form<NewClientForm>,
) -> Response {
    let admin = admin_or_return!(&state, &correlation, &headers);
    let values = FormValues {
        app_name: form.app_name.clone(),
        client_type: form.client_type.clone(),
        redirect_uris: form.redirect_uris.clone(),
        scopes: form.scopes.clone(),
        require_pkce: form.require_pkce.is_some(),
        client_status: "ACTIVE".to_string(),
    };

    // Messages（FluentBundle）は Send でないため、api の await をまたいで保持しない（login.rs と同じ理由）。
    if !csrf_valid(&headers, &form.csrf_token) {
        let messages = Messages::new(locale(&headers));
        let csrf = csrf_from(&headers);
        return bad_request_form(render_new_form(
            &messages,
            &admin,
            &csrf,
            &values,
            Some("admin-error-csrf"),
        ));
    }

    let body = json!({
        "app_name": form.app_name,
        "client_type": form.client_type,
        "redirect_uris": parse_uris(&form.redirect_uris),
        "scopes": parse_scopes(&form.scopes),
        "require_pkce": form.require_pkce.is_some(),
    });
    let result = state
        .api
        .create_client(&correlation.0, &sso(&headers), body)
        .await;
    let messages = Messages::new(locale(&headers));
    let csrf = csrf_from(&headers);
    match result {
        Ok(created) => {
            Html(render_secret_result(&messages, &admin, &created, true)).into_response()
        }
        Err(AdminApiError::Validation(m)) | Err(AdminApiError::Conflict(m)) => {
            bad_request_form(render_new_form_with_message(&messages, &admin, &csrf, &values, &m))
        }
        Err(e) => map_data_error(&messages, &admin, &headers, e),
    }
}

// ── 詳細 ──────────────────────────────────────────────────────────────────────

pub async fn detail(
    State(state): State<WebState>,
    Extension(correlation): Extension<CorrelationId>,
    headers: HeaderMap,
    Path(client_id): Path<String>,
) -> Response {
    let admin = admin_or_return!(&state, &correlation, &headers);
    let result = state
        .api
        .get_client(&correlation.0, &sso(&headers), &client_id)
        .await;
    let messages = Messages::new(locale(&headers));
    let csrf = csrf_from(&headers);
    match result {
        Ok(client) => Html(render_detail(&messages, &admin, &client, &csrf)).into_response(),
        Err(AdminApiError::NotFound) => not_found(&messages, &admin),
        Err(e) => map_data_error(&messages, &admin, &headers, e),
    }
}

// ── 編集フォーム ──────────────────────────────────────────────────────────────

pub async fn edit_form(
    State(state): State<WebState>,
    Extension(correlation): Extension<CorrelationId>,
    headers: HeaderMap,
    Path(client_id): Path<String>,
) -> Response {
    let admin = admin_or_return!(&state, &correlation, &headers);
    let result = state
        .api
        .get_client(&correlation.0, &sso(&headers), &client_id)
        .await;
    let messages = Messages::new(locale(&headers));
    let csrf = csrf_from(&headers);
    match result {
        Ok(client) => {
            let values = FormValues::from_client(&client);
            Html(render_edit_form(
                &messages, &admin, &client, &csrf, &values, None,
            ))
            .into_response()
        }
        Err(AdminApiError::NotFound) => not_found(&messages, &admin),
        Err(e) => map_data_error(&messages, &admin, &headers, e),
    }
}

// ── 編集の実行 ────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct EditClientForm {
    pub app_name: String,
    pub redirect_uris: String,
    pub scopes: String,
    pub client_status: String,
    pub csrf_token: String,
}

pub async fn update(
    State(state): State<WebState>,
    Extension(correlation): Extension<CorrelationId>,
    headers: HeaderMap,
    Path(client_id): Path<String>,
    Form(form): Form<EditClientForm>,
) -> Response {
    let admin = admin_or_return!(&state, &correlation, &headers);

    // 再表示に備え、現行 client を取得する（種別など読み取り専用表示のため）。ClientView は Send。
    let client = match state
        .api
        .get_client(&correlation.0, &sso(&headers), &client_id)
        .await
    {
        Ok(c) => c,
        Err(AdminApiError::NotFound) => {
            let messages = Messages::new(locale(&headers));
            return not_found(&messages, &admin);
        }
        Err(e) => {
            let messages = Messages::new(locale(&headers));
            return map_data_error(&messages, &admin, &headers, e);
        }
    };
    let mut values = FormValues::from_client(&client);
    values.app_name = form.app_name.clone();
    values.redirect_uris = form.redirect_uris.clone();
    values.scopes = form.scopes.clone();
    values.client_status = form.client_status.clone();

    if !csrf_valid(&headers, &form.csrf_token) {
        let messages = Messages::new(locale(&headers));
        let csrf = csrf_from(&headers);
        let err = messages.get("admin-error-csrf");
        return bad_request_form(render_edit_form(
            &messages, &admin, &client, &csrf, &values, Some(err),
        ));
    }

    let body = json!({
        "app_name": form.app_name,
        "redirect_uris": parse_uris(&form.redirect_uris),
        "scopes": parse_scopes(&form.scopes),
        "client_status": form.client_status,
    });
    let result = state
        .api
        .update_client(&correlation.0, &sso(&headers), &client_id, body)
        .await;
    let messages = Messages::new(locale(&headers));
    let csrf = csrf_from(&headers);
    match result {
        Ok(_) => found(&format!("{CLIENTS_PATH}/{client_id}")),
        Err(AdminApiError::NotFound) => not_found(&messages, &admin),
        Err(AdminApiError::Validation(m)) | Err(AdminApiError::Conflict(m)) => {
            bad_request_form(render_edit_form(
                &messages, &admin, &client, &csrf, &values, Some(m),
            ))
        }
        Err(e) => map_data_error(&messages, &admin, &headers, e),
    }
}

// ── secret 再発行 ─────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct CsrfForm {
    pub csrf_token: String,
}

pub async fn rotate_secret(
    State(state): State<WebState>,
    Extension(correlation): Extension<CorrelationId>,
    headers: HeaderMap,
    Path(client_id): Path<String>,
    Form(form): Form<CsrfForm>,
) -> Response {
    let admin = admin_or_return!(&state, &correlation, &headers);

    if !csrf_valid(&headers, &form.csrf_token) {
        let messages = Messages::new(locale(&headers));
        return bad_request_page(&messages, &admin, "admin-error-csrf");
    }
    let rotated = state
        .api
        .rotate_client_secret(&correlation.0, &sso(&headers), &client_id)
        .await;
    match rotated {
        Ok(secret) => {
            // 再発行結果は詳細を取り直して表示する（ClientView は Send）。
            let client = state
                .api
                .get_client(&correlation.0, &sso(&headers), &client_id)
                .await;
            let messages = Messages::new(locale(&headers));
            match client {
                Ok(client) => Html(render_rotated_result(
                    &messages,
                    &admin,
                    &client,
                    &secret.client_secret,
                ))
                .into_response(),
                Err(e) => map_data_error(&messages, &admin, &headers, e),
            }
        }
        Err(AdminApiError::Validation(m)) => {
            let messages = Messages::new(locale(&headers));
            bad_request_page_msg(&messages, &admin, &m)
        }
        Err(AdminApiError::NotFound) => {
            let messages = Messages::new(locale(&headers));
            not_found(&messages, &admin)
        }
        Err(e) => {
            let messages = Messages::new(locale(&headers));
            map_data_error(&messages, &admin, &headers, e)
        }
    }
}

// ── フォームの共通表現・パース ────────────────────────────────────────────────

struct FormValues {
    app_name: String,
    client_type: String,
    redirect_uris: String,
    scopes: String,
    require_pkce: bool,
    client_status: String,
}

impl FormValues {
    fn default_new() -> Self {
        Self {
            app_name: String::new(),
            client_type: "confidential".to_string(),
            redirect_uris: String::new(),
            scopes: "openid".to_string(),
            require_pkce: true,
            client_status: "ACTIVE".to_string(),
        }
    }

    fn from_client(c: &ClientView) -> Self {
        Self {
            app_name: c.app_name.clone(),
            client_type: c.client_type.clone(),
            redirect_uris: c.redirect_uris.join("\n"),
            scopes: c.scopes.join(" "),
            require_pkce: c.require_pkce,
            client_status: c.client_status.clone(),
        }
    }
}

fn parse_uris(raw: &str) -> Vec<String> {
    raw.split_whitespace().map(str::to_string).collect()
}

fn parse_scopes(raw: &str) -> Vec<String> {
    raw.split([' ', '\t', '\n', '\r', ','])
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

// ── CSRF ─────────────────────────────────────────────────────────────────────

fn sso(headers: &HeaderMap) -> String {
    cookies::get(headers, cookies::SSO_SESSION_COOKIE).unwrap_or_default()
}

fn csrf_from(headers: &HeaderMap) -> String {
    cookies::get(headers, cookies::SSO_SESSION_COOKIE)
        .map(|s| console_csrf_token(&s))
        .unwrap_or_default()
}

fn csrf_valid(headers: &HeaderMap, submitted: &str) -> bool {
    cookies::get(headers, cookies::SSO_SESSION_COOKIE)
        .map(|s| console_csrf_token(&s) == submitted)
        .unwrap_or(false)
}

// ── レンダリング ──────────────────────────────────────────────────────────────

fn render_list(messages: &Messages, admin: &str, clients: &[ClientView]) -> String {
    let heading = escape(&messages.get("admin-clients-title"));
    let new_label = escape(&messages.get("admin-clients-new"));
    let body = if clients.is_empty() {
        format!("<p>{}</p>", escape(&messages.get("admin-clients-none")))
    } else {
        let rows: String = clients
            .iter()
            .map(|c| {
                format!(
                    "<tr><td><a href=\"{path}/{id}\">{name}</a></td><td><code>{id}</code></td>\
                     <td>{ctype}</td><td>{status}</td><td>{scopes}</td></tr>",
                    path = CLIENTS_PATH,
                    id = escape(&c.client_id),
                    name = escape(&c.app_name),
                    ctype = escape(&c.client_type),
                    status = escape(&c.client_status),
                    scopes = escape(&c.scopes.join(" ")),
                )
            })
            .collect();
        format!(
            "<table>\n<thead><tr><th>{name}</th><th>{id}</th><th>{ctype}</th><th>{status}</th><th>{scopes}</th></tr></thead>\n\
             <tbody>{rows}</tbody></table>",
            name = escape(&messages.get("admin-client-col-name")),
            id = escape(&messages.get("admin-client-col-id")),
            ctype = escape(&messages.get("admin-client-col-type")),
            status = escape(&messages.get("admin-client-col-status")),
            scopes = escape(&messages.get("admin-client-col-scopes")),
        )
    };
    let content = format!(
        "<h2>{heading}</h2>\n<p><a href=\"{path}/new\">{new_label}</a></p>\n{body}",
        path = CLIENTS_PATH,
    );
    render_layout(messages, Some(admin), &content)
}

fn render_new_form(
    messages: &Messages,
    admin: &str,
    csrf: &str,
    values: &FormValues,
    error_key: Option<&str>,
) -> String {
    let error = error_key.map(|k| messages.get(k));
    render_client_form(
        messages,
        admin,
        csrf,
        values,
        error.as_deref(),
        &messages.get("admin-clients-new"),
        &format!("{CLIENTS_PATH}/new"),
        true,
    )
}

fn render_new_form_with_message(
    messages: &Messages,
    admin: &str,
    csrf: &str,
    values: &FormValues,
    error: &str,
) -> String {
    render_client_form(
        messages,
        admin,
        csrf,
        values,
        Some(error),
        &messages.get("admin-clients-new"),
        &format!("{CLIENTS_PATH}/new"),
        true,
    )
}

fn render_edit_form(
    messages: &Messages,
    admin: &str,
    client: &ClientView,
    csrf: &str,
    values: &FormValues,
    error: Option<String>,
) -> String {
    render_client_form(
        messages,
        admin,
        csrf,
        values,
        error.as_deref(),
        &format!("{}: {}", messages.get("admin-client-edit"), client.app_name),
        &format!("{CLIENTS_PATH}/{}/edit", client.client_id),
        false,
    )
}

#[allow(clippy::too_many_arguments)]
fn render_client_form(
    messages: &Messages,
    admin: &str,
    csrf: &str,
    values: &FormValues,
    error: Option<&str>,
    heading: &str,
    action: &str,
    is_new: bool,
) -> String {
    let error_html = error
        .map(|e| format!("<p class=\"error\" role=\"alert\">{}</p>", escape(e)))
        .unwrap_or_default();

    let type_field = if is_new {
        format!(
            "<label>{label}<br>\n<select name=\"client_type\">\n\
             <option value=\"confidential\"{c}>confidential</option>\n\
             <option value=\"public\"{p}>public</option>\n</select></label>",
            label = escape(&messages.get("admin-client-field-type")),
            c = selected(values.client_type == "confidential"),
            p = selected(values.client_type == "public"),
        )
    } else {
        format!(
            "<p>{label}: <code>{value}</code></p>",
            label = escape(&messages.get("admin-client-field-type")),
            value = escape(&values.client_type),
        )
    };

    let pkce_field = if is_new {
        format!(
            "<label><input type=\"checkbox\" name=\"require_pkce\"{checked}> {label}</label>\
             <small>{hint}</small>",
            checked = if values.require_pkce { " checked" } else { "" },
            label = escape(&messages.get("admin-client-field-pkce")),
            hint = escape(&messages.get("admin-client-field-pkce-hint")),
        )
    } else {
        String::new()
    };

    let status_field = if is_new {
        String::new()
    } else {
        format!(
            "<label>{label}<br>\n<select name=\"client_status\">\n\
             <option value=\"ACTIVE\"{a}>ACTIVE</option>\n\
             <option value=\"DISABLED\"{d}>DISABLED</option>\n</select></label>",
            label = escape(&messages.get("admin-client-field-status")),
            a = selected(values.client_status == "ACTIVE"),
            d = selected(values.client_status == "DISABLED"),
        )
    };

    let content = format!(
        "<h2>{heading}</h2>\n{error_html}\n\
         <form method=\"post\" action=\"{action}\">\n\
         <input type=\"hidden\" name=\"csrf_token\" value=\"{csrf}\">\n\
         <p><label>{name_label}<br>\n<input type=\"text\" name=\"app_name\" value=\"{app_name}\" required></label></p>\n\
         <p>{type_field}</p>\n\
         <p><label>{uris_label}<br>\n<textarea name=\"redirect_uris\" rows=\"4\" cols=\"60\">{uris}</textarea></label><br><small>{uris_hint}</small></p>\n\
         <p><label>{scopes_label}<br>\n<input type=\"text\" name=\"scopes\" value=\"{scopes}\"></label><br><small>{scopes_hint}</small></p>\n\
         <p>{status_field}</p>\n\
         <p>{pkce_field}</p>\n\
         <p><button type=\"submit\">{submit}</button> <a href=\"{path}\">{cancel}</a></p>\n\
         </form>",
        heading = escape(heading),
        csrf = escape(csrf),
        name_label = escape(&messages.get("admin-client-field-name")),
        app_name = escape(&values.app_name),
        uris_label = escape(&messages.get("admin-client-field-uris")),
        uris = escape(&values.redirect_uris),
        uris_hint = escape(&messages.get("admin-client-field-uris-hint")),
        scopes_label = escape(&messages.get("admin-client-field-scopes")),
        scopes = escape(&values.scopes),
        scopes_hint = escape(&messages.get("admin-client-field-scopes-hint")),
        submit = escape(&messages.get("admin-form-save")),
        cancel = escape(&messages.get("admin-form-cancel")),
        path = CLIENTS_PATH,
    );
    render_layout(messages, Some(admin), &content)
}

fn render_detail(messages: &Messages, admin: &str, client: &ClientView, csrf: &str) -> String {
    let rotate = if client.client_type == "confidential" {
        format!(
            "<form method=\"post\" action=\"{path}/{id}/rotate-secret\">\
             <input type=\"hidden\" name=\"csrf_token\" value=\"{csrf}\">\
             <button type=\"submit\">{label}</button></form>",
            path = CLIENTS_PATH,
            id = escape(&client.client_id),
            csrf = escape(csrf),
            label = escape(&messages.get("admin-client-rotate-secret")),
        )
    } else {
        String::new()
    };

    let content = format!(
        "<h2>{name}</h2>\n\
         <dl>\n\
         <dt>{id_label}</dt><dd><code>{id}</code></dd>\n\
         <dt>{type_label}</dt><dd>{ctype}</dd>\n\
         <dt>{status_label}</dt><dd>{status}</dd>\n\
         <dt>{auth_label}</dt><dd>{auth}</dd>\n\
         <dt>{pkce_label}</dt><dd>{pkce}</dd>\n\
         <dt>{uris_label}</dt><dd>{uris}</dd>\n\
         <dt>{scopes_label}</dt><dd>{scopes}</dd>\n\
         <dt>{grant_label}</dt><dd>{grants}</dd>\n\
         <dt>{created_label}</dt><dd>{created}</dd>\n\
         <dt>{updated_label}</dt><dd>{updated}</dd>\n\
         </dl>\n\
         <p><a href=\"{path}/{id}/edit\">{edit}</a> | <a href=\"{path}\">{back}</a></p>\n\
         {rotate}",
        name = escape(&client.app_name),
        id_label = escape(&messages.get("admin-client-col-id")),
        id = escape(&client.client_id),
        type_label = escape(&messages.get("admin-client-col-type")),
        ctype = escape(&client.client_type),
        status_label = escape(&messages.get("admin-client-col-status")),
        status = escape(&client.client_status),
        auth_label = escape(&messages.get("admin-client-field-auth-method")),
        auth = escape(&client.token_endpoint_auth_method),
        pkce_label = escape(&messages.get("admin-client-field-pkce")),
        pkce = if client.require_pkce { "true" } else { "false" },
        uris_label = escape(&messages.get("admin-client-field-uris")),
        uris = render_list_items(&client.redirect_uris),
        scopes_label = escape(&messages.get("admin-client-col-scopes")),
        scopes = escape(&client.scopes.join(" ")),
        grant_label = escape(&messages.get("admin-client-field-grants")),
        grants = escape(&client.grant_types.join(" ")),
        created_label = escape(&messages.get("admin-client-field-created")),
        created = escape(&client.created_at),
        updated_label = escape(&messages.get("admin-client-field-updated")),
        updated = escape(&client.updated_at),
        path = CLIENTS_PATH,
        edit = escape(&messages.get("admin-client-edit")),
        back = escape(&messages.get("admin-client-back")),
        rotate = rotate,
    );
    render_layout(messages, Some(admin), &content)
}

fn render_secret_result(
    messages: &Messages,
    admin: &str,
    created: &ClientCreatedView,
    is_new: bool,
) -> String {
    render_secret_page(
        messages,
        admin,
        &created.client.client_id,
        created.client_secret.as_deref(),
        is_new,
    )
}

fn render_rotated_result(
    messages: &Messages,
    admin: &str,
    client: &ClientView,
    secret: &str,
) -> String {
    render_secret_page(messages, admin, &client.client_id, Some(secret), false)
}

fn render_secret_page(
    messages: &Messages,
    admin: &str,
    client_id: &str,
    secret: Option<&str>,
    is_new: bool,
) -> String {
    let heading = if is_new {
        messages.get("admin-client-created-title")
    } else {
        messages.get("admin-client-secret-rotated-title")
    };
    let secret_html = match secret {
        Some(s) => format!(
            "<p class=\"secret-warning\">{warn}</p>\n<p>{label}: <code>{secret}</code></p>",
            warn = escape(&messages.get("admin-client-secret-warning")),
            label = escape(&messages.get("admin-client-secret-label")),
            secret = escape(s),
        ),
        None => format!("<p>{}</p>", escape(&messages.get("admin-client-no-secret"))),
    };
    let content = format!(
        "<h2>{heading}</h2>\n\
         <p>{id_label}: <code>{id}</code></p>\n\
         {secret_html}\n\
         <p><a href=\"{path}/{id}\">{detail}</a> | <a href=\"{path}\">{back}</a></p>",
        heading = escape(&heading),
        id_label = escape(&messages.get("admin-client-col-id")),
        id = escape(client_id),
        path = CLIENTS_PATH,
        detail = escape(&messages.get("admin-client-detail")),
        back = escape(&messages.get("admin-client-back")),
    );
    render_layout(messages, Some(admin), &content)
}

fn render_list_items(items: &[String]) -> String {
    if items.is_empty() {
        return "-".to_string();
    }
    let lis: String = items
        .iter()
        .map(|i| format!("<li><code>{}</code></li>", escape(i)))
        .collect();
    format!("<ul>{lis}</ul>")
}

// ── レスポンスの共通ヘルパー ──────────────────────────────────────────────────

fn selected(on: bool) -> &'static str {
    if on {
        " selected"
    } else {
        ""
    }
}

fn locale(headers: &HeaderMap) -> Locale {
    Locale::from_accept_language(
        headers
            .get(header::ACCEPT_LANGUAGE)
            .and_then(|v| v.to_str().ok()),
    )
}

/// api の 401/403 を web の画面挙動へ写す（ログイン誘導 / 403 画面）。それ以外は 500。
fn map_data_error(messages: &Messages, admin: &str, headers: &HeaderMap, e: AdminApiError) -> Response {
    match e {
        AdminApiError::Unauthorized => redirect_to_login(),
        AdminApiError::Forbidden => forbidden_response(headers),
        AdminApiError::NotFound => not_found(messages, admin),
        other => {
            tracing::error!(error = ?debug_error(&other), "admin client console data error");
            let content = format!(
                "<p class=\"error\" role=\"alert\">{}</p>",
                escape(&messages.get("admin-error-internal"))
            );
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Html(render_layout(messages, Some(admin), &content)),
            )
                .into_response()
        }
    }
}

fn debug_error(e: &AdminApiError) -> String {
    match e {
        AdminApiError::Validation(m) => format!("validation: {m}"),
        AdminApiError::Conflict(m) => format!("conflict: {m}"),
        AdminApiError::Transport(m) => format!("transport: {m}"),
        AdminApiError::NotFound => "not_found".into(),
        AdminApiError::Unauthorized => "unauthorized".into(),
        AdminApiError::Forbidden => "forbidden".into(),
    }
}

fn bad_request_form(html: String) -> Response {
    (StatusCode::BAD_REQUEST, Html(html)).into_response()
}

fn bad_request_page(messages: &Messages, admin: &str, error_key: &str) -> Response {
    bad_request_page_msg(messages, admin, &messages.get(error_key))
}

fn bad_request_page_msg(messages: &Messages, admin: &str, message: &str) -> Response {
    let content = format!(
        "<p class=\"error\" role=\"alert\">{}</p>\n<p><a href=\"{path}\">{back}</a></p>",
        escape(message),
        path = CLIENTS_PATH,
        back = escape(&messages.get("admin-client-back")),
    );
    (
        StatusCode::BAD_REQUEST,
        Html(render_layout(messages, Some(admin), &content)),
    )
        .into_response()
}

fn not_found(messages: &Messages, admin: &str) -> Response {
    let content = format!(
        "<h2>{title}</h2>\n<p>{msg}</p>\n<p><a href=\"{path}\">{back}</a></p>",
        title = escape(&messages.get("admin-client-not-found-title")),
        msg = escape(&messages.get("admin-client-not-found-message")),
        path = CLIENTS_PATH,
        back = escape(&messages.get("admin-client-back")),
    );
    (
        StatusCode::NOT_FOUND,
        Html(render_layout(messages, Some(admin), &content)),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_uris_splits_and_drops_blanks() {
        let raw = "https://a.example.com/cb\n  https://b.example.com/cb \n\n";
        assert_eq!(
            parse_uris(raw),
            vec![
                "https://a.example.com/cb".to_string(),
                "https://b.example.com/cb".to_string()
            ]
        );
        assert!(parse_uris("   \n  ").is_empty());
    }

    #[test]
    fn parse_scopes_splits_on_space_and_comma() {
        assert_eq!(
            parse_scopes("openid, profile  email"),
            vec![
                "openid".to_string(),
                "profile".to_string(),
                "email".to_string()
            ]
        );
    }

    #[test]
    fn list_escapes_client_fields() {
        let messages = Messages::new(Locale::En);
        let client = ClientView {
            id: "id".into(),
            client_id: "abc123".into(),
            client_type: "public".into(),
            client_status: "ACTIVE".into(),
            app_name: "<script>Evil</script>".into(),
            redirect_uris: vec!["https://a.example.com/cb".into()],
            grant_types: vec!["authorization_code".into()],
            response_types: vec!["code".into()],
            scopes: vec!["openid".into()],
            token_endpoint_auth_method: "none".into(),
            require_pkce: true,
            created_at: "2026-07-06T00:00:00Z".into(),
            updated_at: "2026-07-06T00:00:00Z".into(),
        };
        let html = render_list(&messages, "admin-1", &[client]);
        assert!(html.contains("&lt;script&gt;Evil&lt;/script&gt;"));
        assert!(!html.contains("<script>Evil"));
    }
}
