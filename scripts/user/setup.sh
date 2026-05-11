#!/usr/bin/env bash
# 일반 사용자 1회 셋업 — rootless dockerd 설치, .env 렌더, dev compose up. --gpu/--ft 옵션.
# usage:
#   bash scripts/user/setup.sh                 # dev만
#   bash scripts/user/setup.sh --gpu           # dev + 본인 dockerd에 nvidia runtime
#   bash scripts/user/setup.sh --gpu --ft      # dev + finetune 이미지 빌드 + CUDA 스모크
# 멱등. 두 번 돌리면 모든 단계 [skip].
# sudo 사용 금지 — 본인 셸에서 직접.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

WANT_GPU=0
WANT_FT=0

usage() {
  cat <<EOF
usage: bash $0 [--gpu] [--ft]

옵션:
  --gpu  rootless dockerd 에 nvidia runtime 등록 (finetune 필수)
  --ft   finetune 이미지 빌드 + CUDA 스모크 (반드시 --gpu 와 함께)
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --gpu) WANT_GPU=1 ;;
      --ft)  WANT_FT=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "알 수 없는 옵션. $1 (--help 참고)" ;;
    esac
    shift
  done
  if [ $WANT_FT -eq 1 ] && [ $WANT_GPU -eq 0 ]; then
    die "--ft 은 --gpu 와 함께 써야 함 (GPU 필수). 다시. bash $0 --gpu --ft"
  fi
}

# 부트스트랩 파일 (admin 의 add-user.sh 가 생성) 로드. SSH_PORT_TS/TAILSCALE_IP/LAN_IP 변수가 셀에 들어옴.
load_bootstrap() {
  local f="$HOME/.devstack-bootstrap"
  [ -f "$f" ] || die "$f 없음. admin 이 add-user.sh 를 본인 계정에 돌렸는지 확인."
  # shellcheck disable=SC1090
  source "$f"
  [ -n "${SSH_PORT_TS:-}" ] || die "$f 에 SSH_PORT_TS 누락"
  [ -n "${TAILSCALE_IP:-}" ] || die "$f 에 TAILSCALE_IP 누락. admin 에게 보고."
  log_ok "부트스트랩 로드 (포트 $SSH_PORT_TS, Tailscale $TAILSCALE_IP)"
}

ensure_rootless_docker() {
  local unit="$HOME/.config/systemd/user/docker.service"
  if [ -f "$unit" ]; then
    log_skip "rootless dockerd 이미 설치됨"
  else
    require_cmd dockerd-rootless-setuptool.sh
    log_info "dockerd-rootless-setuptool.sh install"
    dockerd-rootless-setuptool.sh install
  fi
  systemctl --user enable --now docker >/dev/null 2>&1 || \
    die "systemctl --user enable docker 실패. 직접 ssh 진입한 셸에서 실행했는지 확인 (su - 는 systemd --user 세션이 없음)."
  log_ok "rootless dockerd 활성"
}

ensure_shell_env() {
  local rc="$HOME/.bashrc"
  local line_path='export PATH=/usr/bin:$PATH'
  local line_host='export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock'
  idempotent_append "$rc" "$line_path"
  idempotent_append "$rc" "$line_host"
  # 현재 셸에도 적용
  export PATH=/usr/bin:$PATH
  export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
  log_ok ".bashrc 갱신 (PATH, DOCKER_HOST)"
}

ensure_gpu() {
  [ $WANT_GPU -eq 1 ] || return 0
  require_cmd nvidia-ctk
  local daemon_json="$HOME/.config/docker/daemon.json"
  if [ -f "$daemon_json" ] && grep -q '"nvidia"' "$daemon_json"; then
    log_skip "nvidia runtime 이미 등록됨"
  else
    log_info "nvidia-ctk runtime configure (rootless daemon.json)"
    mkdir -p "$(dirname "$daemon_json")"
    nvidia-ctk runtime configure --runtime=docker --config="$daemon_json"
    systemctl --user restart docker
    sleep 2
  fi
  log_ok "GPU runtime 활성"
}

ensure_repo_pulled() {
  # 사용자가 이미 repo 안에서 setup.sh 를 돌리고 있다고 가정. git pull 만 시도.
  if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" pull --ff-only >/dev/null 2>&1 || \
      log_warn "git pull --ff-only 실패. 로컬 변경 또는 fork? 그대로 진행"
    log_ok "repo 최신화 시도 완료"
  else
    log_warn "$REPO_DIR 가 git repo 아님 — clone 하지 않음. 진행"
  fi
}

render_env() {
  local env_file="$REPO_DIR/.env"
  if [ ! -f "$env_file" ]; then
    cp "$REPO_DIR/.env.example" "$env_file"
    log_info "$env_file 신규 생성"
  fi
  local uid gid user
  user=$(whoami)
  uid=$(id -u)
  gid=$(id -g)
  kv_upsert "$env_file" USERNAME "$user"
  kv_upsert "$env_file" USER_UID "$uid"
  kv_upsert "$env_file" USER_GID "$gid"
  kv_upsert "$env_file" DOCKER_GID "$gid"
  kv_upsert "$env_file" DOCKER_SOCK "/run/user/$uid/docker.sock"
  kv_upsert "$env_file" SSH_PORT_TS "$SSH_PORT_TS"
  kv_upsert "$env_file" SSH_PORT_LOCAL "$SSH_PORT_TS"
  kv_upsert "$env_file" TAILSCALE_IP "$TAILSCALE_IP"
  [ -n "${LAN_IP:-}" ] && kv_upsert "$env_file" LAN_IP "$LAN_IP"
  log_ok ".env 렌더 완료"
}

