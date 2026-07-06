-- 利用者権限モデル（ADR-0006）。OIDC scope（claim 制御）とは別軸の「利用者権限」。
-- 権限コードはマスタテーブルで管理し（許可値の単一出所 = seed マイグレーション）、
-- DB ネイティブ ENUM も CHECK 列挙も使わない（追加のたびに ALTER が要るため。CLAUDE.md「DB モデリング」）。

-- 権限コードのマスタ（許可値の単一出所 = seed マイグレーション 0004）
CREATE TABLE permissions (
    code        VARCHAR(64)  NOT NULL,
    description VARCHAR(255) NOT NULL,
    created_at  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (code)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- 利用者 ↔ 権限（多対多）
CREATE TABLE user_permissions (
    user_id         CHAR(36)     NOT NULL,
    permission_code VARCHAR(64)  NOT NULL,
    granted_at      DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (user_id, permission_code),
    KEY user_permissions_code_idx (permission_code),
    CONSTRAINT user_permissions_user_fk FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE CASCADE,
    CONSTRAINT user_permissions_code_fk FOREIGN KEY (permission_code)
        REFERENCES permissions (code) ON DELETE RESTRICT
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
