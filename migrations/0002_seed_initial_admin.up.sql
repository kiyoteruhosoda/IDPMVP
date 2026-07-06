-- マスタデータ: 初期管理ユーザー（設計仕様 §3.1）。
-- 「変更前提のデフォルト値」として seed する。初回ログイン後にパスワードを変更する運用
-- （手順は docs/OPERATIONS.md「初期管理ユーザーのパスワードを変更したいとき」）。
--
-- 単一の出所はこの seed マイグレーション自身とする（値を他所へ重複させない）。
-- 冪等 upsert: 固定 id / sub / email で INSERT し、既存時は何もしない（ON DUPLICATE KEY UPDATE id=id）。
--   → 既に管理者がパスワードを変更していても、再適用で初期値へ戻さない。
--
-- password_hash はアプリと同一の Argon2id（PHC 文字列）。既定パスワードは 'ChangeMe!123'。
--   ※ 平文はコードに保持しない。既定値は上記手順書にのみ記載する。
INSERT INTO users (
    id, sub, email, email_verified, preferred_username, name, password_hash, status
) VALUES (
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-0000000000a1',
    'admin@example.com',
    1,
    'admin',
    'Administrator',
    '$argon2id$v=19$m=65536,t=3,p=4$rDuN4UZ1uO9aCuJjci4tQw$9qhizRUIJntV/0+5fsyfdKt5Xmjw6WyEmPOLkOhY7QM',
    'ACTIVE'
)
ON DUPLICATE KEY UPDATE id = id;
