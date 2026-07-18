-- SAML 連携設定。テナント単位で外部 IdP メタデータを永続化する。
--
-- テーブルオプション（ENGINE / CHARSET / COLLATE）は他の全テーブル（0001 baseline 以降）と一致させる。
-- これを省くとサーバ既定の照合順序で作成され、`tenants(id)`（utf8mb4_unicode_ci）を参照する外部キーが
-- 照合順序不一致で errno 150（Foreign key constraint is incorrectly formed）になり CREATE 自体が失敗する。
-- 時刻列は UTC の DATETIME(6)（CLAUDE.md「DB モデリング」）。
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
