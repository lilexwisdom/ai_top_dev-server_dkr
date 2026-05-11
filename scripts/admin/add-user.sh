#!/usr/bin/env bash
# 사용자 추가 시 1회 root 셋업 — linger/subid 확인, SSH 포트 할당, authorized_keys append, 부트스트랩 dump.
# usage:
#   sudo bash scripts/admin/add-user.sh <username> <pubkey-path-or->
#   sudo bash scripts/admin/add-user.sh <username> --backfill-only <port>
# 멱등. 같은 사용자에 두 번 돌려도 안전.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

DEVSTACK_DIR=${DEVSTACK_DIR:-/etc/devstack}
PORT_REGISTRY="$DEVSTACK_DIR/port-registry.tsv"
USERS_REGISTRY="$DEVSTACK_DIR/users.tsv"
PORT_LOCK="$PORT_REGISTRY.lock"
START_PORT=${START_PORT:-2222}
PORT_RANGE_END=${PORT_RANGE_END:-2299}

usage() {
  cat <<EOF
usage:
  sudo $0 <username> <pubkey-path-or->
  sudo $0 <username> --backfill-only <port>

옵션:
  pubkey-path  본인 클라이언트의 공개키 파일 경로. '-' 면 stdin에서 받음.
  --backfill-only <port>
               이미 동작 중인 사용자를 레지스트리에만 등록. pubkey 처리/linger 등 추가 작업 없음.

환경변수:
  START_PORT     포트 할당 시작값 (기본 2222)
  PORT_RANGE_END 포트 할당 상한 (기본 2299)
  DEVSTACK_DIR   레지스트리 디렉토리 (기본 /etc/devstack)

예:
  cat /tmp/testuser.pub | sudo $0 testuser -
  sudo $0 testuser /tmp/testuser.pub
  sudo $0 lilexwisdom --backfill-only 2222
EOF
}

require_registries() {
  [ -f "$PORT_REGISTRY" ] || die "$PORT_REGISTRY 없음. host-bootstrap.sh를 먼저 실행."
  [ -f "$USERS_REGISTRY" ] || die "$USERS_REGISTRY 없음. host-bootstrap.sh를 먼저 실행."
}

ensure_user_exists() {
  local u=$1
  getent passwd "$u" >/dev/null || die "사용자 '$u' 가 호스트에 없음. 'sudo adduser $u' 먼저."
}

ensure_linger() {
  local u=$1
  if loginctl show-user "$u" 2>/dev/null | grep -q "Linger=yes"; then
    log_skip "linger 이미 활성. $u"
  else
    log_info "loginctl enable-linger $u"
    loginctl enable-linger "$u"
    log_ok "linger 활성. $u"
  fi
}

ensure_subids() {
  local u=$1
  grep -q "^${u}:" /etc/subuid || die "/etc/subuid에 $u 라인 없음. useradd 정상 동작 확인 필요"
  grep -q "^${u}:" /etc/subgid || die "/etc/subgid에 $u 라인 없음"
  log_ok "subuid/subgid OK. $u"
}

# 포트 자동 할당. 멱등(이미 있으면 그 포트 echo).
# usage: allocate_port <username>  → stdout: port
allocate_port() {
  local u=$1
  : > /tmp/.devstack-allocate-$$  # 빈 파일로 stderr 격리

  _allocate_locked() {
    # 이미 등록돼 있으면 그 포트 echo
    local existing
    existing=$(awk -F'\t' -v u="$u" '$1==u {print $2; exit}' "$PORT_REGISTRY")
    if [ -n "$existing" ]; then
      echo "$existing"
      return 0
    fi
    # 신규 — START_PORT부터 빈 포트 스캔
    local p
    for p in $(seq "$START_PORT" "$PORT_RANGE_END"); do
      # 레지스트리에 이미 등록된 포트 skip
      if awk -F'\t' -v p="$p" '$2==p {found=1} END {exit !found}' "$PORT_REGISTRY"; then
        continue
      fi
      # 호스트 OS에서 사용 중인 포트 skip (보조 안전망)
      if ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then
        continue
      fi
      printf '%s\t%s\t%s\t-\n' "$u" "$p" "$(date -Iseconds)" >> "$PORT_REGISTRY"
      echo "$p"
      return 0
    done
    return 1
  }

  with_flock "$PORT_LOCK" _allocate_locked
}

backfill_port() {
  local u=$1 p=$2

  _backfill_locked() {
    # 이미 같은 사용자/포트 라인이 있으면 skip
    if awk -F'\t' -v u="$u" -v p="$p" '$1==u && $2==p {found=1} END {exit !found}' "$PORT_REGISTRY"; then
      return 0
    fi
    # 사용자명은 다른데 포트가 점유돼 있으면 충돌
    local owner
    owner=$(awk -F'\t' -v p="$p" '$2==p {print $1; exit}' "$PORT_REGISTRY")
    if [ -n "$owner" ] && [ "$owner" != "$u" ]; then
      die "포트 $p 이 이미 $owner 에게 할당됨"
    fi
    # 같은 사용자에 다른 포트가 있으면 정책상 멈춤(중복 방지)
    local prev
    prev=$(awk -F'\t' -v u="$u" '$1==u {print $2; exit}' "$PORT_REGISTRY")
    if [ -n "$prev" ] && [ "$prev" != "$p" ]; then
      die "$u 는 이미 포트 $prev 로 등록돼 있음. 변경하려면 레지스트리 수동 편집."
    fi
    printf '%s\t%s\t%s\tbackfill\n' "$u" "$p" "$(date -Iseconds)" >> "$PORT_REGISTRY"
    return 0
  }

  with_flock "$PORT_LOCK" _backfill_locked
}

