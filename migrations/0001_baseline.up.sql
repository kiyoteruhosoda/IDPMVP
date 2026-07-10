-- ベースライン: マルチテナント対応 OIDC IdP の全テーブル（ADR-0009。設計仕様 docs/OIDC_INPUT.md §3, §7）。
-- MariaDB 10.11。方針:
--   * DB ネイティブ ENUM は使わず VARCHAR + CHECK 制約（許可値は Rust 側 enum で集中管理）。
--   * UUID は CHAR(36)。エンティティ主キーは UUIDv7（時刻順序型。ADR-0009 §12）、
--     揮発トークン類（jti / correlation_id 等）は v4 のまま。
--   * 時刻は UTC の DATETIME(6)、配列は JSON。
--   * 既定照合は utf8mb4_unicode_ci（大小無視）。理由:
--       - CITEXT 相当（email / preferred_username）の大小無視一意性を満たす。
--       - redirect_uri / PKCE / state / nonce / client_id 等の「完全一致」が要る比較はすべて
--         アプリ層（Rust）で厳密比較しており、DB 照合には依存しない。
--       - DB キーとして引く識別子（code_hash / session_hash は SHA-256 の小文字 16 進、
--         auth_sessions.id は小文字 16 進トークン、kid も小文字系）は大小のゆらぎが無いため
--         ci でも bin と同一に振る舞う。
--     ※ _bin / ascii_bin 照合は sqlx が VARBINARY として扱い String へデコードできないため使わない。
--   * マルチテナント（ADR-0009）:
--       - テナントは独立した管理境界（Entra ID 型）。root は「parent_tenant_id IS NULL の唯一の行」
--         として構造的に識別し、固定 UUID リテラルには依存しない（seed が動的採番する）。
--       - users.tenant_id は所属元（ホーム）テナント。一意制約は (tenant_id, email) 等の
--         テナント内一意とし、テナントを跨いだ同一値を許容する。
--       - client_id もテナント内一意のため、client_id を参照する子テーブルは
--         (tenant_id, client_id) の複合外部キーで参照する。
--       - MariaDB に RLS はなく、テナント分離はアプリ層が防御線（ADR-0009 §8）。DB 側は
--         外部キーと一意制約で「構造として越境できない」部分のみを担保する。

