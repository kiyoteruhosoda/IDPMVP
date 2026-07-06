//! 監査イベント（設計仕様 §7）。構造化ログと `audit_log` テーブルの双方へ出力する。
#![allow(dead_code)]

use chrono::{DateTime, Utc};
use uuid::Uuid;

/// 監査イベント種別（設計仕様 §7）。`sso_session.terminated` は将来の Logout 用に予約。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuditEventType {
    LoginSucceeded,
    LoginFailed,
    LoginLocked,
    AuthorizationCodeIssued,
    AuthorizationCodeUsed,
    AuthorizationCodeReuseDetected,
    TokenIssued,
    ClientAuthenticationFailed,
    SsoSessionCreated,
    SsoSessionResumed,
    SsoSessionExpired,
    SsoSessionTerminated,
    /// 管理者による利用者権限の付与／剥奪（ADR-0006、設計仕様 §7）。
    UserPermissionGranted,
    UserPermissionRevoked,
    /// 管理者によるクライアント（RP）の登録・更新・シークレット再発行（設計仕様 §9.3・§7）。
    ClientRegistered,
    ClientUpdated,
    ClientSecretRotated,
}

impl AuditEventType {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::LoginSucceeded => "login.succeeded",
            Self::LoginFailed => "login.failed",
            Self::LoginLocked => "login.locked",
            Self::AuthorizationCodeIssued => "authorization_code.issued",
            Self::AuthorizationCodeUsed => "authorization_code.used",
            Self::AuthorizationCodeReuseDetected => "authorization_code.reuse_detected",
            Self::TokenIssued => "token.issued",
            Self::ClientAuthenticationFailed => "client.authentication_failed",
            Self::SsoSessionCreated => "sso_session.created",
            Self::SsoSessionResumed => "sso_session.resumed",
            Self::SsoSessionExpired => "sso_session.expired",
            Self::SsoSessionTerminated => "sso_session.terminated",
            Self::UserPermissionGranted => "user_permission.granted",
            Self::UserPermissionRevoked => "user_permission.revoked",
            Self::ClientRegistered => "client.registered",
            Self::ClientUpdated => "client.updated",
            Self::ClientSecretRotated => "client.secret_rotated",
        }
    }
}

/// 監査イベントの成否。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuditResult {
    Success,
    Failure,
}

impl AuditResult {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Failure => "failure",
        }
    }
}

/// 監査イベント 1 件。PII は含めない（ユーザー識別はハッシュ済み `user_id` のみ）。
#[derive(Debug, Clone)]
pub struct AuditEvent {
    pub event_type: AuditEventType,
    pub occurred_at: DateTime<Utc>,
    pub user_id: Option<Uuid>,
    pub client_id: Option<String>,
    pub ip_address: Option<String>,
    pub user_agent: Option<String>,
    pub result: AuditResult,
    pub reason: Option<String>,
    pub correlation_id: String,
}
