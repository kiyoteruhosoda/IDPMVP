//! SAML 外部 IdP 設定のドメインモデル。
//!
//! SAML 連携はテナント境界に属する設定であり、Entity ID はテナント内で一意に扱う。
//! SSO URL は HTTPS を原則とし、ローカル開発用途のみ `http://localhost` / loopback を許可する。

use crate::domain::error::{DomainError, Result};
use crate::domain::tenant::TenantId;
use chrono::{DateTime, Utc};
use url::Url;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct SamlIdentityProvider {
    pub id: Uuid,
    pub tenant_id: TenantId,
    pub display_name: String,
    pub entity_id: String,
    pub sso_url: String,
    pub x509_certificate: String,
    pub enabled: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub struct NewSamlIdentityProvider {
    pub tenant_id: TenantId,
    pub display_name: String,
    pub entity_id: String,
    pub sso_url: String,
    pub x509_certificate: String,
    pub enabled: bool,
}

impl SamlIdentityProvider {
    pub fn register(id: Uuid, input: NewSamlIdentityProvider, now: DateTime<Utc>) -> Result<Self> {
        let display_name = required(input.display_name, "display_name")?;
        let entity_id = required(input.entity_id, "entity_id")?;
        let sso_url = validate_sso_url(&input.sso_url)?;
        let x509_certificate = required(input.x509_certificate, "x509_certificate")?;
        Ok(Self {
            id,
            tenant_id: input.tenant_id,
            display_name,
            entity_id,
            sso_url,
            x509_certificate,
            enabled: input.enabled,
            created_at: now,
            updated_at: now,
        })
    }
}

pub fn validate_sso_url(raw: &str) -> Result<String> {
    let trimmed = required(raw.to_string(), "sso_url")?;
    let parsed = Url::parse(&trimmed)
        .map_err(|_| DomainError::InvalidValue("sso_url must be a valid URL".to_string()))?;
    match parsed.scheme() {
        "https" => Ok(trimmed),
        "http" if is_localhost(&parsed) => Ok(trimmed),
        _ => Err(DomainError::InvalidValue(
            "sso_url must use https or localhost http".to_string(),
        )),
    }
}

fn required(value: String, field: &str) -> Result<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(DomainError::InvalidValue(format!("{field} is required")));
    }
    Ok(trimmed.to_string())
}

fn is_localhost(url: &Url) -> bool {
    matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "::1"))
}

#[cfg(test)]
mod tests {
    use super::validate_sso_url;

    #[test]
    fn rejects_http_urls_that_only_start_with_localhost() {
        assert!(validate_sso_url("http://localhost.evil.test/sso").is_err());
        assert!(validate_sso_url("http://localhost@evil.test/sso").is_err());
    }

    #[test]
    fn accepts_https_and_loopback_http() {
        assert!(validate_sso_url("https://idp.example.test/sso").is_ok());
        assert!(validate_sso_url("http://localhost:8080/sso").is_ok());
        assert!(validate_sso_url("http://127.0.0.1:8080/sso").is_ok());
    }
}