ensure_users_row() {
  local u=$1 uid gid
  uid=$(id -u "$u")
  gid=$(id -g "$u")
  if awk -F'\t' -v u="$u" '$1==u {found=1} END {exit !found}' "$USERS_REGISTRY"; then
    log_skip "users.tsv 에 $u 이미 존재"
    return 0
  fi
  printf '%s\t%s\t%s\t%s\t-\n' "$u" "$uid" "$gid" "$(date -Iseconds)" >> "$USERS_REGISTRY"
  log_ok "users.tsv 에 $u 추가"
}

install_authorized_key() {
  local u=$1 src=$2
  local home; home=$(getent passwd "$u" | cut -d: -f6)
  local uid gid; uid=$(id -u "$u"); gid=$(id -g "$u")
  local sshd="$home/.ssh"
  local ak="$sshd/authorized_keys"

  install -d -m 0700 -o "$uid" -g "$gid" "$sshd"
  touch "$ak"
  chown "$uid:$gid" "$ak"
  chmod 0600 "$ak"

  local key
  if [ "$src" = "-" ]; then
    key=$(cat)
  else
    [ -f "$src" ] || die "pubkey 파일 없음. $src"
    key=$(cat "$src")
  fi
  # 빈 줄/공백 제거 후 한 줄로 정규화
  key=$(printf '%s' "$key" | tr -d '\r' | awk 'NF {print; exit}')
  [ -n "$key" ] || die "pubkey 가 비어있음"

  if grep -Fxq -- "$key" "$ak"; then
    log_skip "authorized_keys 에 동일 키 존재"
    return 0
  fi
  printf '%s\n' "$key" >> "$ak"
  chown "$uid:$gid" "$ak"
  chmod 0600 "$ak"
  log_ok "authorized_keys 에 키 추가. $u"
}

write_user_bootstrap() {
  local u=$1 port=$2
  local home; home=$(getent passwd "$u" | cut -d: -f6)
  local uid gid; uid=$(id -u "$u"); gid=$(id -g "$u")
  local f="$home/.devstack-bootstrap"

  # TAILSCALE_IP / LAN_IP 우선순위.
  # 1) 환경변수 (admin이 add-user.sh 호출 시 export)
  # 2) /etc/devstack/host-network.env (host-bootstrap.sh가 템플릿 생성)
  local tsip=${TAILSCALE_IP:-}
  local lanip=${LAN_IP:-}
  local host_net="$DEVSTACK_DIR/host-network.env"
  if [ -f "$host_net" ]; then
    # 선두/말미 공백 관대 처리 (sudoedit/포맷터가 들여쓰기 넣어도 동작)
    [ -n "$tsip" ]  || tsip=$(grep -E '^[[:space:]]*TAILSCALE_IP=' "$host_net" | head -1 | sed -E 's/^[[:space:]]*TAILSCALE_IP=//; s/[[:space:]]+$//' || true)
    [ -n "$lanip" ] || lanip=$(grep -E '^[[:space:]]*LAN_IP='      "$host_net" | head -1 | sed -E 's/^[[:space:]]*LAN_IP=//;      s/[[:space:]]+$//' || true)
  fi

  if [ -z "$tsip" ]; then
    log_warn "TAILSCALE_IP 미확인. setup.sh 실행 전 admin이 다음 중 하나로 채우기."
    log_warn "  - 환경변수. TAILSCALE_IP=100.x.y.z $0 ..."
    log_warn "  - 파일.   $host_net 의 TAILSCALE_IP= 값"
  fi

  cat > "$f" <<EOF
# admin/add-user.sh 가 생성. setup.sh 가 읽음.
SSH_PORT_TS=$port
TAILSCALE_IP=$tsip
LAN_IP=$lanip
EOF
  chown "$uid:$gid" "$f"
  chmod 0644 "$f"
  log_ok "$f 작성"
}

print_next_steps() {
  local u=$1 port=$2
  cat <<EOF

=== $u 등록 완료. 포트 $port ===

$u 에게 알려줄 다음 단계.

  ssh $u@<HOST_IP>
  git clone <repo-url> ~/dev-server_dkr     # 이미 있으면 git pull --ff-only
  bash ~/dev-server_dkr/scripts/user/setup.sh           # dev만
  # 또는
  bash ~/dev-server_dkr/scripts/user/setup.sh --gpu --ft  # finetune까지

이후 본인 노트북에서.

  ssh -p $port $u@<TAILSCALE_IP>            # dev 컨테이너 직접 진입
EOF
}

main() {
  require_root
  [ $# -ge 2 ] || { usage; exit 2; }

  local username=$1
  shift

  require_registries
  ensure_user_exists "$username"

  if [ "${1:-}" = "--backfill-only" ]; then
    local port=${2:-}
    [ -n "$port" ] || die "--backfill-only 뒤에 포트 번호 필요"
    log_info "$username 을 포트 $port 로 backfill"
    backfill_port "$username" "$port"
    ensure_users_row "$username"
    log_ok "backfill 완료. dockerd/컨테이너는 손대지 않음"
    return 0
  fi

  local pubkey=$1
  [ -n "$pubkey" ] || die "pubkey 인자 필요. 파일 경로 또는 '-'(stdin)"

  ensure_linger "$username"
  ensure_subids "$username"

  local port
  port=$(allocate_port "$username") || die "포트 할당 실패. 범위 $START_PORT-$PORT_RANGE_END 모두 사용 중?"
  log_ok "포트 $port 할당 (사용자 $username)"

  ensure_users_row "$username"
  install_authorized_key "$username" "$pubkey"
  write_user_bootstrap "$username" "$port"

  print_next_steps "$username" "$port"
}

main "$@"
