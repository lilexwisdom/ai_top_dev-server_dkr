<!-- DGX Spark dev/finetune Docker 스택 사용 안내 (다중 사용자 지원) -->
# dev-server_dkr

DGX Spark(NVIDIA GB10, ARM64+CUDA)에서 코딩(Python/Next.js/Supabase) + AI 파인튜닝을 굴리기 위한 Docker 스택.

호스트의 ollama/whisper 컨테이너가 publish한 포트를 **`host.docker.internal`** 로 호출. 이 방식으로 호스트 dockerd 사용자(lilexwisdom)와 일반 사용자별 rootless dockerd가 동일 compose로 동작.

## 구성

- **`dev`** — 가벼운 코딩 컨테이너. devcontainer 베이스(Ubuntu 24.04) + uv + nvm Node 22 + pnpm + gh + supabase CLI + Docker CLI(호스트 소켓 마운트). VS Code Remote-SSH 진입.
- **`finetune`** — `nvcr.io/nvidia/pytorch:25.11-py3` 위에 transformers/peft/trl/accelerate 얹은 ML 컨테이너. `transformer_engine`(FP8), `flash_attn`, `nvidia-modelopt`, `torchao`는 base 사전 포함. `profiles: ["ft"]`라 기본 실행에서 빠짐.

## 사전 요건

- DGX Spark(또는 ARM64+NVIDIA) 호스트.
- Docker 28+ + NVIDIA 컨테이너 런타임.
- 호스트의 `ollama` 컨테이너가 `:11434`, `whisper` 컨테이너가 `127.0.0.1:8000`로 publish 돼있어야 함.
- 호스트 `~/.ssh/authorized_keys`에 본인 공개키 등록.
- Tailscale 또는 LAN을 통해 접근 가능한 IP.

## 초기 설치

```bash
git clone <repo> && cd dev-server_dkr
cp .env.example .env
# .env 수정: USERNAME, USER_UID(`id -u`), USER_GID(`id -g`),
#           DOCKER_GID(`getent group docker | cut -d: -f3`),
#           TAILSCALE_IP / LAN_IP

docker compose build dev
docker compose up -d dev
```

기동 후 호스트 측에서.

```bash
ss -ltn | grep 2222   # 127.0.0.1과 ${TAILSCALE_IP}만 보여야 함
```

본인 클라이언트(노트북 등)에서.

```bash
ssh -p 2222 <USERNAME>@<TAILSCALE_IP>
```

VS Code Remote-SSH는 같은 host string으로 접속.

## AI 코딩 도구 연동

dev 컨테이너에 OpenAI 호환 환경변수가 미리 주입돼 있음.

```
OLLAMA_BASE_URL=http://host.docker.internal:11434
OPENAI_API_BASE=http://host.docker.internal:11434/v1
OPENAI_API_KEY=ollama
WHISPER_BASE_URL=http://host.docker.internal:8000/v1
```

aider 예시(컨테이너 안에서).

```bash
uv tool install aider-chat
mkdir -p ~/.config/aider
cat > ~/.aider.conf.yml <<'YAML'
openai-api-base: http://host.docker.internal:11434/v1
openai-api-key: ollama
model: openai/gemma4:e4b
YAML
aider <파일들>
```

Continue/Cline/Roo Code 등 VS Code 확장도 같은 base URL을 쓰면 됨.

## 파인튜닝

평소엔 미기동 상태. 필요 시 단발 실행.

```bash
docker compose --profile ft run --rm finetune python train.py
```

장기 세션이 필요하면 `up -d` 후 `exec`.

```bash
docker compose --profile ft up -d finetune
docker exec -it -u ${USERNAME} ${USERNAME}-finetune bash
```

### IDE 사용 흐름 — 패턴 A 권장, B 부가

**패턴 A (권장).** Cursor/VS Code 는 SSH 포트로 **dev 컨테이너** 에 Remote-SSH. 코드 편집·AI 기능은 dev 에서, 학습 실행은 dev 내 터미널의 `docker compose --profile ft run --rm finetune ...`. dev 는 24/7 살아있어 재접속 부담 0, GPU 점유는 학습 중에만. 워크스페이스(`~/Projects/dev-workspace`)는 dev/finetune 양쪽 모두 마운트되므로 파일이 즉시 공유.

한계 — dev 에 transformers/peft/trl 미설치라 정적 import 분석 약함(Cursor AI 자체는 영향 없음, IDE 의 빨간줄만 표시).

