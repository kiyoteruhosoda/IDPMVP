-- F2: Refresh Token（設計仕様 §9.1）。
-- DB には平文ではなく `token_hash = SHA-256(refresh_token)` を保存する。
-- `parent_hash` は rotation / reuse detection に使う（発行元の旧トークンの hash）。
-- `offline_access` scope を要求した認可コードフローでのみ発行する。

CREATE TABLE refresh_tokens (
    token_hash   CHAR(64)     NOT NULL,
    parent_hash  CHAR(64)     NULL,
    user_id      CHAR(36)     NOT NULL,
    client_id    VARCHAR(255) NOT NULL,
    scope        JSON         NOT NULL,
    expires_at   DATETIME(6)  NOT NULL,
    revoked_at   DATETIME(6)  NULL,
    created_at   DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (token_hash),
    KEY refresh_tokens_user_idx    (user_id),
    KEY refresh_tokens_client_idx  (client_id),
    KEY refresh_tokens_parent_idx  (parent_hash),
    KEY refresh_tokens_expires_idx (expires_at),
    CONSTRAINT refresh_tokens_user_fk   FOREIGN KEY (user_id)   REFERENCES users (id)   ON DELETE CASCADE,
    CONSTRAINT refresh_tokens_client_fk FOREIGN KEY (client_id) REFERENCES clients (client_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
