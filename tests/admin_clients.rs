//! クライアント（RP）登録・管理 API の E2E 統合テスト（Progress A1、設計仕様 §9.3）。
//!
//! `TEST_DATABASE_URL` 設定時のみ実行:
//!   TEST_DATABASE_URL='mysql://idp:idp@127.0.0.1:3306/idp' cargo test --test admin_clients
//!
//! 認可は `RequirePerms<IdpAdmin>`。初期管理者（seed 0002 + 0004 で idp.admin 付与済み）の
//! SSO セッションを直接作成し、その Cookie で管理 API を叩く。権限の無い利用者は 403 になることも検証する。

use axum::body::Body;
use axum::http::header::{CONTENT_TYPE, COOKIE};
use axum::http::{Request, StatusCode};
use idp::config::Config;
use idp::domain::clock::Clock;
use idp::infrastructure::crypto;
use idp::presentation::router;
use idp::presentation::state::AppState;
use serde_json::{json, Value};
use sqlx::mysql::MySqlPoolOptions;
use sqlx::MySqlPool;
use std::sync::Arc;
use tower::ServiceExt;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// seed 0002 の初期管理者 id（seed 0004 で idp.admin を付与済み）。
const ADMIN_ID: &str = "00000000-0000-0000-0000-000000000001";
const REDIRECT_URI: &str = "https://app.example.com/callback";

struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> chrono::DateTime<chrono::Utc> {
        chrono::Utc::now()
    }
}

struct TestEnv {
    app: axum::Router,
    pool: MySqlPool,
}

async fn setup() -> Option<TestEnv> {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL not set; skipping admin clients integration test");
        return None;
    };
    let pool = MySqlPoolOptions::new()
        .connect(&url)
        .await
        .expect("connect to test database");
    MIGRATOR.run(&pool).await.expect("run migrations");

    let config = Arc::new(Config::from_env().expect("load config"));
    let state = AppState::build(pool.clone(), config, Arc::new(SystemClock));
    Some(TestEnv {
        app: router::build(state),
        pool,
    })
}

/// 指定ユーザーの有効な SSO セッションを作成し、Cookie 用の平文 session_id を返す。
async fn create_sso_session(pool: &MySqlPool, user_id: &str) -> String {
    let session_id = crypto::random_hex(32);
    let session_hash = crypto::sha256_hex(&session_id);
    sqlx::query(
        "INSERT INTO sso_sessions \
         (session_hash, user_id, auth_time, idle_expires_at, absolute_expires_at) \
         VALUES (?, ?, UTC_TIMESTAMP(6), \
                 DATE_ADD(UTC_TIMESTAMP(6), INTERVAL 1 HOUR), \
                 DATE_ADD(UTC_TIMESTAMP(6), INTERVAL 8 HOUR))",
    )
    .bind(&session_hash)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("insert sso session");
    session_id
}

async fn send(app: &axum::Router, request: Request<Body>) -> axum::response::Response {
    app.clone().oneshot(request).await.expect("send request")
}

