# Progress

進行中・未着手タスクのみを管理する（完了したら本ファイルから削除し、必要なら `CHANGELOG.md` / `history/` へ）。

## バックログ

| 優先 | # | 概要 | 状態 | 影響度 | 工数 |
|---|---|---|---|---|---|
| 1 | MT1 | `tenants` テーブル新設 + `default` テナント seed | ⬜未着手 | 大 | 小 |
| 2 | MT2 | `users` / `clients` に `tenant_id` 追加（既存行を `default` テナントへ移行） | ⬜未着手 | 大 | 中 |
| 3 | MT3 | `user_permissions` に `tenant_id`（番兵値 `''` = システム全体）追加 + 新権限コード seed | ⬜未着手 | 大 | 小 |
| 4 | MT4 | `Tenant` ドメインモデル + `TenantRepository` trait + `TenantContext`/`TenantScope` 値オブジェクト | ⬜未着手 | 大 | 中 |
| 5 | MT5 | 既存 Repository trait / ユースケースへ `tenant_id` 引数追加（テナント分離強制） | ⬜未着手 | 大 | 大 |
| 6 | MT6 | `TenantResolver` middleware + `RequirePerms` のテナントスコープ拡張 | ⬜未着手 | 大 | 中 |
| 7 | MT7 | `/{tenant_slug}/...` ルーティング + 既存パスの後方互換エイリアス | ⬜未着手 | 大 | 中 |
| 8 | MT8 | `/admin/tenants` CRUD API（システム管理者専用） | ⬜未着手 | 中 | 中 |
| 9 | MT9 | テナント管理者向け管理コンソール（自テナントのユーザー・クライアント管理） | ⬜未着手 | 中 | 大 |
| 10 | MT10 | テナント間分離・権限境界の統合テスト | ⬜未着手 | 大 | 中 |

### 詳細

**MT1**: `tenants(id, slug, name, status, created_at, updated_at)` テーブル新設。`slug` は URL セーフ識別子（英小文字・数字・ハイフン、最大 63 文字）。seed で `slug='default'` テナントを追加する。設計根拠: ADR-0009 §1。

**MT2**: `users` / `clients` に `tenant_id CHAR(36) NOT NULL` を追加。UNIQUE 制約を `(tenant_id, email)` / `(tenant_id, preferred_username)` / `(tenant_id, client_id)` へ拡張。既存行はすべて `default` テナント ID へ移行。設計根拠: ADR-0009 §2。

**MT3**: `user_permissions` に `tenant_id VARCHAR(36) NOT NULL DEFAULT ''`（空文字 = システム全体の番兵値）を追加し PRIMARY KEY を再設計。権限コード `idp.system.admin`（システム全体）・`idp.tenant.admin`（テナント固有）を seed。初期管理者を `idp.system.admin`（`tenant_id = ''`）へ移行。設計根拠: ADR-0009 §3・§8。

**MT4–MT6**: DDD 4 層でのテナント概念実装。`TenantContext` は axum `State` 経由で全ユースケースへ伝播。`TenantResolver` は `:tenant_slug` パスセグメントを DB で解決して `Extension<ResolvedTenant>` に注入。設計根拠: ADR-0009 §4–§6。

**MT7–MT9**: プレゼンテーション層。既存 `/authorize` 等は `default` テナントへのエイリアスとして後方互換を維持。`/admin/tenants` は `idp.system.admin` 保有者のみアクセス可。テナント管理コンソール（`/{tenant_slug}/admin/`）は `idp.tenant.admin`（自テナント）保有者のみ。設計根拠: ADR-0009 §7。
