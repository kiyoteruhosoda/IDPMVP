-- SAML 連携設定。テナント単位で外部 IdP メタデータを永続化する。
-- テーブルオプションは他テーブルと同じ utf8mb4_unicode_ci を明示する（省略するとサーバ既定の
-- 照合になり、tenants.id との照合不一致で外部キーが errno 150 で作成できない）。
-- entity_id は SAML 2.0 の推奨上限 1024 文字を格納しつつ、utf8mb4 では 4 バイト/文字で
-- InnoDB の索引キー上限 3072 バイトを超えるため、一意性は先頭 700 文字のプレフィックスで担保する。
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
        UNIQUE (tenant_id, entity_id(700)),
    INDEX idx_saml_identity_providers_tenant (tenant_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
