//! web の axum ルータ組立。管理コンソールは後続ステージで追加する。

use crate::correlation;
use crate::handlers::{health, login};
use crate::state::WebState;
use axum::routing::get;
use axum::Router;
use tower_http::trace::TraceLayer;

pub fn build(state: WebState) -> Router {
    Router::new()
        .route("/healthz", get(health::liveness))
        .route("/readyz", get(health::readiness))
        .route("/login", get(login::login_page).post(login::login))
        .layer(axum::middleware::from_fn(correlation::propagate))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
