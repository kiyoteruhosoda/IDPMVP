# Progress

進行中・未着手タスクのみを管理する（完了したら本ファイルから削除し、必要なら `CHANGELOG.md` / `history/` へ）。

## バックログ

| 優先 | # | 概要 | 状態 | 影響度 | 工数 |
|---|---|---|---|---|---|
| 1 | MT1 | `tenants` テーブル新設（階層対応）+ `root` テナント seed | ⬜未着手 | 大 | 小 |
| 2 | MT2 | `users` / `clients` に `tenant_id` 追加（既存行を `root` テナントへ移行） | ⬜未着手 | 大 | 中 |
| 3 | MT3 | `user_permissions` に `tenant_id` 追加（root テナント UUID = システム全体）+ 新権限コード seed | ⬜未着手 | 大 | 小 |
| 4 | MT4 | `Tenant` ドメインモデル（階層）+ `TenantRepository` trait + `TenantContext`/`TenantScope` 値オブジェクト | ⬜未着手 | 大 | 中 |
| 5 | MT5 | 既存 Repository trait / ユースケースへ `tenant_id` 引数追加（テナント分離強制） | ⬜未着手 | 大 | 大 |
| 6 | MT6 | `TenantResolver` middleware + `RequirePerms` のテナントスコープ拡張 | ⬜未着手 | 大 | 中 |
| 7 | MT7 | `/{tenant_slug}/...` ルーティング + 既存パスの後方互換エイリアス（`root` テナント） | ⬜未着手 | 大 | 中 |
| 8 | MT8 | テナント CRUD API（`/admin/tenants`）+ テナント作成時の管理者自動生成・パスワード自動生成 | ⬜未着手 | 中 | 中 |
| 9 | MT9 | テナント管理コンソール（`/{tenant_slug}/admin/`）— ユーザー・クライアント・子テナント管理 | ⬜未着手 | 中 | 大 |
| 10 | MT10 | システム設定画面（`/admin/settings`）— SMTP 等のシステム設定 | ⬜未着手 | 中 | 中 |
| 11 | MT11 | テナント設定画面（`/{tenant_slug}/admin/settings`） | ⬜未着手 | 中 | 小 |
| 12 | MT12 | ユーザー設定画面（`/{tenant_slug}/settings`）— MFA・言語設定（パスワードリセットは後続） | ⬜未着手 | 中 | 中 |
| 13 | MT13 | テナント間分離・権限境界・階層の統合テスト | ⬜未着手 | 大 | 中 |
| 14 | MT14 | パスワードリセット（外部 SMTP 連携。MT10 の SMTP 設定完了後） | ⬜未着手 | 中 | 中 |
| 15 | MT15 | ゲスト登録・テナント切り替え（別テナントへの招待 UI） | ⬜未着手 | 中 | 大 |

### 詳細

**MT1**: `tenants(id, parent_tenant_id, slug, name, status, created_at, updated_at)` テーブル新設。
`parent_tenant_id` は自己参照 FK（NULL 許容、root のみ NULL）。
seed で `slug='root'`・`id='00000000-0000-0000-0000-000000000000'`・`parent_tenant_id=NULL` を挿入。
設計根拠: ADR-0009 §1。

**MT2**: `users` / `clients` に `tenant_id CHAR(36) NOT NULL` を追加。UNIQUE 制約を
`(tenant_id, email)` / `(tenant_id, preferred_username)` / `(tenant_id, client_id)` へ拡張。
既存行（`admin@example.com` 等）はすべて `root` テナント ID へ移行。設計根拠: ADR-0009 §2。

**MT3**: `user_permissions` に `tenant_id CHAR(36) NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'` を追加
し PRIMARY KEY を `(user_id, permission_code, tenant_id)` に再設計（全 NOT NULL で空文字番兵不要）。
権限コード `idp.system.admin`（tenant_id = root UUID）・`idp.tenant.admin`（テナント固有）を seed。
`idp.admin` を `idp.system.admin` へ置換。設計根拠: ADR-0009 §3。

**MT4–MT6**: DDD 4 層でのテナント概念実装。`TenantScope::Root` / `TenantScope::Tenant(TenantId)` enum。
`TenantContext` は axum `Extension` 経由で全ユースケースへ伝播。`TenantResolver` は `:tenant_slug`
パスセグメントを DB で解決して `Extension<ResolvedTenant>` に注入。設計根拠: ADR-0009 §4・§6・§7。

**MT7–MT9**: プレゼンテーション層。既存 `/authorize` 等は `root` テナントへのエイリアスとして後方互換を維持。
テナント作成 API は `{ name, admin_email }` を受け取りパスワードを自動生成して `generated_password` をレスポンスに含める（一度限り）。設計根拠: ADR-0009 §4・§8。

**MT10**: システム設定画面（`/admin/settings`）。外部 SMTP サーバー接続情報（host・port・user・TLS 等）、
システム全体のデフォルト設定値を管理。`idp.system.admin` 保有者のみアクセス可。設計根拠: ADR-0009 §9。

**MT12**: ユーザー設定画面はパスワードリセット以外（MFA 設定・言語設定）を先行実装し、
リセット機能は MT14（SMTP 実装後）で追加する。設計根拠: ADR-0009 §9。

**MT14**: パスワードリセット機能（メールでのトークン送付）。MT10 の SMTP 設定完了が前提。
外部 SMTP サーバーを使用する（IdP 自体は SMTP サーバーを内包しない）。

**MT15**: ゲスト登録（別テナントのユーザーを招待）・テナント切り替え UI。
ユーザーが複数テナントに帰属するシナリオを扱うため、`user_tenant_memberships` テーブルの追加等、
スキーマ設計を別途行う（ADR 追加予定）。
