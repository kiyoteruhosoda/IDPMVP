# ADR-0009: マルチテナントアーキテクチャ

- **Status**: Proposed
- **Date**: 2026-07-09（2026-07-09 改訂）
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
5. **管理・設定 UI が不在** — システム設定・テナント設定・ユーザー設定の画面が定義されていない。

---

## Decision

### 1. テナントをファーストクラスエンティティとして新設（階層対応）

```sql
CREATE TABLE tenants (
    id               CHAR(36)     NOT NULL,
    parent_tenant_id CHAR(36)     NULL
        COMMENT 'NULL は root テナントのみ。それ以外は必ず親テナントを持つ',
    slug             VARCHAR(63)  NOT NULL,   -- URL セーフ識別子（例: acme, contoso）
    name             VARCHAR(255) NOT NULL,
    status           VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    created_at       DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at       DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY tenants_slug_uk (slug),
    CONSTRAINT tenants_status_chk CHECK (status IN ('ACTIVE', 'DISABLED')),
    CONSTRAINT tenants_parent_fk FOREIGN KEY (parent_tenant_id)
        REFERENCES tenants(id) ON DELETE RESTRICT
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
```

**root テナント**: `slug = 'root'`、`parent_tenant_id = NULL`。これのみ NULL を許容する。
固定 UUID（`00000000-0000-0000-0000-000000000000`）を seed で挿入する。

**階層ルール**:
- root テナントは seed のみが作成する（アプリ経由では作成不可）。
- `idp.system.admin` 保有者（root テナント管理者）は任意の親テナント配下に子テナントを作成できる。
- `idp.tenant.admin` 保有者（テナント管理者）は自テナント配下にのみ子テナントを作成できる。
- テナント削除は「自テナント配下に子テナントが存在しない」かつ「子テナントにユーザー/クライアントが存在しない」場合のみ許可する（`ON DELETE RESTRICT` で DB レベルでも保護）。

### 2. users・clients をテナントスコープ化

`users` / `clients` テーブルに `tenant_id CHAR(36) NOT NULL` を追加し、すべてのデータを
いずれかのテナントに帰属させる。`UNIQUE` 制約は `(tenant_id, email)` / `(tenant_id, client_id)`
へ拡張し、テナントを跨いで同一値が許容される。

| テーブル | 追加カラム | 変更する制約 |
|---|---|---|
| `users` | `tenant_id CHAR(36) NOT NULL` | `users_email_uk` → `(tenant_id, email)` / `users_preferred_username_uk` → `(tenant_id, preferred_username)` |
| `clients` | `tenant_id CHAR(36) NOT NULL` | `clients_client_id_uk` → `(tenant_id, client_id)` |

外部キー: `REFERENCES tenants(id) ON DELETE RESTRICT`

既存の `admin@example.com` は `root` テナントに帰属させる。

### 3. 権限スコープ: root テナント ID を「システム全体」の表現に使う

空文字列番兵（旧案）は廃止する。`user_permissions.tenant_id` は常に実在するテナント ID を指す
外部キーとし、`root` テナントの UUID を「システム全体権限」の表現に使う。

```sql
ALTER TABLE user_permissions
    ADD COLUMN tenant_id CHAR(36) NOT NULL
        DEFAULT '00000000-0000-0000-0000-000000000000'
        COMMENT 'root テナント ID = システム全体権限',
    ADD CONSTRAINT user_permissions_tenant_fk
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE;
-- PRIMARY KEY は (user_id, permission_code, tenant_id) — すべて NOT NULL で問題なし
```

権限コードの追加（seed マイグレーション）:

| コード | `tenant_id` の値 | 意味 |
|---|---|---|
| `idp.system.admin` | root テナント UUID | テナント作成・削除・全テナント閲覧・システム設定 |
| `idp.tenant.admin` | 対象テナント UUID | 自テナント内のユーザー・クライアント管理、子テナント作成 |

既存の `idp.admin` は段階的に廃止し、`idp.system.admin`（tenant_id = root UUID）へ置換する。

