#!/usr/bin/env bash
# scripts/build-remote-container.sh — git 非搭載のデプロイ先（例: Synology DSM）向けの一ホスト方式。
#
# ソース取得＆イメージビルドは「dev コンテナ」内で行い（コンテナに git・ツールチェーンがある前提）、
# 生成された dist/ をコンテナのワークスペース（ホストから見えるパス）からデプロイ先へ取り込み、
# 同梱の deploy.sh を実行する。**デプロイ先に git は不要**（build-remote.sh の git 版が使えない環境向け）。
#
# 3 ステップを 1 本で実行する（旧来の別 pick.sh は本スクリプトへ統合済み）:
#   BUILD  … dev コンテナ内で git pull → scripts/build.sh（dist/ を生成）
#   PICK   … ビルド済み dist/ をデプロイ先へ取り込み
#   DEPLOY … 取り込んだ deploy.sh を実行
#
# 使い方（デプロイ先で。モードはどの引数位置でも拾う。既定 migrate）:
#   ./build-remote-container.sh            # migrate
#   ./build-remote-container.sh app
#   ./build-remote-container.sh reset
#
# 設定（環境変数で上書き可。下の既定値を環境に合わせて書き換えてもよい）:
#   IDP_PROJECT        dev コンテナ内のプロジェクト名（IDP_DEV_WORKDIR の既定に使う）
#   IDP_DEV_CONTAINER  ビルドを行う dev コンテナ名
#   IDP_DEV_USER       コンテナ内でビルドする実行ユーザー
#   IDP_DEV_WORKDIR    コンテナ内のリポジトリ working dir（scripts/build.sh がある場所）
#   IDP_DIST_DIR       ホストから見えるビルド済み dist/ の絶対パス（必須。無指定はエラー）
#   IDP_TARGET_DIR     デプロイ先ディレクトリ（既定: このスクリプトの場所）
#
# 前提: docker（デプロイ先）と、ビルド用 dev コンテナが起動していること。
set -euo pipefail

# ---- 既定値（環境に合わせて編集するか、環境変数で上書きする） --------------------
project="${IDP_PROJECT:-idp}"
dev_container="${IDP_DEV_CONTAINER:-ubuntu-dev}"
dev_user="${IDP_DEV_USER:-sshuser}"
dev_workdir="${IDP_DEV_WORKDIR:-/work/project/${project}}"
dist_dir="${IDP_DIST_DIR:-}"
target_dir="${IDP_TARGET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

log() { printf '[idp:build-remote-container] %s\n' "$*" >&2; }
die() { printf '[idp:build-remote-container][error] %s\n' "$*" >&2; exit 1; }

# モードは引数のどこにあっても拾う（余分な語が前に付いても動く）。既定 migrate。
mode=migrate
for arg in "$@"; do
  case "$arg" in app | migrate | reset) mode="$arg" ;; esac
done

command -v docker >/dev/null 2>&1 || die "docker が見つかりません。"
[[ -n "$dist_dir" ]] || die "IDP_DIST_DIR（ホストから見えるビルド済み dist/ の絶対パス）を設定してください。"

cd "$target_dir"
log "START  project=$project  mode=$mode  target=$target_dir"

# --- BUILD（dev コンテナ内で git pull → build.sh） ------------------------------
log "BUILD  dev コンテナ '$dev_container' でビルドします（$dev_workdir）..."
docker exec -u "$dev_user" "$dev_container" bash -lc "
  set -e
  cd '$dev_workdir'
  git pull --ff-only
  ./scripts/build.sh
" || die "コンテナ内ビルドに失敗しました。"

# --- PICK（ビルド済み dist をデプロイ先へ取り込み。旧 pick.sh 相当） --------------
log "PICK   $dist_dir → $target_dir"
[[ -d "$dist_dir" ]] || die "dist が見つかりません: $dist_dir（build.sh の出力先か IDP_DIST_DIR を確認）。"
cp -a "$dist_dir/." "$target_dir/"
[[ -f "$target_dir/deploy.sh" ]] || die "deploy.sh が取り込まれていません（build.sh の出力を確認）。"
chmod +x "$target_dir"/*.sh 2>/dev/null || true

# --- DEPLOY（.env は deploy.sh が管理: 初回生成・以後は不足キーのみ追記・秘密は不変） ----
log "DEPLOY ./deploy.sh $mode"
"$target_dir/deploy.sh" "$mode"

log "END    mode=$mode"
