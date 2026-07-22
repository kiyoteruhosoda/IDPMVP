-- ロールバック: 外部 IdP 連携テーブルを再作成する（0008 と同一定義）。
CREATE TABLE saml_identity_providers (
    id CHAR(36) NOT NULL PRIMARY KEY,
    tenant_id CHAR(36) NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    entity_id VARCHAR(1024) NOT NULL,
    sso_url VARCHAR(2048) NOT NULL,
    x509_certificate TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME(6) NOT NULL,
    updated_at DATETIME(6) NOT NULL,
    CONSTRAINT fk_saml_identity_providers_tenant
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE,
    CONSTRAINT uq_saml_identity_providers_tenant_entity
        UNIQUE (tenant_id, entity_id),
    INDEX idx_saml_identity_providers_tenant (tenant_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
