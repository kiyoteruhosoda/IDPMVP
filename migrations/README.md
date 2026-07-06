# migrations

sqlx マイグレーション（MariaDB）を管理する。

- ファイル名: `<version>_<description>.sql`（reversible 運用時は `.up.sql` / `.down.sql` を対で用意）。
- `version` は sqlx が採番する連番（タイムスタンプ）。この version が
  スキーマ・マスタデータのバージョン整合性の SSOT（`_sqlx_migrations` テーブル）。
- 適用: `sqlx migrate run`（アプリ起動時には**適用しない**。起動時は「DB が期待 version 以上か」を
  照合するのみ ＝ fail-fast。詳細は `docs/adr/0004-schema-version-sync.md`）。
- 規約: DB ネイティブ ENUM 禁止（`VARCHAR` + `CHECK`）、UUID は `CHAR(36)`、時刻は UTC の `DATETIME(6)`。
  詳細は `.claude/skills/db-migration/` と `CLAUDE.md`「DB モデリング」を参照。

- マスタデータ（初期管理ユーザー等）も冪等 upsert のマイグレーションとして書く。単一の出所は
  当該 seed マイグレーション自身とし、値を他所へ重複させない（`.claude/skills/db-migration/` 参照）。

現行のマイグレーション:

- `0001_baseline`: 全テーブル（users / clients / auth_sessions / sso_sessions /
  authorization_codes / signing_keys / audit_log）。
- `0002_seed_initial_admin`: 初期管理ユーザー（`admin@example.com`）の seed。「変更前提のデフォルト値」
  として冪等 upsert。既定パスワードの変更手順は `docs/OPERATIONS.md`。
- `0003_permissions_and_user_permissions`: 利用者権限モデル（ADR-0006）。`permissions`（権限コードの
  マスタ）と `user_permissions`（利用者↔権限の多対多）を追加。OIDC scope とは別軸の内部認可。
- `0004_seed_admin_permission`: 権限コード `idp.admin` の seed と、初期管理者への冪等付与。
