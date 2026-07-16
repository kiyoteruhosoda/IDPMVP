-- SAML 連携設定。テナント単位で外部 IdP メタデータを永続化する。
CREATE TABLE saml_identity_providers (
    id CHAR(36) NOT NULL PRIMARY KEY,
    tenant_id CHAR(36) NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    entity_id VARCHAR(1024) NOT NULL,
    sso_url VARCHAR(2048) NOT NULL,
    x509_certificate TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    CONSTRAINT fk_saml_identity_providers_tenant
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE,
    CONSTRAINT uq_saml_identity_providers_tenant_entity
        UNIQUE (tenant_id, entity_id),
    INDEX idx_saml_identity_providers_tenant (tenant_id)
);
