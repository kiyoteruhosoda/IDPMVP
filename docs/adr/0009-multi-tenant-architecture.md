# ADR-0009: マルチテナントアーキテクチャ

- **Status**: Proposed
- **Date**: 2026-07-09
- **関連**: `docs/adr/0006-admin-permission-model.md`、`docs/OIDC_INPUT.md`、`CLAUDE.md`「権限管理」「DB モデリング」

---

## Context

現状の IdP は「単一組織・単一認証ドメイン」前提で設計されており、すべてのユーザー・クライアントが
フラットな同一空間に存在する。EntraID のように複数の組織（テナント）を 1 つの IdP インスタンスで
ホストするには、以下が欠けている。

1. **テナントの概念がない** — ユーザー・クライアントを組織単位で分離する器が存在しない。
2. **管理者の粒度が粗い** — 現行の `idp.admin` は全データへのアクセスを与えており、
   特定テナントのみ管理する「テナント管理者」を表現できない。
3. **テナント間分離がアプリ層で強制されない** — リポジトリ・ユースケースにテナント境界がない。
4. **OIDC エンドポイントがテナント非対応** — `/authorize` 等がどのテナントのフローかを判別できない。

---

## Decision

### 1. テナントをファーストクラスエンティティとして新設

```sql
CREATE TABLE tenants (
    id          CHAR(36)     NOT NULL,
    slug        VARCHAR(63)  NOT NULL,   -- URL セーフ識別子（例: acme, contoso）
    name        VARCHAR(255) NOT NULL,
    status      VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    created_at  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY tenants_slug_uk (slug),
    CONSTRAINT tenants_status_chk CHECK (status IN ('ACTIVE', 'DISABLED'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
```

- `slug` は URL パスに直接使う（英小文字・数字・ハイフン、最大 63 文字）。
- 既存データ移行用に「デフォルトテナント（`slug = 'default'`）」を seed として追加する。

### 2. users・clients をテナントスコープ化

`users` / `clients` テーブルに `tenant_id CHAR(36) NOT NULL` を追加し、すべてのデータを
いずれかのテナントに帰属させる。`UNIQUE` 制約は `(tenant_id, email)` / `(tenant_id, client_id)`
へ拡張し、テナントを跨いで同一値が許容される。

| テーブル | 追加カラム | 変更する制約 |
|---|---|---|
| `users` | `tenant_id CHAR(36) NOT NULL` | `users_email_uk` → `(tenant_id, email)` / `users_preferred_username_uk` → `(tenant_id, preferred_username)` |
| `clients` | `tenant_id CHAR(36) NOT NULL` | `clients_client_id_uk` → `(tenant_id, client_id)` |

外部キー: `REFERENCES tenants(id) ON DELETE RESTRICT`

### 3. 2 層の管理者権限

既存の `user_permissions` にテナントスコープを追加する。

```sql
ALTER TABLE user_permissions
    ADD COLUMN tenant_id CHAR(36) NULL
        COMMENT 'NULL = システム全体権限、非NULL = 特定テナント内権限',
    ADD CONSTRAINT user_permissions_tenant_fk
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE,
    DROP PRIMARY KEY,
    ADD PRIMARY KEY (user_id, permission_code, tenant_id_coalesce);
-- ※ MariaDB は NULL を含む複合主キーを許容しないため
--   実装時は (user_id, permission_code, COALESCE(tenant_id, '')) または
--   tenant_id を NOT NULL にして '' を「システム全体」の番兵値とするか検討する（§8 参照）
```

> **実装方針（§8 で詳細化）**: `tenant_id = NULL` の代わりに空文字列 `''` を番兵値として使い、
> PRIMARY KEY `(user_id, permission_code, tenant_id)` で NOT NULL を維持する。
> アプリ層は `tenant_id = ''` をシステム全体権限として扱う。

権限コードの追加（seed マイグレーション）:

| コード | スコープ | 意味 |
|---|---|---|
| `idp.system.admin` | システム全体（`tenant_id = ''`） | テナント作成・削除・全テナント閲覧・システム設定 |
| `idp.tenant.admin` | テナント固有（`tenant_id = <id>`） | 自テナント内のユーザー・クライアント管理 |

既存の `idp.admin` は段階的に廃止し、移行スクリプトで `idp.system.admin` へ置換する。

### 4. OIDC エンドポイントのテナント対応（テナントプレフィクス方式）

EntraID の `/{tenant}/oauth2/v2.0/...` に倣い、テナント slug をパスに含める。

```
GET  /{tenant_slug}/.well-known/openid-configuration
GET  /{tenant_slug}/authorize
POST /{tenant_slug}/token
GET  /{tenant_slug}/userinfo
POST /{tenant_slug}/introspect
POST /{tenant_slug}/revoke
GET  /{tenant_slug}/jwks.json
```

システム管理者向けエンドポイント（テナント横断）:

```
/admin/tenants                  GET/POST          テナント一覧・作成
/admin/tenants/{tenant_id}      GET/PATCH/DELETE  テナント詳細・更新・削除
```

既存パス（`/authorize` 等）は後方互換のため一定期間リダイレクトまたは `default` テナントへの
エイリアスとして残す。

