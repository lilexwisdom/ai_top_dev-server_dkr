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
docker exec -it -u ${USERNAME} finetune bash
```

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
127.0.0.1:2222   — 호스트 자기 자신
${TAILSCALE_IP}:2222 — Tailscale 메시
```

LAN까지 허용하려면 `docker-compose.yml`의 `${LAN_IP}:2222:22` 주석 해제. Caddy(HTTPS) 경유는 안 함 — 단독 사용자라 도메인/TLS 불필요.

**중요**. Docker `ports:`는 호스트 ufw를 우회한다. 인터페이스 바인딩 자체가 1차 방어선이므로 절대 `0.0.0.0:`로 바꾸지 말 것.

## 같은 호스트의 일반 사용자가 본인 계정에서 띄울 때 (rootless docker)

호스트 docker 그룹에 추가하지 않고, 각 사용자가 본인 systemd --user 단위로 개별 dockerd를 굴리는 방식. 호스트 dockerd는 무손상.

> 손으로 따라할 거면 [`Quick_setup.md`](Quick_setup.md). Claude Code로 자동 진행할 거면 [`docs/user-rootless-setup.md`](docs/user-rootless-setup.md) (검증 포함 runbook).

### 한 번만 — 시스템 관리자 (lilexwisdom 또는 root)

```bash
# rootless docker 의존 패키지 + linger
sudo apt install -y docker-ce-rootless-extras slirp4netns uidmap fuse-overlayfs
sudo loginctl enable-linger <username1> <username2> ...

# 호스트 dockerd의 whisper에 publish 추가 (ollama-whisper-webui_dkr/docker-compose.yml의 whisper에)
# - 127.0.0.1: rootless docker 사용자 (slirp4netns가 호스트 lo로 매핑)
# - 172.17.0.1: 호스트 dockerd 사용자 (docker0 게이트웨이) — `ip -4 addr show docker0`로 확인
#   ports:
#     - "127.0.0.1:8000:8000"
#     - "172.17.0.1:8000:8000"
# 그 후. cd ~/Projects/ollama-whisper-webui_dkr && docker compose up -d whisper

# rootless GPU 전제 (finetune 사용자가 있으면)
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

### 사용자별 — 본인 셸에서 1회

```bash
# rootless dockerd 설치
dockerd-rootless-setuptool.sh install
systemctl --user enable --now docker

# 셸 환경 (영구화)
echo 'export PATH=/usr/bin:$PATH' >> ~/.bashrc
echo 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock' >> ~/.bashrc
source ~/.bashrc
docker info | grep -E "Rootless|Cgroup"      # Rootless: true 확인

# (finetune 필요 시) GPU 활성화
nvidia-ctk runtime configure --runtime=docker --config=$HOME/.config/docker/daemon.json
systemctl --user restart docker
docker run --rm --device nvidia.com/gpu=all nvcr.io/nvidia/pytorch:25.11-py3 nvidia-smi

# repo clone & 첫 기동
cd ~ && git clone <repo> dev-server_dkr && cd dev-server_dkr
cp .env.example .env
# .env에 본인 값 작성
#   USERNAME=<본인 계정명>
#   USER_UID=<id -u>
#   USER_GID=<id -g>
#   DOCKER_GID=<id -g>                         # rootless라 본인 GID
#   DOCKER_SOCK=/run/user/$(id -u)/docker.sock
#   SSH_PORT_LOCAL=<관리자에게 받은 포트>      # 사용자별 분배
#   SSH_PORT_TS=<관리자에게 받은 포트>
#   TAILSCALE_IP=<관리자에게 받기>             # 호스트 단위라 모두 동일

mkdir -p ~/Projects/dev-workspace
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# ~/.ssh/authorized_keys 본인 공개키 등록 필수

docker compose build dev
docker compose up -d dev

# finetune이 필요한 경우
docker compose --profile ft build finetune
docker compose --profile ft up -d finetune
```

이미지는 user-specific(host UID와 묶임)이라 사용자별로 빌드. image tag(`devstack-dev:${USERNAME}`)와 container_name(`${USERNAME}-dev`)이 사용자별로 분리되므로 같은 호스트에서 다중 사용자가 충돌 없이 동시 운영 가능.

## 디렉토리

```
dev-server_dkr/
├── docker-compose.yml
├── .env.example
├── .gitignore
├── README.md
├── checklist.md            # 작업 체크리스트
├── context-notes.md        # 결정·근거·함정 기록
├── dev/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── sshd_config
└── finetune/
    └── Dockerfile
```

## 참고 핀

- dev 베이스 — `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`
- finetune 베이스 — `nvcr.io/nvidia/pytorch:25.11-py3`
- Node — `22.11.0` (nvm 0.40.3)
- Supabase CLI — `2.98.1`
- transformers — `>=4.46,<5` (5.x는 hub 1.x ABI 불일치 보고)
