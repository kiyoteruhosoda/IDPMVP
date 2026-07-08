-- client_consents: ユーザーがクライアント（RP）に付与した同意済み scope を永続化する（F3）。
-- scopes は空白区切り文字列を JSON 配列で保存する。
-- user_id は users.id を参照し、ユーザー削除時にカスケード削除する。
-- PRIMARY KEY (user_id, client_id) でクライアントごとに 1 行のみ保持（UPSERT で上書き）。

CREATE TABLE client_consents (
    user_id    CHAR(36)     NOT NULL,
    client_id  VARCHAR(100) NOT NULL COLLATE utf8mb4_0900_as_cs,
    scopes     JSON         NOT NULL,
    granted_at DATETIME(6)  NOT NULL,
    updated_at DATETIME(6)  NOT NULL,
    PRIMARY KEY (user_id, client_id),
    CONSTRAINT fk_client_consents_user FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4;