async fn body_json(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("read body");
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

fn admin_post(cookie: &str, uri: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header(CONTENT_TYPE, "application/json")
        .header(COOKIE, format!("sso_session_id={cookie}"))
        .body(Body::from(body.to_string()))
        .unwrap()
}

#[tokio::test]
async fn admin_can_manage_clients_but_others_cannot() {
    let Some(env) = setup().await else {
        return;
    };
    let admin_cookie = create_sso_session(&env.pool, ADMIN_ID).await;

    // 未認証（Cookie 無し）→ 401。
    let res = send(
        &env.app,
        Request::builder()
            .method("POST")
            .uri("/admin/clients")
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(json!({}).to_string()))
            .unwrap(),
    )
    .await;
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED, "no cookie -> 401");

    // 権限の無い利用者 → 403。
    let plain_user_id = uuid::Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO users (id, sub, email, email_verified, password_hash, status) \
         VALUES (?, ?, ?, 1, 'x', 'ACTIVE')",
    )
    .bind(&plain_user_id)
    .bind(uuid::Uuid::new_v4().to_string())
    .bind(format!("plain-{}@example.com", &plain_user_id[..8]))
    .execute(&env.pool)
    .await
    .expect("insert plain user");
    let plain_cookie = create_sso_session(&env.pool, &plain_user_id).await;
    let res = send(
        &env.app,
        admin_post(
            &plain_cookie,
            "/admin/clients",
            json!({
                "app_name": "X",
                "client_type": "public",
                "redirect_uris": [REDIRECT_URI],
                "scopes": ["openid"],
            }),
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::FORBIDDEN, "no permission -> 403");

    // バリデーション: フラグメント付き redirect_uri → 400。
    let res = send(
        &env.app,
        admin_post(
            &admin_cookie,
            "/admin/clients",
            json!({
                "app_name": "Bad",
                "client_type": "public",
                "redirect_uris": ["https://app.example.com/cb#frag"],
                "scopes": ["openid"],
            }),
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::BAD_REQUEST, "fragment uri -> 400");

    // public クライアント登録 → 201・secret 無し。
    let res = send(
        &env.app,
        admin_post(
            &admin_cookie,
            "/admin/clients",
            json!({
                "app_name": "Public App",
                "client_type": "public",
                "redirect_uris": [REDIRECT_URI],
                "scopes": ["openid", "profile"],
            }),
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::CREATED, "public create -> 201");
    let created = body_json(res).await;
    let public_client_id = created["client_id"].as_str().unwrap().to_string();
    assert!(
        created.get("client_secret").is_none(),
        "public has no secret"
    );
    assert_eq!(created["token_endpoint_auth_method"], "none");

    // public のシークレット再発行 → 400。
    let res = send(
        &env.app,
        Request::builder()
            .method("POST")
            .uri(format!("/admin/clients/{public_client_id}/secret"))
            .header(COOKIE, format!("sso_session_id={admin_cookie}"))
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "public secret -> 400"
    );

    // confidential クライアント登録 → 201・secret 平文あり。
    let res = send(
        &env.app,
        admin_post(
            &admin_cookie,
            "/admin/clients",
            json!({
                "app_name": "Confidential App",
                "client_type": "confidential",
                "redirect_uris": [REDIRECT_URI],
                "scopes": ["openid"],
            }),
        ),
    )
    .await;
    assert_eq!(
        res.status(),
        StatusCode::CREATED,
        "confidential create -> 201"
    );
    let created = body_json(res).await;
    let conf_client_id = created["client_id"].as_str().unwrap().to_string();
    let first_secret = created["client_secret"]
        .as_str()
        .expect("confidential returns secret")
        .to_string();
    assert!(!first_secret.is_empty());
    assert_eq!(created["token_endpoint_auth_method"], "client_secret_basic");

    // 一覧に両クライアントが含まれる。
    let res = send(
        &env.app,
        Request::builder()
            .method("GET")
            .uri("/admin/clients")
            .header(COOKIE, format!("sso_session_id={admin_cookie}"))
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(res.status(), StatusCode::OK);
    let list = body_json(res).await;
    let ids: Vec<&str> = list
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["client_id"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&public_client_id.as_str()));
    assert!(ids.contains(&conf_client_id.as_str()));

    // 更新: status を DISABLED に。
    let res = send(
        &env.app,
        Request::builder()
            .method("PATCH")
            .uri(format!("/admin/clients/{public_client_id}"))
            .header(CONTENT_TYPE, "application/json")
            .header(COOKIE, format!("sso_session_id={admin_cookie}"))
            .body(Body::from(
                json!({ "client_status": "DISABLED" }).to_string(),
            ))
            .unwrap(),
    )
    .await;
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["client_status"], "DISABLED");

    // confidential のシークレット再発行 → 200・新しい値（旧値と異なる）。
    let res = send(
        &env.app,
        Request::builder()
            .method("POST")
            .uri(format!("/admin/clients/{conf_client_id}/secret"))
            .header(COOKIE, format!("sso_session_id={admin_cookie}"))
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(res.status(), StatusCode::OK);
    let rotated = body_json(res).await["client_secret"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(!rotated.is_empty());
    assert_ne!(rotated, first_secret, "rotation changes the secret");

    // 不存在の取得 → 404。
    let res = send(
        &env.app,
        Request::builder()
            .method("GET")
            .uri("/admin/clients/does-not-exist")
            .header(COOKIE, format!("sso_session_id={admin_cookie}"))
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(res.status(), StatusCode::NOT_FOUND, "missing client -> 404");
}
