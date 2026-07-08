//! web が受け取るフォーム DTO。

use serde::Deserialize;

/// ログインフォーム（`POST /login`）。
#[derive(Debug, Deserialize)]
pub struct LoginForm {
    pub username: String,
    pub password: String,
    pub csrf_token: String,
}

/// 同意フォーム（`POST /consent`、F3）。
#[derive(Debug, Deserialize)]
pub struct ConsentForm {
    pub auth_session_id: String,
    pub csrf_token: String,
    /// `approve` または `deny`。
    pub action: String,
}
