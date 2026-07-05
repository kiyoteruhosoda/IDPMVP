# OIDC IdP（Rust）マルチステージビルド。CLAUDE.md「環境要件」準拠（rust:slim ベース）。
#
# ビルド依存: ring（rustls バックエンド）が C/アセンブラをコンパイルするため C ツールチェインと
# perl が要る。TLS は rustls のため OpenSSL は不要。翻訳リソース（i18n/*.ftl）は include_str! で
# バイナリへ埋め込まれるため、実行イメージには同梱不要。

# ---- builder ----
FROM rust:slim AS builder
WORKDIR /build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential perl pkg-config \
    && rm -rf /var/lib/apt/lists/*

# 依存解決を層キャッシュに乗せる（マニフェストのみ先にコピー）。
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs \
    && cargo build --release --locked \
    && rm -rf src

# 本体をビルド。
COPY src ./src
COPY i18n ./i18n
# ダミー main のタイムスタンプより新しくして確実に再ビルドさせる。
RUN touch src/main.rs && cargo build --release --locked

# ---- migrate ----
# DDL / マスタデータ適用の専用ジョブ（sqlx migrate run）。CLAUDE.md schema-version 方針に従い、
# アプリ起動時には適用せず、この単独ジョブで適用する。Compose の migrate サービスから使う。
FROM rust:slim AS migrate
WORKDIR /migrate
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential perl pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && cargo install sqlx-cli --version ^0.8 --no-default-features --features mysql,rustls --locked
COPY migrations ./migrations
# DATABASE_URL は実行時に注入する。
ENTRYPOINT ["sqlx", "migrate", "run", "--source", "/migrate/migrations"]

# ---- runtime ----
FROM debian:bookworm-slim AS runtime
WORKDIR /app

# TLS 検証用のルート証明書と、ヘルスチェック用の curl。非 root で実行する。
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --no-create-home idp

COPY --from=builder /build/target/release/idp /usr/local/bin/idp

USER idp
EXPOSE 8080
# liveness は /healthz（依存先を見ない）。BIND_ADDR の既定ポートに合わせる。
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=5 \
    CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1
# 設定はすべて環境変数から注入する（config モジュール経由。docs/OPERATIONS.md 参照）。
ENTRYPOINT ["/usr/local/bin/idp"]
