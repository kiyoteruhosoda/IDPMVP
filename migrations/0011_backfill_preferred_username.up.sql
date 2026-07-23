-- ログイン識別子を preferred_username に統一（ADR-0009 §8）。従来 NULL 許容だった preferred_username を
-- 既存ユーザーについて email と同値で埋め、ログイン（preferred_username 照合）を継続できるようにする。
-- 新規作成時の既定値化（未指定なら email）はアプリ層（register / user_management）で実施する。
-- 冪等: 既に非 NULL の行は対象外。(tenant_id, preferred_username) UNIQUE は email がテナント内一意のため衝突しない。
UPDATE users
SET    preferred_username = email
WHERE  preferred_username IS NULL;
