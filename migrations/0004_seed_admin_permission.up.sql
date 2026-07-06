-- マスタデータ: 権限コードの許可値（ADR-0006 §2「seed を単一の出所」）と、初期管理者への付与。
-- 冪等 upsert（ON DUPLICATE KEY UPDATE ... = ...）で再適用しても値を初期化しない。
--
-- MVP-admin は粗粒度の idp.admin から開始する。将来はこの seed へ行を追加するだけで細分化できる
-- （idp.clients:read / idp.audit:read など。スキーマ変更は不要。ADR-0006 §3）。

-- 権限コードのマスタ（許可値の単一出所）
INSERT INTO permissions (code, description) VALUES
    ('idp.admin', 'IdP management console: full administrative access')
ON DUPLICATE KEY UPDATE description = VALUES(description);

-- 初期管理者（0002_seed_initial_admin の admin@example.com）へ idp.admin を付与する。
-- 人手を介さず最初の管理者を成立させる（ADR-0006 §4）。冪等: 既存付与は granted_at を保持。
INSERT INTO user_permissions (user_id, permission_code) VALUES
    ('00000000-0000-0000-0000-000000000001', 'idp.admin')
ON DUPLICATE KEY UPDATE user_id = user_id;
