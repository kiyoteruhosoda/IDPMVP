-- 0004 seed の巻き戻し。付与と権限マスタ行を削除する（0003 でテーブル自体を落とす前提の順序）。
DELETE FROM user_permissions
    WHERE user_id = '00000000-0000-0000-0000-000000000001' AND permission_code = 'idp.admin';
DELETE FROM permissions WHERE code = 'idp.admin';
