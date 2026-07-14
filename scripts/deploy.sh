#!/usr/bin/env bash
# deploy.sh — デプロイ先の単一入口（ソース不要・ビルドしない。build.sh が作る dist/ に同梱）。
#
# モードは必須。どのモードでも新イメージを load し、アプリコンテナ（api・web・proxy）を
# --force-recreate で必ず作り直す（旧イメージのまま restart ループしているコンテナが居座って
# 新バイナリが反映されない事故を防ぐ）。DB（mariadb）は落とさない（reset を除く）。
#
# 使い方（デプロイ先の dist/ 内で実行する）:
#   ./deploy.sh app      アプリのみ更新（DDL 変更なし）。イメージ load → app 作り直し → readiness
#   ./deploy.sh migrate  DDL 更新時（新しい migration を追加した場合）。app + migrate（DDL・マスタデータ）
#   ./deploy.sh reset    完全初期化（DB volume 削除。破壊的・確認なし）→ migrate → app 作り直し
#
# 初回デプロイは DDL 適用が要るため `migrate`（または `reset`）を使う。以降のアプリ更新は `app`。
# 前提: docker（Compose v2 または docker-compose v1）と openssl。
set -Eeuo pipefail

log()  { printf '[idp] %s\n' "$*" >&2; }
warn() { printf '[idp][warn] %s\n' "$*" >&2; }
err()  { printf '[idp][error] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

# --- 実行場所の解決 ---------------------------------------------------------------
# バンドル（dist/）内では deploy.sh の隣に docker-compose.yml とイメージ tar がある。
# リポジトリ内（scripts/）ではルートの docker-compose.deploy.yml と dist/ を使う。
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/docker-compose.yml" ]]; then
  base="$script_dir"
  compose_file="docker-compose.yml"
  dist_dir="$script_dir"
else
  base="$(cd "$script_dir/.." && pwd)"
  compose_file="docker-compose.deploy.yml"
  dist_dir="$base/dist"
fi
cd "$base"
[[ -f "$base/$compose_file" ]] || die "$compose_file がありません（デプロイ用 Compose）。"

env_file="$base/.env"
example_file="$base/.env.example"

# アプリコンテナ（毎回作り直す対象）と、診断でログを見るサービス一覧。
APP_SERVICES=(api web proxy)
ALL_SERVICES=(mariadb migrate api web proxy)
DEPLOYED_REVISION=""

# --- 引数（モード必須） -----------------------------------------------------------
mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    app | migrate | reset) mode="$1" ;;
    -h | --help) usage; exit 0 ;;
    *) usage; die "不明な引数: $1" ;;
  esac
  shift
done
[[ -n "$mode" ]] || { usage; die "モードを指定してください（app | migrate | reset）。"; }

command -v docker >/dev/null 2>&1 || die "docker が見つかりません。"
if docker compose version >/dev/null 2>&1; then
  compose="docker compose -f $compose_file"
elif command -v docker-compose >/dev/null 2>&1; then
  compose="docker-compose -f $compose_file"
else
  die "docker compose（v2）または docker-compose（v1）が見つかりません。"
fi

# --- .env の値参照・秘密マスク -----------------------------------------------------
# .env から KEY の値を取り出す（最後の一致。無ければ空）。
get_env_var() {
  local key="$1"
  [[ -f "$env_file" ]] || return 0
  grep -E "^${key}=" "$env_file" | tail -n1 | cut -d= -f2-
}

