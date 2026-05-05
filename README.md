<!-- DGX Spark 단독사용자 dev/finetune Docker 스택 사용 안내 -->
# dev-server_dkr

DGX Spark(NVIDIA GB10, ARM64+CUDA)에서 단독 사용자가 코딩(Python/Next.js/Supabase) + AI 파인튜닝을 동시에 굴리기 위한 Docker 스택.

호스트에 이미 동작 중인 **`temp_ollama-net`** bridge에 attach 하여 `ollama:11434`와 `whisper:8000`(OpenAI 호환 `/v1`)을 컨테이너 DNS로 직접 호출.

## 구성

- **`dev`** — 가벼운 코딩 컨테이너. devcontainer 베이스(Ubuntu 24.04) + uv + nvm Node 22 + pnpm + gh + supabase CLI + Docker CLI(호스트 소켓 마운트). VS Code Remote-SSH 진입.
- **`finetune`** — `nvcr.io/nvidia/pytorch:25.11-py3` 위에 transformers/peft/trl/accelerate 얹은 ML 컨테이너. `transformer_engine`(FP8), `flash_attn`, `nvidia-modelopt`, `torchao`는 base 사전 포함. `profiles: ["ft"]`라 기본 실행에서 빠짐.

## 사전 요건

- DGX Spark(또는 ARM64+NVIDIA) 호스트.
- Docker 28+ + NVIDIA 컨테이너 런타임.
- `temp_ollama-net` 외부 네트워크가 살아있어야 함 (`docker network ls`).
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
OLLAMA_BASE_URL=http://ollama:11434
OPENAI_API_BASE=http://ollama:11434/v1
OPENAI_API_KEY=ollama
WHISPER_BASE_URL=http://whisper:8000/v1
```

aider 예시(컨테이너 안에서).

```bash
uv tool install aider-chat
mkdir -p ~/.config/aider
cat > ~/.aider.conf.yml <<'YAML'
openai-api-base: http://ollama:11434/v1
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

## 다른 사용자가 이 repo를 재사용할 때

`USERNAME`이 build-arg 파라미터화돼있어 본인 환경에 맞게 재빌드만 하면 됨.

```bash
git clone <repo> && cd dev-server_dkr
cp .env.example .env
# .env 의 USERNAME, USER_UID, USER_GID, DOCKER_GID, TAILSCALE_IP 본인 값으로
docker compose build dev
docker compose up -d dev
```

이미지는 user-specific(host UID와 묶임)이므로 Docker Hub로 push하지 않는다. 각자 빌드.

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
