#!/usr/bin/env bash
# scripts/build.sh — リリース成果物をビルドする（ネイティブ binary または Docker イメージ）。
#
# モード:
#   （既定）      cargo でワークスペースの release binary（idp / idp-web）をビルドする。
#   --docker      Docker イメージ（api / web / migrate）を docker compose でビルドする。
#   --check       ビルド前に fmt チェック・clippy（警告をエラー扱い）・test を実行する。
#   --help        使い方を表示する。
#
# 例:
#   ./scripts/build.sh                # release binary を target/release へ出力
#   ./scripts/build.sh --check        # 検証（fmt/clippy/test）してから release binary
#   ./scripts/build.sh --docker       # api/web/migrate の Docker イメージをビルド
#   ./scripts/build.sh --check --docker
#
# 前提: ネイティブビルドは rustup（cargo）。Docker ビルドは docker（Compose v2）。
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib.sh"

target="native"
run_check=0

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker) target="docker" ;;
    --check)  run_check=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "不明な引数: $1（--help で使い方を表示）" ;;
  esac
  shift
done

# --- 事前検証（任意） ----------------------------------------------------------
if [[ $run_check -eq 1 ]]; then
  command -v cargo >/dev/null 2>&1 || die "cargo が見つかりません（rustup を導入してください）。"
  log "fmt チェック（cargo fmt --check）..."
  cargo fmt --all -- --check
  log "clippy（警告をエラー扱い）..."
  cargo clippy --workspace --all-targets -- -D warnings
  log "テスト（cargo test）..."
  cargo test --workspace --locked
fi

# --- ビルド --------------------------------------------------------------------
case "$target" in
  native)
    command -v cargo >/dev/null 2>&1 || die "cargo が見つかりません（rustup を導入してください）。"
    log "release binary をビルドします（idp / idp-web）..."
    cargo build --release --locked --bin idp --bin idp-web
    log "完了。成果物: target/release/idp・target/release/idp-web"
    ;;
  docker)
    compose="$(compose_cmd)"
    log "Docker イメージをビルドします（api / web / migrate）..."
    $compose build api web migrate
    log "完了。イメージがビルドされました（docker compose images で確認）。"
    ;;
esac
