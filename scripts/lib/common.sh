# dev-server_dkr 셋업 스크립트 공통 헬퍼 (log/idempotent_append/kv_upsert/flock 등)
# shellcheck shell=bash
# 단독 실행 금지. 다른 스크립트에서 `source "$(dirname "$0")/../lib/common.sh"` 형태로 로드.

set -euo pipefail

# ANSI는 TTY일 때만 사용 (파이프/리다이렉트 시 잡음 회피)
if [ -t 1 ]; then
  _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'; _C_BLU=$'\033[34m'; _C_RST=$'\033[0m'
else
  _C_RED=; _C_YEL=; _C_GRN=; _C_BLU=; _C_RST=
fi

log_info()  { printf '%s[INFO]%s %s\n'  "$_C_BLU" "$_C_RST" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n'  "$_C_GRN" "$_C_RST" "$*"; }
log_skip()  { printf '%s[skip]%s %s\n'  "$_C_BLU" "$_C_RST" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n'  "$_C_YEL" "$_C_RST" "$*" >&2; }
log_fail()  { printf '%s[FAIL]%s %s\n'  "$_C_RED" "$_C_RST" "$*" >&2; }

die() { log_fail "$*"; exit 1; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "필요한 명령이 없음. $c"
  done
}

require_root() {
  [ "$(id -u)" = "0" ] || die "이 스크립트는 root로 실행해야 함. sudo로 다시."
}

require_not_root() {
  [ "$(id -u)" != "0" ] || die "이 스크립트는 일반 사용자 셸에서 실행해야 함. sudo 없이."
}

# 파일에 라인이 없으면 append. fixed-string 매칭(정규식 X)
# usage: idempotent_append <file> <line>
idempotent_append() {
  local file=$1 line=$2
  [ -f "$file" ] || { printf '%s\n' "$line" > "$file"; return 0; }
  grep -Fxq -- "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

# KEY=VAL 형식 파일에 멱등 upsert. 값 안에 `&`, `|`, `\` 안 들어가는 단순값 가정.
# usage: kv_upsert <file> <KEY> <VALUE>
kv_upsert() {
  local file=$1 key=$2 val=$3
  [ -f "$file" ] || : > "$file"
  if grep -Eq "^${key}=" "$file"; then
    # sed -i with delimiter | (값에 / 가능) — val의 |, \, & 회피
    local esc
    esc=$(printf '%s' "$val" | sed -e 's/[|&\\]/\\&/g')
    sed -i -E "s|^${key}=.*|${key}=${esc}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# flock 래퍼. lockfile은 자동 생성. fd 9 사용.
# usage: with_flock <lockfile> <command...>
with_flock() {
  local lockfile=$1; shift
  ( flock -x 9; "$@" ) 9>"$lockfile"
}

# 환경 가정 검증 한 줄 표시
# usage: check_item <라벨> <표현식> ... — 표현식이 0 종료면 OK
check_item() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then
    log_ok "$label"
    return 0
  else
    log_fail "$label"
    return 1
  fi
}
