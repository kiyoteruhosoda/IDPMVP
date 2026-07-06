//! web の axum ルータ組立。管理コンソールは後続ステージで追加する。

use crate::correlation;
use crate::handlers::{admin_clients_console, admin_console, health, login};
use crate::state::WebState;
use axum::routing::{get, post};
use axum::Router;
use tower_http::trace::TraceLayer;

pub fn build(state: WebState) -> Router {
    Router::new()
        .route("/healthz", get(health::liveness))
        .route("/readyz", get(health::readiness))
        .route("/login", get(login::login_page).post(login::login))
        // 管理コンソール（ADR-0006 §6・ADR-0007 §4）。ログインはクライアント不要。
        .route(
            "/admin/console/login",
            get(admin_console::login_page).post(admin_console::login),
        )
        .route("/admin/console/logout", post(admin_console::logout))
        .route("/admin/console", get(admin_console::home))
        // クライアント（RP）管理画面。静的セグメント（new）は動的 {client_id} より優先。
        .route("/admin/console/clients", get(admin_clients_console::list))
        .route(
            "/admin/console/clients/new",
            get(admin_clients_console::new_form).post(admin_clients_console::create),
        )
        .route(
            "/admin/console/clients/{client_id}",
            get(admin_clients_console::detail),
        )
        .route(
            "/admin/console/clients/{client_id}/edit",
            get(admin_clients_console::edit_form).post(admin_clients_console::update),
        )
        .route(
            "/admin/console/clients/{client_id}/rotate-secret",
            post(admin_clients_console::rotate_secret),
        )
        .layer(axum::middleware::from_fn(correlation::propagate))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
