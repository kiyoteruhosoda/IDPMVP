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

# cargo ワークスペース（ADR-0007 P1: crates/core・crates/api）をビルドする。
# 依存解決を層キャッシュに乗せるため、マニフェスト類を先にコピーしてダミービルドする。
COPY Cargo.toml Cargo.lock ./
COPY crates/core/Cargo.toml crates/core/Cargo.toml
COPY crates/api/Cargo.toml crates/api/Cargo.toml
RUN mkdir -p crates/core/src crates/api/src \
    && echo "" > crates/core/src/lib.rs \
    && echo "" > crates/api/src/lib.rs \
    && echo "fn main() {}" > crates/api/src/main.rs \
    && cargo build --release --locked --bin idp \
    ; rm -rf crates/core/src crates/api/src

# 本体をビルド。i18n（include_str! で埋め込み）と migrations（sqlx::migrate! で埋め込み）は
# crate マニフェスト基準の相対パス（../../i18n・../../migrations）で参照するためルートへ配置する。
COPY crates ./crates
COPY i18n ./i18n
COPY migrations ./migrations
RUN cargo build --release --locked --bin idp

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
