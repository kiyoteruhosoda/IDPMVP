-- ベースラインの巻き戻し: 全テーブルを外部キー依存の逆順で削除する。
DROP TABLE IF EXISTS audit_log;
DROP TABLE IF EXISTS passkey_challenges;
DROP TABLE IF EXISTS user_webauthn_credentials;
DROP TABLE IF EXISTS user_totp_secrets;
DROP TABLE IF EXISTS signing_keys;
DROP TABLE IF EXISTS revoked_access_tokens;
DROP TABLE IF EXISTS client_consents;
DROP TABLE IF EXISTS refresh_tokens;
DROP TABLE IF EXISTS authorization_codes;
DROP TABLE IF EXISTS sso_sessions;
DROP TABLE IF EXISTS auth_sessions;
DROP TABLE IF EXISTS user_permissions;
DROP TABLE IF EXISTS permissions;
DROP TABLE IF EXISTS tenant_memberships;
DROP TABLE IF EXISTS clients;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS tenants;