**패턴 B (부가).** 정밀 ML 코딩 세션(트레이너 클래스 커스터마이즈 등) 시 Cursor 의 "Remote-SSH → Attach to Running Container" 로 **finetune 에 직접 attach**. Python intellisense 완벽. 단점 — 세션 동안 GPU 점유, `restart: "no"` 라 매번 `compose up` 선행. 4–5명 공유 GPU 에선 짧은 정밀 작업에 한정 권장.

### 학습 산출물 컨벤션

체크포인트/모델은 `~/Projects/dev-workspace/finetune-output/<run-name>/` 에 저장. dev 와 finetune 양쪽에서 같은 경로로 보이므로 산출물 후처리(merge, GGUF 변환 등)는 dev 에서 이어서 가능.

GPU·라이브러리 점검.

```bash
docker compose --profile ft run --rm finetune python -c \
  "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
# True NVIDIA GB10
```

DGX Spark/GB10 효율 활용 팁.

- **FP8 학습** — `accelerate launch --mixed_precision=fp8 train.py`. transformer_engine 자동 사용.
- **양자화 QLoRA** — bitsandbytes 대신 `nvidia-modelopt` 또는 `torchao.quantization.quantize_` 사용. ARM64 휠 이슈 없음.
- **`torch.compile(model)`** — Inductor + Triton 사전 설치. 한 줄로 큰 속도 이득.
- **CPU offload 적극 사용** — Grace+Blackwell unified memory(LPDDR5X 128GB)라 offload 비용이 거의 0.

### Ollama로 export 흐름

1. `merge_and_unload()`로 PEFT adapter merge → safetensors.
2. `llama.cpp/convert_hf_to_gguf.py`로 GGUF 변환 + `quantize`.
3. `Modelfile` 작성 후 dev 컨테이너에서.

```bash
docker exec -i ollama ollama create my-finetuned -f - < Modelfile
```

(dev 컨테이너에 호스트 docker.sock이 마운트돼있으므로 가능)

## 워크스페이스 격리

dev/finetune 컨테이너는 호스트의 `~/Projects` 전체가 아닌 **`~/Projects/dev-workspace`만** bind mount한다. 이유.

- 호스트의 `~/Projects` 안에 다른 사용자도 의존하는 공유 인프라(`ollama-whisper-webui_dkr` 등)가 있어 컨테이너에서 실수로 손상시킬 위험이 큼.
- dev-workspace 외에는 컨테이너에서 보이지도 않으므로 `rm -rf` 같은 사고를 원천 차단.
- 컨테이너 안에서 호스트 컨테이너 운영(ollama 재시작, 모델 추가 등)은 마운트된 `docker.sock`을 통해 그대로 가능.

호스트에서 `mkdir -p ~/Projects/dev-workspace` 한 번 만들고, 새 프로젝트는 처음부터 그 안에서 git clone. dev-server_dkr 자체(이 인프라 repo)는 호스트에서 직접 편집(컨테이너에 마운트 X).

## 외부 노출 정책

기본 SSH 포트 매핑.

```
${TAILSCALE_IP}:${SSH_PORT_TS}  — Tailscale 메시 (호스트 자기 자신에서도 같은 IP로 접속됨)
```

`127.0.0.1` 별도 publish는 안 함. rootless docker(rootlesskit-builtin)가 같은 host port를 두 IP에 동시 publish 못하는 limitation 때문에 dual-binding을 피했음. 호스트 자기 자신에서도 `ssh -p ${SSH_PORT_TS} <USER>@${TAILSCALE_IP}`로 접속 가능 (Tailscale이 자기 IP를 로컬 라우팅).

LAN까지 허용하려면 `docker-compose.yml`의 `${LAN_IP}` 줄 주석 해제. 단, `${TAILSCALE_IP}`와 동일 포트면 rootless에서 충돌하므로 `SSH_PORT_LAN`을 별도 포트로 쓰기. Caddy(HTTPS) 경유는 안 함 — 단독 사용자라 도메인/TLS 불필요.

**중요**. Docker `ports:`는 호스트 ufw를 우회한다. 인터페이스 바인딩 자체가 1차 방어선이므로 절대 `0.0.0.0:`로 바꾸지 말 것.

## 같은 호스트의 일반 사용자가 본인 계정에서 띄울 때 (rootless docker)

호스트 docker 그룹에 추가하지 않고, 각 사용자가 본인 systemd --user 단위로 개별 dockerd를 굴리는 방식. 호스트 dockerd는 무손상. 셋업은 두 스크립트로 자동화.

### 1) 머신 첫 셋업 — admin, 1회만

```bash
sudo bash scripts/admin/host-bootstrap.sh
```

