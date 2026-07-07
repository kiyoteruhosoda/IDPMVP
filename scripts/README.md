# scripts/

運用・ビルド・検証をワンコマンド化したシェルスクリプト群。すべてリポジトリルートからの相対パスに
依存せず、どのディレクトリから実行しても動く（各スクリプトが自身の位置からリポジトリルートを解決する）。

| スクリプト | 用途 | 単体実行 |
|---|---|---|
| `init.sh` | 初回セットアップ（`.env` 生成 → DB 起動 → マイグレーション → api/web/proxy 起動）。冪等。 | ○ |
| `build.sh` | リリース成果物のビルド（ネイティブ binary または Docker イメージ）。 | ○ |
| `deploy.sh` | 同一ホストの Docker Compose へデプロイ（ビルド → マイグレーション → 再起動 → readiness 確認）。 | ○ |
| `e2e.sh` | web→api の疎通 E2E（api・web を実プロセス起動して HTTP で検証）。 | ○ |
| `lib.sh` | 上記が共有するヘルパ（ログ・Compose コマンド判定・`.env` 操作・healthy 待ち）。 | ✗（`source` 専用） |

前提となるツールは各スクリプトのヘッダコメントに記載している。

---

## init.sh — 初回セットアップ

```bash
./scripts/init.sh
```

- `.env` が無ければ `.env.example` を基に生成し、秘密情報（DB パスワード・`KEY_ENCRYPTION_KEY`・
  `INTERNAL_SERVICE_TOKEN`）を乱数生成する。**既存の `.env` は上書きしない**（冪等）。
- MariaDB を起動し、マイグレーション（DDL + マスタデータ）を専用ジョブ（`docker compose run --rm migrate`）で
  適用し、api・web・proxy を起動する。
- 完了後、ログイン/管理コンソール・Swagger UI の URL と初期管理ユーザーを表示する。

前提: `docker`（Compose v2）と `openssl`。

## build.sh — ビルド

```bash
./scripts/build.sh            # ネイティブ release binary（target/release/idp・idp-web）
./scripts/build.sh --check    # fmt チェック・clippy（-D warnings）・test を実行してからビルド
./scripts/build.sh --docker   # Docker イメージ（api / web / migrate）を compose でビルド
./scripts/build.sh --check --docker
./scripts/build.sh --help
```

| オプション | 効果 |
|---|---|
| （なし） | `cargo build --release --locked --bin idp --bin idp-web` |
| `--docker` | `docker compose build api web migrate` |
| `--check` | ビルド前に `cargo fmt --check` → `cargo clippy -D warnings` → `cargo test` |

前提: ネイティブビルドは `cargo`（rustup）。Docker ビルドは `docker`（Compose v2）。

## deploy.sh — デプロイ

```bash
./scripts/deploy.sh
```

1. イメージビルド（api / web / migrate）
2. DDL + マスタデータ適用（`sqlx migrate run` を単独ジョブで実行）
3. api・web・proxy を再起動（`docker compose up -d`）
4. `/readyz`（プロキシ経由 = api の readiness）で起動確認

**前提: 事前に `init.sh` を実行済み（`.env` が存在する）こと。** ロールバック方針はスクリプト冒頭の
コメントおよび `docs/OPERATIONS.md`「ロールバックしたいとき」を参照。

## e2e.sh — 疎通 E2E

```bash
TEST_DATABASE_URL='mysql://idp:idp@127.0.0.1:3306/idp' ./scripts/e2e.sh
```

api（DB 直結）と web（HTML 画面）を実際に別プロセスで起動し、ブラウザ相当の HTTP で
「OIDC 認可コードフロー（web ログイン経由）」と「管理コンソール（web→api JSON 管理 API）」を検証する。

前提: MariaDB が起動しマイグレーション適用済み（初期管理ユーザー seed 済み）。既定 DB は
`mysql://idp:idp@127.0.0.1:3306/idp`（`TEST_DATABASE_URL` で上書き可）。テスト用クライアント投入に
`docker exec idp-test-db` を使うため、対応する MariaDB コンテナが必要。

---

## 典型的な流れ

```bash
# 1. 初回セットアップ（.env 生成・DB・マイグレーション・起動）
./scripts/init.sh

# 2. 変更後、検証してからビルド
./scripts/build.sh --check

# 3. デプロイ（イメージ再ビルド・マイグレーション・再起動・readiness 確認）
./scripts/deploy.sh
```

CI/ローカルでの疎通確認が必要なときは `./scripts/e2e.sh` を追加で実行する。
