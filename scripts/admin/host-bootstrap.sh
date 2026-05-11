#!/usr/bin/env bash
# 호스트 머신 1회 root 셋업 — rootless docker 패키지, nvidia CDI, /etc/devstack/ 레지스트리.
# 멱등. 두 번 실행해도 모든 단계가 [skip]으로 종료.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

DEVSTACK_DIR=${DEVSTACK_DIR:-/etc/devstack}
PORT_REGISTRY="$DEVSTACK_DIR/port-registry.tsv"
USERS_REGISTRY="$DEVSTACK_DIR/users.tsv"

REQUIRED_PKGS=(
  docker-ce-rootless-extras
  slirp4netns
  uidmap
  fuse-overlayfs
  nvidia-container-toolkit
)

ensure_pkgs() {
  local missing=()
  local p
  for p in "${REQUIRED_PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    log_skip "rootless 패키지 5종 이미 설치"
    return 0
  fi
  log_info "누락 패키지 설치. ${missing[*]}"
  apt-get update -y
  apt-get install -y --no-install-recommends "${missing[@]}"
  log_ok "패키지 설치 완료"
}

ensure_cdi() {
  if [ -f /etc/cdi/nvidia.yaml ]; then
    log_skip "/etc/cdi/nvidia.yaml 존재"
    return 0
  fi
  require_cmd nvidia-ctk
  log_info "/etc/cdi/nvidia.yaml 생성 (nvidia-ctk cdi generate)"
  mkdir -p /etc/cdi
  nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
  log_ok "CDI 명세 생성"
}

ensure_userns() {
  local v
  v=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo 1)
  # 일부 커널은 이 키 자체가 없을 수 있음(기본 1). 그땐 패스.
  if [ "$v" = "1" ]; then
    log_ok "kernel.unprivileged_userns_clone=1"
    return 0
  fi
  log_warn "kernel.unprivileged_userns_clone=$v. 1로 임시 설정 후 sysctl.d에 영구화 권장"
  sysctl -w kernel.unprivileged_userns_clone=1 >/dev/null
  echo 'kernel.unprivileged_userns_clone=1' > /etc/sysctl.d/99-devstack-userns.conf
  log_ok "userns 임시+영구 설정"
}

ensure_registry() {
  if [ ! -d "$DEVSTACK_DIR" ]; then
    log_info "$DEVSTACK_DIR 생성"
    install -d -m 0755 -o root -g root "$DEVSTACK_DIR"
  fi
  if [ ! -f "$PORT_REGISTRY" ]; then
    printf '# username\tssh_port\tcreated_at\tnote\n' > "$PORT_REGISTRY"
    chmod 0644 "$PORT_REGISTRY"
    log_ok "$PORT_REGISTRY 초기화"
  else
    log_skip "$PORT_REGISTRY 존재"
  fi
  if [ ! -f "$USERS_REGISTRY" ]; then
    printf '# username\tuid\tgid\tcreated_at\tnote\n' > "$USERS_REGISTRY"
    chmod 0644 "$USERS_REGISTRY"
    log_ok "$USERS_REGISTRY 초기화"
  else
    log_skip "$USERS_REGISTRY 존재"
  fi
  local hn="$DEVSTACK_DIR/host-network.env"
  if [ ! -f "$hn" ]; then
    cat > "$hn" <<'EOF'
# 호스트 네트워크 정보. add-user.sh 가 사용자 부트스트랩 작성 시 이 값을 주입.
# admin이 1회 채워두면 사용자 추가 시 매번 export 안 해도 됨.
TAILSCALE_IP=
LAN_IP=
EOF
    chmod 0644 "$hn"
    log_warn "$hn 템플릿 생성. TAILSCALE_IP 값 채우기 권장 (사용자 .env 자동 작성에 사용)"
  else
    log_skip "$hn 존재"
  fi
}

verify() {
  printf '\n=== 검증 ===\n'
  local fail=0

  local p
  local pkg_ok=1
  for p in "${REQUIRED_PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || pkg_ok=0
  done
  if [ $pkg_ok -eq 1 ]; then log_ok "rootless 패키지 5종"; else log_fail "rootless 패키지 일부 누락"; fail=1; fi

  if [ -f /etc/cdi/nvidia.yaml ]; then log_ok "CDI nvidia.yaml"; else log_fail "CDI nvidia.yaml 없음"; fail=1; fi

  local v
  v=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo 1)
  if [ "$v" = "1" ]; then log_ok "kernel userns"; else log_fail "kernel userns=$v"; fail=1; fi

  if [ -f "$PORT_REGISTRY" ] && [ -f "$USERS_REGISTRY" ]; then
    log_ok "$DEVSTACK_DIR 레지스트리"
  else
    log_fail "레지스트리 파일 누락"
    fail=1
  fi

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    log_ok "nvidia-smi 동작"
  else
    log_warn "nvidia-smi 미동작 (드라이버 미설치 또는 GPU 없음). GPU 사용자 추가 전 확인"
  fi

  if [ $fail -ne 0 ]; then
    die "검증 실패. 위 FAIL 항목 해결 후 재실행."
  fi
  log_ok "호스트 부트스트랩 완료"
}

main() {
  require_root
  log_info "host-bootstrap 시작"
  ensure_pkgs
  ensure_cdi
  ensure_userns
  ensure_registry
  verify
}

main "$@"