mask_secrets() {
  local sed_expr=() key value
  if [[ -f "$env_file" ]]; then
    for key in MARIADB_PASSWORD MARIADB_ROOT_PASSWORD KEY_ENCRYPTION_KEY INTERNAL_SERVICE_TOKEN CSRF_SECRET; do
      value="$(get_env_var "$key" 2>/dev/null || true)"
      [[ -n "$value" ]] && sed_expr+=(-e "s|${value//|/\|}|***MASKED***|g")
    done
  fi
  if [[ ${#sed_expr[@]} -gt 0 ]]; then
    sed "${sed_expr[@]}"
  else
    cat
  fi
}

# --- 診断・エラー処理 --------------------------------------------------------------
# 指定サービスの状態とログ末尾を出す（秘密はマスク）。バインドマウント失敗など
# コンテナが生成されない起動前エラーもあるため、compose ps -a で全体像も出す。
dump_module_logs() { # 引数: サービス名...
  {
    echo "[idp][diagnostic] mode=${mode:-unknown}"
    echo "[idp][diagnostic] compose ps"
    $compose ps -a || true
    local svc cid state image
    for svc in "$@"; do
      cid="$($compose ps -aq "$svc" 2>/dev/null || true)"
      [[ -n "$cid" ]] || continue
      state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
      image="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
      echo "[idp][diagnostic] service=$svc status=${state:-unknown} image=${image:-unknown}"
      echo "[idp][diagnostic] logs tail: $svc"
      $compose logs --tail=80 "$svc" || true
    done
  } 2>&1 | mask_secrets >&2
}

# エラーメッセージを出し、関係サービスのログを出して終了する。
fail() { # 引数: メッセージ [サービス名...]
  trap - ERR
  local msg="$1"
  shift || true
  err "$msg"
  [[ $# -gt 0 ]] && dump_module_logs "$@"
  err "デプロイに失敗しました（mode=${mode:-unknown}）。"
  exit 1
}

# 想定外のエラー（set -e で中断）でも、全モジュールのログを出し、元の終了コードを保って終わる。
on_unexpected_error() {
  local code="$1" line="$2" command="$3"
  trap - ERR
  echo "[idp][error] 想定外のエラー: line=$line exit=$code command=$command（mode=${mode:-unknown}）" | mask_secrets >&2
  dump_module_logs "${ALL_SERVICES[@]}"
  err "デプロイに失敗しました（mode=${mode:-unknown}）。"
  exit "$code"
}
trap 'on_unexpected_error $? $LINENO "$BASH_COMMAND"' ERR

# 指定サービスが healthy（healthcheck が無い場合は running）になるまで待つ。
# exited/dead/restarting は「起動できず落ちている」ため即失敗させる（旧イメージのスタブや
# 設定不備による crash-loop をタイムアウトを待たずに検知する）。
wait_healthy() {
  local service="$1" tries="${2:-60}" cid state health i
  log "$service の起動を待機します..."
  for ((i = 0; i < tries; i++)); do
    cid="$($compose ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null || true)"
      case "$state" in
        restarting | exited | dead)
          fail "$service が起動できず異常終了しています（status=$state）。旧イメージのスタブや設定不備が疑われます。" "$service" ;;
      esac
      if [[ "$health" == "healthy" || (-z "$health" && "$state" == "running") ]]; then
        log "$service: ${health:-$state}"
        return 0
      fi
    fi
    sleep 2
  done
  fail "$service が healthy になりませんでした（タイムアウト）。" "$service"
}

# --- .env -------------------------------------------------------------------------
# .env の KEY 行を VALUE で置換する（無ければ追記）。VALUE は sed を通さず printf で
# リテラル書き込みするため、base64 の / + = や @ : を含んでも安全。
set_env_var() {
  local key="$1" value="$2" tmp replaced=0 line
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "${key}="* ]]; then
      printf '%s=%s\n' "$key" "$value" >>"$tmp"
      replaced=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$env_file"
  [[ $replaced -eq 1 ]] || printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$env_file"
}

# .env を .env.example から生成する。既存 .env は上書きしない（冪等）。
ensure_env_file() {
  if [[ -f "$env_file" ]]; then
    log "既存の .env を使用します（上書きしません）。"
    return 0
  fi
  [[ -f "$example_file" ]] || die ".env.example が見つかりません。"
  command -v openssl >/dev/null 2>&1 || die "openssl が見つかりません。"
  log ".env を新規生成します（秘密情報を乱数生成）。"
  cp "$example_file" "$env_file"
  local db_password
  db_password="$(openssl rand -hex 24)"
  set_env_var MARIADB_PASSWORD "$db_password"
  set_env_var MARIADB_ROOT_PASSWORD "$(openssl rand -hex 24)"
  set_env_var KEY_ENCRYPTION_KEY "$(openssl rand -base64 32)"
  set_env_var INTERNAL_SERVICE_TOKEN "$(openssl rand -hex 32)"
  set_env_var CSRF_SECRET "$(openssl rand -base64 32)"
  set_env_var DATABASE_URL "mysql://idp:${db_password}@127.0.0.1:3306/idp"
  set_env_var TEST_DATABASE_URL "mysql://idp:${db_password}@127.0.0.1:3306/idp"
  chmod 600 "$env_file"
  log ".env を生成しました（パーミッション 600）。秘密情報は自動生成済みです。"
  log "環境に合わせて確認・変更する項目（詳細は .env 内コメント）:"
  log "  - ISSUER   : 利用者がアクセスする公開 URL（既定 http://localhost:8080）"
  log "  - WEB_PORT : ホストに公開するポート（既定 8080）"
}

# --- イメージ（tar 読込と確認） ------------------------------------------------------
# `docker load` は標準では進捗を出さず、大きいイメージだと数分間無反応に見える。pv があれば
# 進捗バーを、無ければ一定間隔でハートビートを出し「止まって見えるが実行中」を分かるようにする。
load_image_with_progress() {
  local tar="$1" size_human pid waited=0
  size_human="$(du -h "$tar" 2>/dev/null | cut -f1 || true)"
  log "イメージを読み込みます: $tar (${size_human:-unknown size}) ..."
  if command -v pv >/dev/null 2>&1; then
    pv "$tar" | docker load >/dev/null || fail "docker load に失敗しました: $tar"
    return 0
  fi
  docker load -i "$tar" >/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    waited=$((waited + 5))
    if kill -0 "$pid" 2>/dev/null; then
      log "...読み込み中、${waited}s 経過（大きいイメージでは正常です）"
    fi
  done
  wait "$pid" || fail "docker load に失敗しました: $tar"
}

# dist の tar からイメージを読み込み、api/web/migrate が揃っていることを確認する。
# manifest.env（build.sh が出力）があれば image ID を照合し、一致すれば読込をスキップする。
ensure_images() {
  local manifest="$dist_dir/manifest.env" svc ref tar expected_id actual_id ref_key id_key
  local first_revision="" revision prefix tag
  prefix="$(get_env_var IMAGE_PREFIX)"
  tag="$(get_env_var IMAGE_TAG)"
  # shellcheck disable=SC1090
  [[ -f "$manifest" ]] && source "$manifest"
  for svc in api web migrate; do
    ref_key="${svc}_ref"
    id_key="${svc}_image_id"
    ref="${!ref_key:-${prefix:-idp}/${svc}:${tag:-latest}}"
    expected_id="${!id_key:-}"
    tar="$dist_dir/idp-${svc}.tar"
    actual_id="$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || true)"
    if [[ -z "$actual_id" || (-n "$expected_id" && "$actual_id" != "$expected_id") ]]; then
      [[ -f "$tar" ]] || die "イメージ $ref がありません（$tar も無し）。build.sh が出力した dist/ を配置してください。"
      load_image_with_progress "$tar"
      actual_id="$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || true)"
    fi
    [[ -n "$actual_id" ]] || die "イメージ $ref を解決できません。"
    [[ -z "$expected_id" || "$actual_id" == "$expected_id" ]] ||
      die "$ref の image ID が manifest と不一致です: $actual_id != $expected_id"
    revision="$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$ref" 2>/dev/null || true)"
    if [[ -n "$revision" ]]; then
      if [[ -z "$first_revision" ]]; then
        first_revision="$revision"
      else
        [[ "$revision" == "$first_revision" ]] || die "api/web/migrate の commit label が一致しません。"
      fi
    fi
    log "配置対象 image: service=$svc ref=$ref revision=${revision:-unknown}"
  done
  DEPLOYED_REVISION="$first_revision"
}

# --- 各フェーズ ---------------------------------------------------------------------
# mariadb を起動して healthy を待つ（reset 以外では既存を落とさず再利用する）。
ensure_mariadb() {
  log "MariaDB を起動します..."
  $compose up -d mariadb
  wait_healthy mariadb
}

# DDL・マスタデータを適用する（常駐させない専用ジョブ）。
run_migrate() {
  ensure_mariadb
  log "マイグレーションを適用します（DDL + マスタデータ）..."
  $compose run --rm migrate
}

# アプリコンテナを --force-recreate で必ず作り直す。旧イメージのまま restart ループしている
# コンテナが居座ると、新イメージを load（タグ付け替え）しても `up -d` が「変更なし」と判断して
# 置き換えないことがあるため。--remove-orphans で名前が変わった旧コンテナも掃除する。
recreate_app() {
  local up_out status
  log "api・web・proxy を作り直します（--force-recreate で新イメージへ確実に置き換え）..."
  up_out="$(mktemp)"
  set +e
  $compose up -d --force-recreate --remove-orphans "${APP_SERVICES[@]}" 2>&1 | tee "$up_out" | mask_secrets >&2
  status=${PIPESTATUS[0]}
  set -e
  if [[ $status -ne 0 ]]; then
    err "docker compose up が失敗しました。"
    # バインドマウント失敗等の起動前エラーはコンテナログに残らないため up の出力を再掲する。
    echo "[idp][diagnostic] 'docker compose up' の出力（コンテナログに残らない起動前エラー対策）:" >&2
    mask_secrets <"$up_out" >&2
    rm -f "$up_out"
    dump_module_logs "${APP_SERVICES[@]}"
    err "デプロイに失敗しました（mode=${mode:-unknown}）。"
    exit "$status"
  fi
  rm -f "$up_out"
  wait_healthy api
  wait_healthy web
}

root_tenant_id() {
  local db_user db_name db_password
  db_user="$(get_env_var MARIADB_USER)"
  db_name="$(get_env_var MARIADB_DATABASE)"
  db_password="$(get_env_var MARIADB_PASSWORD)"
  $compose exec -T mariadb mariadb -u"${db_user:-idp}" -p"$db_password" "${db_name:-idp}" -N -B \
    -e 'SELECT id FROM tenants WHERE parent_tenant_id IS NULL' 2>/dev/null || true
}

# readiness（proxy 経由 /readyz）を確認し、ログイン URL を案内する。
verify_ready() {
  local web_port issuer ready_url root login_url cid
  web_port="$(get_env_var WEB_PORT)"
  web_port="${web_port:-8080}"
  issuer="$(get_env_var ISSUER)"
  issuer="${issuer:-http://localhost:${web_port}}"
  ready_url="http://127.0.0.1:${web_port}/readyz"
  log "readiness を確認します: $ready_url"
  for _ in $(seq 1 30); do
    if curl -fsS "$ready_url" >/dev/null 2>&1; then
      root="$(root_tenant_id)"
      login_url="${issuer%/}/${root:-<root-tenant-id>}/login"
      log "readyz OK。"
      log "ログイン URL: $login_url"
      return 0
    fi
    sleep 2
  done
  err "readyz が OK になりませんでした: $ready_url"
  dump_module_logs "${APP_SERVICES[@]}"
  cid="$($compose ps -q web 2>/dev/null || true)"
  if [[ -n "$cid" ]]; then
    echo "[idp][diagnostic] web healthcheck 履歴:" >&2
    docker inspect --format '{{json .State.Health}}' "$cid" 2>/dev/null | mask_secrets >&2 || true
  fi
  err "デプロイに失敗しました（mode=${mode:-unknown}）。"
  exit 1
}

# --- 実行 --------------------------------------------------------------------------
log "デプロイ開始（mode=$mode, base=$base）"

# Docker daemon 到達性の事前確認（権限不足・daemon 停止を早期に分かりやすく落とす）。
if ! docker info >/dev/null 2>&1; then
  err "Docker daemon に到達できません（権限不足、または daemon 停止）。"
  err "  sudo で実行するか、ユーザーを docker グループに追加して再ログインしてください。"
  exit 1
fi

ensure_env_file
ensure_images

case "$mode" in
  app)
    # アプリのみ更新（DDL 変更なし）。DB は起動確認だけして落とさない。
    ensure_mariadb
    recreate_app
    verify_ready
    ;;
  migrate)
    # DDL 更新時。migrate（DDL・マスタデータ）を適用してから app を作り直す。
    run_migrate
    recreate_app
    verify_ready
    ;;
  reset)
    # 完全初期化（破壊的）。DB volume を削除してから migrate・app をやり直す。.env は保持する。
    log "DB volume を削除します（.env は保持します）。"
    $compose down -v --remove-orphans
    run_migrate
    recreate_app
    verify_ready
    ;;
esac

log "未使用の Docker イメージを掃除します..."
docker image prune -f >/dev/null 2>&1 || true

log "デプロイが完了しました（mode=$mode, revision=${DEPLOYED_REVISION:-unknown}）。"
