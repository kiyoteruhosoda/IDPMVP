-- seed の巻き戻し（開発用）。root UUID は動的採番のため、構造（parent_tenant_id IS NULL）で特定する。
SET @root := (SELECT id FROM tenants WHERE parent_tenant_id IS NULL);
SET @admin := (SELECT id FROM users WHERE tenant_id = @root AND email = 'admin@example.com');

-- seed 権限コードへの参照（permissions は ON DELETE RESTRICT）を先に取り除く。
DELETE FROM user_permissions
    WHERE permission_code IN ('idp.system.admin', 'idp.tenant.admin');

-- CHECK 制約（0002 up が PREPARE/EXECUTE で付与）を外す。
SET @chk_exists := (
    SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS
    WHERE CONSTRAINT_SCHEMA = DATABASE()
      AND TABLE_NAME = 'user_permissions'
      AND CONSTRAINT_NAME = 'user_permissions_system_admin_scope_chk');
SET @ddl := IF(@chk_exists = 1,
    'ALTER TABLE user_permissions DROP CONSTRAINT user_permissions_system_admin_scope_chk',
    'DO 0');
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

DELETE FROM permissions WHERE code IN ('idp.system.admin', 'idp.tenant.admin');

DELETE FROM tenant_memberships WHERE user_id = @admin;
DELETE FROM users WHERE id = @admin;

-- root テナント（子テナントが残っている場合は削除しない）。
DELETE FROM tenants
WHERE parent_tenant_id IS NULL
  AND id NOT IN (
      SELECT parent_tenant_id FROM (
          SELECT parent_tenant_id FROM tenants WHERE parent_tenant_id IS NOT NULL
      ) AS children);