### 5. テナント解決 Middleware

axum の `from_fn` middleware として `TenantResolver` を追加する。リクエストパスの
`:tenant_slug` セグメントを検索し、`State` に `ResolvedTenant` として注入する。
テナントが存在しない・DISABLED の場合は 404 を返す。

```
Presentation (Router) → TenantResolver middleware → Handler
                              ↓
                    State<ResolvedTenant>
```

### 6. アプリ層のテナント分離強制

- すべての Repository trait のメソッドシグネチャに `tenant_id: &TenantId` を追加する。
- Application（ユースケース）は `TenantId` を保持した `TenantContext` を受け取り、
  リポジトリ呼び出しに必ず渡す。
- `RequirePerms` extractor もテナントスコープ権限の検証を担う（テナント管理者が
  他テナントへアクセスしようとすると 403）。

### 7. システム管理者専用操作の分離

`/admin/...` ルートは `RequirePerms("idp.system.admin")` で保護し、
テナント CRUD・全テナントユーザー閲覧・システム設定変更のみここで提供する。
テナント管理者は `/{tenant_slug}/admin/...` 配下（自テナント限定）を使う。

### 8. `user_permissions` の NULL 問題と番兵値設計

MariaDB では複合 PRIMARY KEY に NULL を含められない。選択肢:

| 案 | 概要 | 採用 |
|---|---|---|
| A. `tenant_id = ''`（空文字を番兵）| NOT NULL を維持。アプリ層で空文字をシステム全体と解釈 | **採用** |
| B. `tenant_id` を別テーブルに分離 | `system_permissions` / `tenant_permissions` の2テーブル | 却下（既存実装の変更が多い） |
| C. `COALESCE(tenant_id, '')` 仮想カラム + 索引 | NULL を許容しつつ索引化 | 却下（MariaDB のバージョン依存が増える） |

案 A を採用し、`tenant_id = ''` はシステム全体スコープの番兵値として定義する。
コード上は `TenantScope::System` / `TenantScope::Tenant(TenantId)` の enum で表現し、
DB への変換時に空文字列と UUID 文字列の間で変換する。

---

## 段階的実装計画（Phase 分け）

### Phase 1: データ基盤（マイグレーション）

1. `tenants` テーブル新設 + `default` テナント seed
2. `users` / `clients` に `tenant_id` 追加（DEFAULT 'default' テナント ID で既存行を移行）
3. `user_permissions` に `tenant_id` 追加（既存 `idp.admin` は `''` 番兵値へ）
4. `idp.system.admin` / `idp.tenant.admin` 権限コード追加
5. 初期管理者を `idp.system.admin`（`tenant_id = ''`）へ移行

### Phase 2: ドメイン・アプリケーション層

6. `Tenant` ドメインモデル + `TenantRepository` trait
7. `TenantContext` / `TenantScope` 値オブジェクト
8. 既存 Repository trait へ `tenant_id` 引数追加
9. 既存ユースケースの `TenantContext` 対応
10. `TenantResolver` middleware + `RequirePerms` のテナントスコープ拡張

### Phase 3: プレゼンテーション層・管理 API

11. `/{tenant_slug}/...` ルーティング
12. `/admin/tenants` CRUD API（システム管理者専用）
13. テナント管理者向け管理コンソール（自テナントのユーザー・クライアント管理）
14. 統合テスト（テナント間分離・権限境界の検証）

---

## Consequences

**Positive**

- テナントをまたいだデータ漏洩をアーキテクチャレベルで防止できる。
- 1 インスタンスで複数組織を収容でき、運用コストを削減できる。
- 権限コードのスコープ（システム全体 vs テナント固有）が明示的になる。
- ADR-0006 の permission モデルを大幅変更せずにスコープを拡張できる。

**Negative / コスト**

- 既存マイグレーション（`users`, `clients`, `user_permissions`）への破壊的変更が必要。
- すべての Repository インターフェース変更は広範囲の波及（実装量が多い）。
- テスト基盤もテナント ID を意識した設計に更新が必要。
- 後方互換エンドポイント（`/authorize` 等）の管理コストが一時的に増える。

**Alternatives considered**

- `users.tenant_id` を持たずクライアント単位でテナントを表現する:
  ユーザーが複数クライアントを持つテナントに所属しても整合性を保てない → 却下。
- テナントごとに DB スキーマ（DB 分離マルチテナント）:
  Synology DSM/Docker 環境での運用が複雑化する → MVP 範囲外として却下。
- 既存エンドポイントを変えずにリクエストパラメータでテナントを指定:
  EntraID のような URL 構造から外れ、エンドポイント識別が曖昧になる → 却下。

---

## Follow-ups

- Phase 1 完了後、`docs/OIDC_INPUT.md` のスキーマ図（§3）にテナント関係を追記する。
- テナント管理者の権限付与/剥奪を `audit_log` の `event_type` に追加する。
- 将来: テナントごとの signing key（`signing_keys` に `tenant_id` 追加）は Phase 3 以降で検討。
- 将来: テナントカスタムドメイン（`acme.idp.example.com` → `acme` テナント解決）は slug ルーティング確立後に拡張可能。
