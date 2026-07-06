-- 0003 の巻き戻し。user_permissions を先に落としてから permissions を落とす（FK 依存順）。
DROP TABLE IF EXISTS user_permissions;
DROP TABLE IF EXISTS permissions;