ensure_workspace() {
  mkdir -p "$HOME/Projects/dev-workspace"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [ -f "$HOME/.ssh/authorized_keys" ]; then
    chmod 600 "$HOME/.ssh/authorized_keys"
  fi
  if [ $WANT_FT -eq 1 ]; then
    mkdir -p "$HOME/Projects/dev-workspace/finetune-output"
    log_ok "finetune-output 디렉토리 생성"
  fi
  log_ok "워크스페이스/SSH 디렉토리 준비"
}

compose_up_dev() {
  ( cd "$REPO_DIR" && docker compose build dev )
  ( cd "$REPO_DIR" && docker compose up -d dev )
  log_info "dev healthy 폴링 (최대 60초)"
  local user; user=$(whoami)
  local cname="${user}-dev"
  local s=""
  for _ in $(seq 1 30); do
    s=$(docker inspect -f '{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "unknown")
    [ "$s" = "healthy" ] && break
    sleep 2
  done
  [ "$s" = "healthy" ] || die "dev 컨테이너가 healthy 가 되지 못함 (현재 $s). 'docker logs $cname' 확인."
  log_ok "dev 컨테이너 healthy"
}

build_finetune() {
  [ $WANT_FT -eq 1 ] || return 0
  ( cd "$REPO_DIR" && docker compose --profile ft build finetune )
  log_ok "finetune 이미지 빌드 완료"
}

verify_dev() {
  printf '\n=== dev 검증 ===\n'
  local fail=0
  if docker info 2>/dev/null | grep -qE "^ Rootless: true"; then
    log_ok "Rootless: true"
  else
    log_fail "Rootless 아님 — DOCKER_HOST 또는 dockerd 상태 점검"
    fail=1
  fi
  if docker run --rm hello-world >/dev/null 2>&1; then
    log_ok "hello-world 통과"
  else
    log_fail "docker run --rm hello-world 실패"
    fail=1
  fi
  local user; user=$(whoami)
  local cname="${user}-dev"
  local code
  code=$(docker exec "$cname" curl -s -o /dev/null -w "%{http_code}" http://host.docker.internal:11434/api/tags 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then log_ok "host.docker.internal:11434 -> 200"; else log_warn "ollama:11434 -> $code (호스트 측 ollama 점검)"; fi
  code=$(docker exec "$cname" curl -s -o /dev/null -w "%{http_code}" http://host.docker.internal:8000/v1/models 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then log_ok "host.docker.internal:8000 -> 200"; else log_warn "whisper:8000 -> $code (호스트 측 whisper 점검)"; fi
  return $fail
}

verify_gpu_and_ft() {
  [ $WANT_GPU -eq 1 ] || return 0
  printf '\n=== GPU/finetune 검증 ===\n'
  if ! docker info 2>/dev/null | grep -qE 'Runtimes:.*nvidia'; then
    log_fail "rootless dockerd 에 nvidia runtime 미등록"
    return 1
  fi
  log_ok "nvidia runtime 등록됨"

  if [ $WANT_FT -eq 1 ]; then
    log_info "CUDA 스모크 (finetune 컨테이너에서 torch.cuda.is_available)"
    local out
    out=$( cd "$REPO_DIR" && docker compose --profile ft run --rm finetune \
             python -c "import torch; print('CUDA=', torch.cuda.is_available()); print('DEV=', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'none')" 2>&1 || true )
    printf '%s\n' "$out" | tail -5
    printf '%s' "$out" | grep -q 'CUDA= True' && log_ok "CUDA 스모크 통과" || { log_fail "CUDA False — GPU CDI/runtime 점검"; return 1; }
  fi
}

report() {
  local user; user=$(whoami)
  cat <<EOF

=== 완료 보고 ===

- 본인 계정/UID. $user/$(id -u)
- SSH 포트. $SSH_PORT_TS
- 컨테이너. ${user}-dev (healthy)
- 외부 진입 명령. ssh -p $SSH_PORT_TS $user@$TAILSCALE_IP
EOF
  if [ $WANT_FT -eq 1 ]; then
    cat <<EOF
- finetune 이미지. devstack-finetune:$user (built)
- finetune 시작. cd $REPO_DIR && docker compose --profile ft up -d finetune
- finetune 진입. docker exec -it -u $user ${user}-finetune bash
- 학습 산출물. ~/Projects/dev-workspace/finetune-output/
- IDE 권장. Cursor → Remote-SSH (포트 $SSH_PORT_TS) → dev 안에서 코드, 실행은 위 compose 명령
EOF
  fi
}

main() {
  require_not_root
  parse_args "$@"
  log_info "사용자 셋업 시작 (gpu=$WANT_GPU ft=$WANT_FT)"
  load_bootstrap
  ensure_rootless_docker
  ensure_shell_env
  ensure_gpu
  ensure_repo_pulled
  render_env
  ensure_workspace
  compose_up_dev
  build_finetune
  verify_dev || die "dev 검증 실패"
  verify_gpu_and_ft || die "GPU/finetune 검증 실패"
  report
}

main "$@"
