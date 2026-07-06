#!/usr/bin/env bash
# scripts/lib.sh — init.sh / deploy.sh 共通ヘルパ。単体では実行しない（source して使う）。

log() { printf '[idp] %s\n' "$*" >&2; }
die() { printf '[idp][error] %s\n' "$*" >&2; exit 1; }

# 利用可能な Compose コマンド（v2: `docker compose` / v1: `docker-compose`）を返す。
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    die "docker compose（v2）または docker-compose（v1）が見つかりません。"
  fi
}

# .env の KEY 行を VALUE で置換する（無ければ追記）。VALUE は sed を通さず printf で
# リテラル書き込みするため、base64 の / + = や @ : を含んでも安全。
set_env_var() {
  local key="$1" value="$2" file="$3" tmp replaced=0 line
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "${key}="* ]]; then
      printf '%s=%s\n' "$key" "$value" >>"$tmp"
      replaced=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
  [[ $replaced -eq 1 ]] || printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$file"
}

# .env から KEY の値を取り出す（最後の一致。無ければ空）。
get_env_var() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2-
}

# 指定サービスのコンテナが healthy（healthcheck 無い場合は running）になるまで待つ。
wait_healthy() {
  local compose="$1" service="$2" tries="${3:-60}" cid status i
  log "$service の起動を待機します..."
  for ((i = 0; i < tries; i++)); do
    cid="$($compose ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
      case "$status" in
        healthy | running) log "$service: $status"; return 0 ;;
        exited | dead) die "$service が異常終了しました（status=$status）。ログ: $compose logs $service" ;;
      esac
    fi
    sleep 2
  done
  die "$service が healthy になりませんでした（タイムアウト）。ログ: $compose logs $service"
}
