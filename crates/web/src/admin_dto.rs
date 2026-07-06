//! web が api の JSON 管理 API（`/admin/*`）から受け取るビューモデル（ADR-0007 §4）。
//!
//! これらは api の OpenAPI DTO（`ClientResponse` 等）と同じ JSON 形状を web 側で受けるための
//! 読み取り用構造体。api の管理 API は OpenAPI で公開される契約であり、web はその一消費者として
//! 自前のビューモデルで受ける（内部認証の真の契約は `idp-contracts` に置く）。整合は E2E で検証する。

use serde::Deserialize;

/// クライアント（RP）の公開表現（`GET /admin/clients`・`/admin/clients/{id}` の応答要素）。
#[derive(Debug, Clone, Deserialize)]
pub struct ClientView {
    pub id: String,
    pub client_id: String,
    pub client_type: String,
    pub client_status: String,
    pub app_name: String,
    pub redirect_uris: Vec<String>,
    pub grant_types: Vec<String>,
    #[allow(dead_code)]
    pub response_types: Vec<String>,
    pub scopes: Vec<String>,
    pub token_endpoint_auth_method: String,
    pub require_pkce: bool,
    pub created_at: String,
    pub updated_at: String,
}

/// 作成応答（`POST /admin/clients`）。`client_secret` は confidential のときのみ含まれる。
#[derive(Debug, Clone, Deserialize)]
pub struct ClientCreatedView {
    #[serde(flatten)]
    pub client: ClientView,
    #[serde(default)]
    pub client_secret: Option<String>,
}

/// secret 再発行応答（`POST /admin/clients/{id}/secret`）。
#[derive(Debug, Clone, Deserialize)]
pub struct ClientSecretView {
    #[allow(dead_code)]
    pub client_id: String,
    pub client_secret: String,
}

/// api のエラー応答本文（`{ "error": code, "message": msg }`）。
#[derive(Debug, Clone, Deserialize)]
pub struct ApiErrorBody {
    #[allow(dead_code)]
    pub error: String,
    pub message: String,
}