-- 1. Tenants（ADR-0009 §1）
CREATE TABLE tenants (
    id               CHAR(36)     NOT NULL COMMENT 'UUIDv7。root も含めシード/アプリが動的採番する',
    parent_tenant_id CHAR(36)     NULL
        COMMENT '作成元テナント。NULL は root テナントのみ。系譜であり管理権限の境界ではない',
    name             VARCHAR(255) NOT NULL COMMENT '表示名。一意制約なし・URL には使わない',
    status           VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    -- root（parent_tenant_id IS NULL）を DB レベルで 1 行に限定するための番兵列。
    -- root のとき 1、それ以外は NULL。UNIQUE は複数 NULL を許容するため root だけが一意化される。
    -- 式が (x IS NULL) OR NULL なのは、MariaDB 10.11 が索引付き生成列で IF()/CASE を
    -- 許可しない（ERROR 1901）ため。TRUE OR NULL = 1 / FALSE OR NULL = NULL で同じ値になる。
    is_root          TINYINT(1)   GENERATED ALWAYS AS ((parent_tenant_id IS NULL) OR NULL) VIRTUAL,
    created_at       DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at       DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY tenants_single_root_uk (is_root),
    KEY tenants_parent_idx (parent_tenant_id),
    CONSTRAINT tenants_status_chk CHECK (status IN ('ACTIVE', 'DISABLED')),
    CONSTRAINT tenants_parent_fk FOREIGN KEY (parent_tenant_id)
        REFERENCES tenants (id) ON DELETE RESTRICT
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 2. Users（設計仕様 §3.1 + ADR-0009 §2・§5）
CREATE TABLE users (
    id                   CHAR(36)     NOT NULL COMMENT 'UUIDv7',
    tenant_id            CHAR(36)     NOT NULL COMMENT '所属元（ホーム）テナント。常に 1 つ・変更不可',
    sub                  CHAR(36)     NOT NULL,
    email                VARCHAR(320) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    email_verified       TINYINT(1)   NOT NULL DEFAULT 0,
    preferred_username   VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL,
    name                 VARCHAR(255) NULL,
    password_hash        VARCHAR(255) NOT NULL,
    -- 自動生成パスワードで作成されたユーザーへ付与。初回ログイン時にパスワード変更へ強制誘導する
    -- （ADR-0009 §5。誘導の実装はアプリ層）。
    must_change_password TINYINT(1)   NOT NULL DEFAULT 0,
    status               VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    failed_login_count   INT          NOT NULL DEFAULT 0,
    locked_until         DATETIME(6)  NULL,
    created_at           DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at           DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- sub はトークン（ID Token / access token）の主体識別子のため全テナントで一意。
    UNIQUE KEY users_sub_uk (sub),
    -- email / preferred_username はテナント内一意（テナント跨ぎの同一値は許容。ADR-0009 §2）。
    -- preferred_username は NULL 許容。MariaDB の UNIQUE は複数 NULL を許容するため
    -- 通常の UNIQUE 索引で PostgreSQL の部分 UNIQUE 索引を代替できる。
    UNIQUE KEY users_tenant_email_uk (tenant_id, email),
    UNIQUE KEY users_tenant_preferred_username_uk (tenant_id, preferred_username),
    CONSTRAINT users_status_chk CHECK (status IN ('ACTIVE', 'DISABLED', 'LOCKED')),
    CONSTRAINT users_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE RESTRICT
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 3. Clients（設計仕様 §3.2 + ADR-0009 §2。logout 関連 URI は設計仕様 §9.3）
CREATE TABLE clients (
    id                          CHAR(36)     NOT NULL COMMENT 'UUIDv7',
    tenant_id                   CHAR(36)     NOT NULL,
    client_id                   VARCHAR(255) NOT NULL,
    client_secret_hash          VARCHAR(255) NULL,
    client_type                 VARCHAR(16)  NOT NULL,
    client_status               VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    app_name                    VARCHAR(255) NOT NULL,
    redirect_uris               JSON         NOT NULL,
    post_logout_redirect_uris   JSON         NULL,
    frontchannel_logout_uri     VARCHAR(2048) NULL,
    backchannel_logout_uri      VARCHAR(2048) NULL,
    grant_types                 JSON         NOT NULL,
    response_types              JSON         NOT NULL,
    scopes                      JSON         NOT NULL,
    token_endpoint_auth_method  VARCHAR(32)  NOT NULL,
    require_pkce                TINYINT(1)   NOT NULL DEFAULT 1,
    created_at                  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at                  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- client_id はテナント内一意（子テーブルはこの複合キーを外部キー参照する）。
    UNIQUE KEY clients_tenant_client_id_uk (tenant_id, client_id),
    CONSTRAINT clients_type_chk CHECK (client_type IN ('public', 'confidential')),
    CONSTRAINT clients_status_chk CHECK (client_status IN ('ACTIVE', 'DISABLED')),
    CONSTRAINT clients_token_auth_chk CHECK (token_endpoint_auth_method IN ('client_secret_basic', 'none')),
    CONSTRAINT clients_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE RESTRICT
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 4. TenantMemberships（招待とゲスト参加。ADR-0009 §3）
--    HOME 行はユーザー作成時に自動生成する投影（所属元の単一の出所は users.tenant_id）。
CREATE TABLE tenant_memberships (
    tenant_id             CHAR(36)    NOT NULL COMMENT '参加先テナント',
    user_id               CHAR(36)    NOT NULL,
    membership_type       VARCHAR(16) NOT NULL COMMENT 'HOME = 所属元 / GUEST = 招待による参加',
    status                VARCHAR(16) NOT NULL COMMENT 'INVITED = 招待中（未承諾） / ACTIVE',
    invited_by            CHAR(36)    NULL COMMENT '招待を作成した管理者ユーザー',
    invitation_token_hash VARCHAR(64) NULL COMMENT '招待トークンのハッシュ（INVITED の間のみ）',
    invitation_expires_at DATETIME(6) NULL,
    created_at            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (tenant_id, user_id),
    KEY tenant_memberships_user_idx (user_id),
    CONSTRAINT tenant_memberships_tenant_fk
        FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE CASCADE,
    CONSTRAINT tenant_memberships_user_fk
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
    CONSTRAINT tenant_memberships_type_chk CHECK (membership_type IN ('HOME', 'GUEST')),
    CONSTRAINT tenant_memberships_status_chk CHECK (status IN ('INVITED', 'ACTIVE'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 5. Permissions（権限コードのマスタ。許可値の単一出所 = seed マイグレーション。ADR-0006）
CREATE TABLE permissions (
    code        VARCHAR(64)  NOT NULL,
    description VARCHAR(255) NOT NULL,
    created_at  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (code)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 6. UserPermissions（利用者 ↔ 権限。scope = tenant_id。ADR-0009 §4）
--    scope は当該テナントのみに及ぶ（配下・系譜へは一切及ばない = 完全一致判定）。
--    tenant_id に DEFAULT は設けない（常に seed／アプリが明示指定する）。
CREATE TABLE user_permissions (
    user_id         CHAR(36)    NOT NULL,
    permission_code VARCHAR(64) NOT NULL,
    tenant_id       CHAR(36)    NOT NULL
        COMMENT '権限の適用範囲（scope）。当該テナントのみに及ぶ（配下へは及ばない）',
    granted_at      DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (user_id, permission_code, tenant_id),
    KEY user_permissions_code_idx (permission_code),
    KEY user_permissions_tenant_idx (tenant_id),
    CONSTRAINT user_permissions_user_fk FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE CASCADE,
    CONSTRAINT user_permissions_code_fk FOREIGN KEY (permission_code)
        REFERENCES permissions (code) ON DELETE RESTRICT,
    CONSTRAINT user_permissions_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES tenants (id) ON DELETE CASCADE
    -- CHECK（idp.system.admin の scope = root）は root UUID が動的採番のため固定リテラルでは
    -- 書けない。seed マイグレーション（0002）が解決済みの root UUID をリテラル化して付与する
    -- （ADR-0009 §4。制約名: user_permissions_system_admin_scope_chk）。
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 7. AuthSessions（/authorize 〜 /login の一時状態。tenant_id はフローを開始したテナント。ADR-0009 §8）
CREATE TABLE auth_sessions (
    -- id は 128bit 以上の推測不能なランダム値（256bit 乱数の小文字 16 進 = 64 文字を想定）。
    id                     VARCHAR(64)  NOT NULL,
    tenant_id              CHAR(36)     NOT NULL,
    client_id              VARCHAR(255) NOT NULL,
    redirect_uri           VARCHAR(2048) NOT NULL,
    scope                  JSON         NOT NULL,
    state                  VARCHAR(1024) NOT NULL,
    nonce                  VARCHAR(1024) NOT NULL,
    code_challenge         VARCHAR(255) NOT NULL,
    code_challenge_method  VARCHAR(8)   NOT NULL DEFAULT 'S256',
    authenticated_user_id  CHAR(36)     NULL,
    auth_time              DATETIME(6)  NULL,
    -- パスワード検証済み・MFA（TOTP 等）未完了の中間状態。NULL = 未検証 or MFA なし。
    password_verified_at   DATETIME(6)  NULL,
    expires_at             DATETIME(6)  NOT NULL,
    created_at             DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at             DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY auth_sessions_expires_idx (expires_at),
    KEY auth_sessions_user_idx (authenticated_user_id),
    KEY auth_sessions_tenant_client_idx (tenant_id, client_id),
    CONSTRAINT auth_sessions_ccm_chk CHECK (code_challenge_method IN ('S256')),
    CONSTRAINT auth_sessions_user_fk FOREIGN KEY (authenticated_user_id)
        REFERENCES users (id) ON DELETE SET NULL,
    -- client_id はテナント内一意のため (tenant_id, client_id) で参照する。
    CONSTRAINT auth_sessions_client_fk FOREIGN KEY (tenant_id, client_id)
        REFERENCES clients (tenant_id, client_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 8. SsoSessions（IdP の SSO ログイン状態。Cookie には session_id、DB にはその SHA-256）
--    SSO セッションはホスト単位で共有し、テナント境界はメンバーシップ検証で強制する
--    （ADR-0009 §8。ゲストは所属元でログインし参加先フローで再利用するため tenant_id を持たない）。
CREATE TABLE sso_sessions (
    session_hash         CHAR(64)     NOT NULL,
    user_id              CHAR(36)     NOT NULL,
    auth_time            DATETIME(6)  NOT NULL,
    idle_expires_at      DATETIME(6)  NOT NULL,
    absolute_expires_at  DATETIME(6)  NOT NULL,
    user_agent           VARCHAR(512) NULL,
    ip_address           VARCHAR(45)  NULL,
    created_at           DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at           DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (session_hash),
    KEY sso_sessions_user_idx (user_id),
    KEY sso_sessions_idle_idx (idle_expires_at),
    CONSTRAINT sso_sessions_user_fk FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 9. AuthorizationCodes（DB には平文ではなく SHA-256 を保存。tenant_id は発行テナント）
CREATE TABLE authorization_codes (
    code_hash              CHAR(64)     NOT NULL,
    tenant_id              CHAR(36)     NOT NULL,
    user_id                CHAR(36)     NOT NULL,
    client_id              VARCHAR(255) NOT NULL,
    redirect_uri           VARCHAR(2048) NOT NULL,
    scope                  JSON         NOT NULL,
    nonce                  VARCHAR(1024) NOT NULL,
    auth_time              DATETIME(6)  NOT NULL,
    code_challenge         VARCHAR(255) NOT NULL,
    code_challenge_method  VARCHAR(8)   NOT NULL DEFAULT 'S256',
    expires_at             DATETIME(6)  NOT NULL,
    used_at                DATETIME(6)  NULL,
    created_at             DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at             DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (code_hash),
    KEY authorization_codes_expires_idx (expires_at),
    KEY authorization_codes_user_idx (user_id),
    KEY authorization_codes_tenant_client_idx (tenant_id, client_id),
    CONSTRAINT authorization_codes_ccm_chk CHECK (code_challenge_method IN ('S256')),
    CONSTRAINT authorization_codes_user_fk FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE CASCADE,
    CONSTRAINT authorization_codes_client_fk FOREIGN KEY (tenant_id, client_id)
        REFERENCES clients (tenant_id, client_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 10. RefreshTokens（設計仕様 §9.1。token_hash = SHA-256(refresh_token)、parent_hash は rotation 用）
CREATE TABLE refresh_tokens (
    token_hash   CHAR(64)     NOT NULL,
    parent_hash  CHAR(64)     NULL,
    tenant_id    CHAR(36)     NOT NULL,
    user_id      CHAR(36)     NOT NULL,
    client_id    VARCHAR(255) NOT NULL,
    scope        JSON         NOT NULL,
    expires_at   DATETIME(6)  NOT NULL,
    revoked_at   DATETIME(6)  NULL,
    created_at   DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (token_hash),
    KEY refresh_tokens_user_idx (user_id),
    KEY refresh_tokens_parent_idx (parent_hash),
    KEY refresh_tokens_expires_idx (expires_at),
    KEY refresh_tokens_tenant_client_idx (tenant_id, client_id),
    CONSTRAINT refresh_tokens_user_fk FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE CASCADE,
    CONSTRAINT refresh_tokens_client_fk FOREIGN KEY (tenant_id, client_id)
        REFERENCES clients (tenant_id, client_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 11. ClientConsents（ユーザーがクライアント（RP）に付与した同意済み scope。設計仕様 §6）
--     client_id の大小・完全一致の検証はアプリ層で行う（ベースライン先頭の照合方針を参照）。
CREATE TABLE client_consents (
    user_id    CHAR(36)     NOT NULL,
    tenant_id  CHAR(36)     NOT NULL,
    client_id  VARCHAR(255) NOT NULL,
    scopes     JSON         NOT NULL,
    granted_at DATETIME(6)  NOT NULL,
    updated_at DATETIME(6)  NOT NULL,
    -- クライアント実体 = (tenant_id, client_id)。ユーザー × クライアント実体で 1 行（UPSERT で上書き）。
    PRIMARY KEY (user_id, tenant_id, client_id),
    KEY client_consents_tenant_client_idx (tenant_id, client_id),
    CONSTRAINT client_consents_user_fk FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE CASCADE,
    CONSTRAINT client_consents_client_fk FOREIGN KEY (tenant_id, client_id)
        REFERENCES clients (tenant_id, client_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 12. RevokedAccessTokens（RFC 7009。jti を記録して擬似的な即時失効を実現。設計仕様 §9.2）
CREATE TABLE revoked_access_tokens (
    jti        VARCHAR(64)  NOT NULL,
    revoked_at DATETIME(6)  NOT NULL,
    expires_at DATETIME(6)  NOT NULL,
    PRIMARY KEY (jti),
    KEY revoked_access_tokens_expires_idx (expires_at)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 13. SigningKeys（JWT 署名鍵。private_key_encrypted は DB 外の鍵で暗号化。テナント間で共有）
CREATE TABLE signing_keys (
    kid                    VARCHAR(128) NOT NULL,
    algorithm              VARCHAR(16)  NOT NULL DEFAULT 'RS256',
    public_key             TEXT         NOT NULL,
    private_key_encrypted  TEXT         NOT NULL,
    status                 VARCHAR(16)  NOT NULL,
    not_before             DATETIME(6)  NOT NULL,
    not_after              DATETIME(6)  NOT NULL,
    created_at             DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at             DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (kid),
    KEY signing_keys_status_idx (status),
    CONSTRAINT signing_keys_status_chk CHECK (status IN ('ACTIVE', 'RETIRED')),
    CONSTRAINT signing_keys_alg_chk CHECK (algorithm IN ('RS256', 'ES256'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 14. UserTotpSecrets（MFA: TOTP。ユーザー状態の一部 = 所属元テナントと本人のみが操作。ADR-0009 §3）
CREATE TABLE user_totp_secrets (
    user_id          CHAR(36)     NOT NULL,
    secret_encrypted TEXT         NOT NULL,
    confirmed_at     DATETIME(6)  NULL,
    created_at       DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at       DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (user_id),
    CONSTRAINT user_totp_user_fk FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 15. UserWebauthnCredentials（Passkey。RP ID はホスト単位のため、テナント分離は
--     「クレデンシャル ⇔ ユーザー ⇔ 所属元テナント」の紐付けで実現する。ADR-0009 §6）
CREATE TABLE user_webauthn_credentials (
    id            CHAR(36)     NOT NULL COMMENT 'UUIDv7',
    user_id       CHAR(36)     NOT NULL,
    -- WebAuthn credential ID（base64url エンコード）。認証レスポンスからの逆引き用。
    credential_id VARCHAR(512) NOT NULL,
    -- webauthn-rs Passkey 構造体全体（公開鍵・sign_count・back_eligible など）の JSON。
    passkey_json  MEDIUMTEXT   NOT NULL,
    -- ユーザーが付けた任意のラベル（例: "MacBook Touch ID"）。
    name          VARCHAR(255) NOT NULL DEFAULT '',
    created_at    DATETIME(6)  NOT NULL,
    last_used_at  DATETIME(6)  NULL,
    PRIMARY KEY (id),
    UNIQUE KEY user_webauthn_credential_id_uk (credential_id(255)),
    KEY user_webauthn_user_idx (user_id),
    CONSTRAINT user_webauthn_user_fk FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 16. PasskeyChallenges（登録 / 認証の begin → complete 間の一時状態）
CREATE TABLE passkey_challenges (
    id               CHAR(36)     NOT NULL,
    -- register: SSO 済みユーザーの UUID。authenticate: discoverable のため NULL 可。
    user_id          CHAR(36)     NULL,
    challenge_type   VARCHAR(20)  NOT NULL,
    -- webauthn-rs の PasskeyRegistration / DiscoverableAuthentication を JSON シリアライズした値。
    state_json       MEDIUMTEXT   NOT NULL,
    -- 認証チャレンジと OIDC フロー（AuthSession）を紐づける。register では NULL。
    auth_session_id  VARCHAR(64)  NULL,
    expires_at       DATETIME(6)  NOT NULL,
    created_at       DATETIME(6)  NOT NULL,
    PRIMARY KEY (id),
    KEY passkey_challenges_expires_idx (expires_at),
    CONSTRAINT passkey_challenges_type_chk CHECK (challenge_type IN ('register', 'authenticate'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 17. 監査ログ（構造化ログと同時に DB へ書き込む。PII は含めない。設計仕様 §7）
--     tenant_id で監査イベントをテナント単位に追跡する（ADR-0009 §8）。監査は追記専用の記録のため
--     外部キーは張らない（テナント・ユーザー削除後も行を保持する）。
CREATE TABLE audit_log (
    id              BIGINT       NOT NULL AUTO_INCREMENT,
    event_type      VARCHAR(64)  NOT NULL,
    occurred_at     DATETIME(6)  NOT NULL,
    tenant_id       CHAR(36)     NULL,
    user_id         CHAR(36)     NULL,
    client_id       VARCHAR(255) NULL,
    ip_address      VARCHAR(45)  NULL,
    user_agent      VARCHAR(512) NULL,
    result          VARCHAR(16)  NOT NULL,
    reason          VARCHAR(255) NULL,
    correlation_id  VARCHAR(64)  NOT NULL,
    PRIMARY KEY (id),
    KEY audit_log_event_idx (event_type),
    KEY audit_log_correlation_idx (correlation_id),
    KEY audit_log_occurred_idx (occurred_at),
    KEY audit_log_tenant_idx (tenant_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