rootless docker 의존 패키지(`docker-ce-rootless-extras`, `slirp4netns`, `uidmap`, `fuse-overlayfs`, `nvidia-container-toolkit`) 설치, `/etc/cdi/nvidia.yaml` 생성, `/etc/devstack/` 레지스트리(`port-registry.tsv`, `users.tsv`, `host-network.env`) 초기화. 멱등.

이후 `/etc/devstack/host-network.env` 의 `TAILSCALE_IP=` 한 줄을 본인 머신의 Tailscale IP 로 채워 두면 신규 사용자 추가 시 자동 주입.

별도로 호스트 dockerd 의 whisper 컨테이너가 publish 돼 있어야 함 (rootless 사용자가 host.docker.internal 로 도달하는 경로).

```yaml
# ollama-whisper-webui_dkr/docker-compose.yml 의 whisper.ports
# - "127.0.0.1:8000:8000"
# - "172.17.0.1:8000:8000"
```

### 2) 사용자 추가 — admin, 사용자별 1회

호스트 OS 계정은 이미 생성됐다고 가정(`sudo adduser <username>` 별도). 사용자 노트북 공개키 1줄을 받아서.

```bash
# 옵션 A — pubkey 파일 경로
sudo bash scripts/admin/add-user.sh <username> /tmp/<username>.pub

# 옵션 B — stdin (파이프)
cat ~/keys/<username>.pub | sudo bash scripts/admin/add-user.sh <username> -

# 이미 동작 중인 사용자를 레지스트리에만 backfill (재셋업 안 함)
sudo bash scripts/admin/add-user.sh <username> --backfill-only <port>
```

linger 활성 → subuid/subgid 확인 → 포트 자동 할당(`/etc/devstack/port-registry.tsv` + flock) → `~<user>/.ssh/authorized_keys` append → `~<user>/.devstack-bootstrap` 작성. 마지막에 사용자에게 안내할 한 줄 출력.

### 3) 사용자 본인 셋업 — 사용자 셸에서 1회

```bash
ssh <YOUR_USER>@<HOST_IP>
git clone https://github.com/lilexwisdom/ai_top_dev-server_dkr.git ~/dev-server_dkr
bash ~/dev-server_dkr/scripts/user/setup.sh           # dev 만
# 또는
bash ~/dev-server_dkr/scripts/user/setup.sh --gpu --ft   # finetune 까지
```

스크립트가 자동으로. `dockerd-rootless-setuptool.sh install` → `systemctl --user enable --now docker` → `.bashrc` 의 `DOCKER_HOST`/`PATH` → (옵션) GPU 활성화 → `.env` 자동 렌더 → `~/Projects/dev-workspace` 생성 → `docker compose build/up dev` → healthy 폴링 → (옵션) finetune 이미지 빌드 + CUDA 스모크 → 검증·완료 보고. 멱등(두 번 돌리면 모두 `[skip]`).

> 손으로 따라가야 할 때 (자동화 깨짐, 단계 이해 필요) 는 [`Quick_setup.md`](Quick_setup.md), [`docs/manual-setup.md`](docs/manual-setup.md) 또는 [`docs/user-rootless-setup.md`](docs/user-rootless-setup.md).

이미지는 user-specific(host UID와 묶임)이라 사용자별로 빌드. image tag(`devstack-dev:${USERNAME}`)와 container_name(`${USERNAME}-dev`)이 사용자별로 분리되므로 같은 호스트에서 다중 사용자가 충돌 없이 동시 운영 가능.

## 디렉토리

```
dev-server_dkr/
├── docker-compose.yml
├── .env.example
├── .gitignore
├── README.md
├── Quick_setup.md          # 신규 사용자 진입점 (자동화 wrapper)
├── checklist.md            # 작업 체크리스트
├── context-notes.md        # 결정·근거·함정 기록
├── dev/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── sshd_config
├── finetune/
│   └── Dockerfile
├── docs/
│   ├── manual-setup.md         # 아카이브 — 손 셋업 가이드
│   └── user-rootless-setup.md  # Claude Code runbook (fallback)
└── scripts/
    ├── lib/common.sh           # 공통 헬퍼 (log, kv_upsert, flock)
    ├── admin/
    │   ├── host-bootstrap.sh   # 머신 1회 root 셋업
    │   └── add-user.sh         # 사용자 추가 시 root 셋업
    └── user/setup.sh           # 사용자 본인 1회 셋업 (--gpu --ft)
```

## 참고 핀

- dev 베이스 — `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`
- finetune 베이스 — `nvcr.io/nvidia/pytorch:25.11-py3`
- Node — `22.11.0` (nvm 0.40.3)
- Supabase CLI — `2.98.1`
- transformers — `>=4.46,<5` (5.x는 hub 1.x ABI 불일치 보고)