コード上は `TenantScope::Root` / `TenantScope::Tenant(TenantId)` の enum で表現する。

### 4. テナント作成フロー

テナント作成時に必要な情報は以下の 3 点のみ:

| 入力 | 備考 |
|---|---|
| テナント名（`name`） | `slug` はシステムが name を正規化して生成（英小文字・数字・ハイフン、重複時はサフィックス付与）|
| 管理者メールアドレス | 作成と同時に `idp.tenant.admin` 権限を付与した管理者ユーザーを生成する |
| パスワード | **自動生成**（32 文字以上のランダム文字列）。レスポンスに一度だけ平文で返す |

- パスワードは argon2id でハッシュして `users.password_hash` へ保存する。
- パスワードのリセット機能は未実装（後続タスク: SMTP 連携後に実装）。
  暫定運用として、テナント作成者が API レスポンスを確認して管理者へ別途通知する。
- テナント作成 API のレスポンスには `generated_password` フィールドを含める（一度限り）。

### 5. OIDC エンドポイントのテナント対応（テナントプレフィクス方式）

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
/admin/tenants                       GET/POST          テナント一覧・作成
/admin/tenants/{tenant_id}           GET/PATCH/DELETE  テナント詳細・更新・削除
/admin/tenants/{tenant_id}/children  GET               子テナント一覧
```

既存パス（`/authorize` 等）は後方互換のため一定期間 `root` テナントへのエイリアスとして残す。

### 6. テナント解決 Middleware

axum の `from_fn` middleware として `TenantResolver` を追加する。リクエストパスの
`:tenant_slug` セグメントを検索し、`State` に `ResolvedTenant` として注入する。
テナントが存在しない・DISABLED の場合は 404 を返す。

```
Presentation (Router) → TenantResolver middleware → Handler
                              ↓
                    Extension<ResolvedTenant>
