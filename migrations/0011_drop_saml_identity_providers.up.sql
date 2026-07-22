-- 外部 IdP 連携（本プロダクトが SP として外部 SAML IdP に依存する機能）を廃止する。
-- 純粋な IdP は他 IdP に依存しない方針のため、`saml_identity_providers`（0008）を削除する。
-- SP（クライアント）登録は `saml_service_providers`（0010）で別途管理する。
DROP TABLE IF EXISTS saml_identity_providers;