```

### 7. アプリ層のテナント分離強制

- すべての Repository trait のメソッドシグネチャに `tenant_id: &TenantId` を追加する。
- Application（ユースケース）は `TenantId` を保持した `TenantContext` を受け取り、
  リポジトリ呼び出しに必ず渡す。
- `RequirePerms` extractor もテナントスコープ権限の検証を担う（テナント管理者が
  他テナントへアクセスしようとすると 403）。

### 8. システム管理者専用操作の分離

`/admin/...` ルートは `RequirePerms("idp.system.admin")` で保護し、
テナント CRUD・全テナントユーザー閲覧・システム設定変更のみここで提供する。
テナント管理者は `/{tenant_slug}/admin/...` 配下（自テナント限定）を使う。

### 9. 管理・設定画面の構成

以下の 3 種の設定画面を定義する。

| 画面 | URL | アクセス権限 | 主な機能 |
|---|---|---|---|
| **システム設定** | `/admin/settings` | `idp.system.admin` | SMTP 設定（外部サーバー）、システム全体の設定値管理、デフォルト値の上書き |
| **テナント設定** | `/{tenant_slug}/admin/settings` | `idp.tenant.admin`（自テナント） | テナント名・スラッグ変更、テナント有効/無効、子テナント作成・管理 |
| **ユーザー設定** | `/{tenant_slug}/settings` | SSO ログイン済み（自分のみ） | パスワードリセット（SMTP 実装後）、MFA 設定（TOTP・Passkey）、言語設定、SSO アカウント連携 |

**SMTP 設定** はシステム設定画面で管理し、テナント共通の外部 SMTP サーバー接続情報を保持する。
パスワードリセット機能は SMTP 設定の完了を前提とするため、後続タスクとして分離する。

---

## 段階的実装計画（Phase 分け）

### Phase 1: データ基盤（マイグレーション）

1. `tenants` テーブル新設 + `root` テナント seed（固定 UUID `00000000-0000-0000-0000-000000000000`）
2. `users` / `clients` に `tenant_id` 追加（既存行はすべて `root` テナントへ移行）
3. `user_permissions` に `tenant_id` 追加（既存 `idp.admin` → `idp.system.admin` / tenant_id = root UUID）
4. `idp.system.admin` / `idp.tenant.admin` 権限コード seed
5. 初期管理者ユーザーを `root` テナントへ紐付け + `idp.system.admin` 付与

### Phase 2: ドメイン・アプリケーション層

6. `Tenant` ドメインモデル（階層含む）+ `TenantRepository` trait
7. `TenantContext` / `TenantScope` 値オブジェクト
8. 既存 Repository trait へ `tenant_id` 引数追加
9. 既存ユースケースの `TenantContext` 対応
10. `TenantResolver` middleware + `RequirePerms` のテナントスコープ拡張

### Phase 3: プレゼンテーション層・管理 API

11. `/{tenant_slug}/...` ルーティング + 既存パスの後方互換エイリアス（`root` テナント）
12. テナント CRUD API（`/admin/tenants`）+ テナント作成時の管理者自動生成・パスワード自動生成
13. テナント管理者向け管理コンソール（`/{tenant_slug}/admin/`）— ユーザー・クライアント・子テナント管理
14. システム設定画面（`/admin/settings`）— SMTP 等のシステム設定
15. テナント設定画面（`/{tenant_slug}/admin/settings`）
16. ユーザー設定画面（`/{tenant_slug}/settings`）— MFA・言語設定（パスワードリセットは後続）
17. 統合テスト（テナント間分離・権限境界・階層の検証）

---

## Consequences

**Positive**

- `root` テナントが実在するため、空文字列番兵が不要になり DB 整合性が自明になる。
- 階層構造により、組織のサブ部門や子会社を同一 IdP インスタンスで表現できる。
- テナントをまたいだデータ漏洩をアーキテクチャレベルで防止できる。
- テナント作成フローが完結しており、管理者が即時アクセス可能（SMTP 不要）。
- ADR-0006 の permission モデルを大幅変更せずにスコープを拡張できる。

**Negative / コスト**

- 既存マイグレーション（`users`, `clients`, `user_permissions`）への破壊的変更が必要。
- すべての Repository インターフェース変更は広範囲の波及（実装量が多い）。
- 階層の深さに制限がないため、循環参照防止・深さ上限はアプリ層で検証する必要がある。
- 後方互換エンドポイント（`/authorize` 等）の管理コストが一時的に増える。

**Alternatives considered**

- `tenant_id = ''`（空文字列番兵）でシステム全体権限を表現する:
  DB の外部キー整合性が保てず、アプリ層の変換コードが煩雑になる → 廃案（root テナント採用）。
- `users.tenant_id` を持たずクライアント単位でテナントを表現する:
  ユーザーが複数クライアントを持つテナントに所属しても整合性を保てない → 却下。
- テナントごとに DB スキーマ（DB 分離マルチテナント）:
  Synology DSM/Docker 環境での運用が複雑化する → MVP 範囲外として却下。
- 既存エンドポイントを変えずにリクエストパラメータでテナントを指定:
  EntraID のような URL 構造から外れ、エンドポイント識別が曖昧になる → 却下。

---

## Follow-ups（後続タスク）

- **パスワードリセット**: SMTP 設定完了後に実装。ユーザー設定画面に「パスワードリセット」フローを追加。
  外部 SMTP サーバーはシステム設定画面で設定する（ADR 別途）。
- **ゲスト登録 / テナント切り替え**: 別テナントのユーザーをゲストとして招待し、複数テナントに
  帰属するユーザー体験（テナント切り替え UI）。Phase 3 以降で設計する。
- Phase 1 完了後、`docs/OIDC_INPUT.md` のスキーマ図（§3）にテナント関係を追記する。
- テナント管理者の権限付与/剥奪を `audit_log` の `event_type` に追加する。
- 将来: テナントごとの signing key（`signing_keys` に `tenant_id` 追加）は Phase 3 以降で検討。
- 将来: テナントカスタムドメイン（`acme.idp.example.com` → `acme` テナント解決）は slug ルーティング確立後に拡張可能。
