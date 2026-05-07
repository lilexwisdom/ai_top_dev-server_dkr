<!-- 일반 사용자가 본인 계정에서 dev 컨테이너를 띄우기 위한 빠른 안내. 손으로 따라하기 좋게 단계별. -->
# Quick Setup — 일반 사용자용 dev 컨테이너 셋업

DGX Spark에서 본인 계정으로 dev 컨테이너를 띄우는 가장 짧은 절차. 호스트 docker 그룹 가입 없이 본인 전용 rootless dockerd로 동작.

> 이 문서의 IP·사용자명·포트는 placeholder. 실제 값(Tailscale IP, LAN IP, 본인에게 할당된 SSH 포트)은 호스트 관리자(lilexwisdom)에게 별도 채널로 받기.

> Claude Code로 자동 진행하고 싶다면.
> 1. 본인 계정으로 호스트에 SSH 진입한 뒤
> 2. `git clone https://github.com/lilexwisdom/ai_top_dev-server_dkr.git ~/dev-server_dkr && cd ~/dev-server_dkr`
> 3. Claude Code 세션에서 한 줄 — `docs/user-rootless-setup.md를 읽고 절차대로 셋업해줘`
>
> 아래는 손으로 직접 따라할 때.

---

## 시작하기 전에

### 본인이 챙길 것

- [ ] 본인 노트북/PC에 SSH 공개키가 있음. 없으면 만들기 — `ssh-keygen -t ed25519`
- [ ] 호스트(DGX Spark)의 본인 계정으로 SSH 진입 가능. 안 되면 lilexwisdom에게 공개키 등록 요청

### 호스트 관리자(lilexwisdom)가 이미 처리한 것

본인이 따로 할 일 없음. 다음이 다 끝나있다고 가정. 만약 아래 절차 중 막히면 이 가정이 깨졌을 수 있으니 lilexwisdom에게 보고.

- 시스템 패키지(`docker-ce-rootless-extras`, `slirp4netns`, `uidmap`, `fuse-overlayfs`) 설치
- 본인 계정에 `loginctl enable-linger` 부여
- `/etc/cdi/nvidia.yaml` 생성 (GPU 사용 전제)
- 호스트의 whisper 컨테이너 publish (`127.0.0.1:8000`, `172.17.0.1:8000`)

### 본인 SSH 포트

사용자별 고정 포트로 분배 — 본인 포트는 호스트 관리자에게 받기. 아래 명령들에서 `<SSH_PORT>`로 표기된 부분을 본인 포트로 치환.

---

## 1단계 — 본인 계정으로 호스트 SSH 진입

본인 노트북에서.

```bash
ssh <YOUR_USER>@<HOST_IP>        # 호스트 IP는 관리자에게
```

**중요** — 반드시 직접 SSH로 들어와야 함. `su - <YOUR_USER>` 같은 방식은 systemd --user 세션이 없어서 다음 단계가 깨짐.

---

## 2단계 — Rootless Docker 설치 (1회)

```bash
dockerd-rootless-setuptool.sh install
systemctl --user enable --now docker
```

셸 환경 영구화.

```bash
echo 'export PATH=/usr/bin:$PATH' >> ~/.bashrc
echo 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock' >> ~/.bashrc
source ~/.bashrc
```

**검증** — 다음 한 줄이 `Rootless: true`를 출력해야 함.

```bash
docker info | grep "Rootless: true"
```

---

## 3단계 — GPU 활성화 (finetune이 필요할 때만)

dev 컨테이너만 쓸 거면 건너뜀.

```bash
nvidia-ctk runtime configure --runtime=docker --config=$HOME/.config/docker/daemon.json
systemctl --user restart docker
```

**검증** — `NVIDIA GB10`이 표에 나오면 OK. 처음 이미지 다운로드는 수 GB라 시간 걸림.

```bash
docker run --rm --device nvidia.com/gpu=all nvcr.io/nvidia/pytorch:25.11-py3 nvidia-smi
```

---

## 4단계 — repo clone

```bash
cd ~
git clone https://github.com/lilexwisdom/ai_top_dev-server_dkr.git dev-server_dkr
cd dev-server_dkr
cp .env.example .env
```

---

## 5단계 — `.env` 작성

`.env` 파일을 본인 값으로. 형식 예시(꺾쇠는 본인 값으로 치환).

```env
USERNAME=<YOUR_USER>
USER_UID=<id -u 결과>
USER_GID=<id -g 결과>
DOCKER_GID=<USER_GID와 동일>
DOCKER_SOCK=/run/user/<UID>/docker.sock
SSH_PORT_LOCAL=<할당된 포트>
SSH_PORT_TS=<할당된 포트>
TAILSCALE_IP=<관리자에게 받기>
LAN_IP=<관리자에게 받기>
```

값 산출.

- `USERNAME` — `whoami`
- `USER_UID` — `id -u`
- `USER_GID` — `id -g` (본인 환경에선 보통 USER_UID와 같음)
- `DOCKER_GID` — `id -g` 그대로 (rootless에선 본인 GID 사용)
- `DOCKER_SOCK` — `echo /run/user/$(id -u)/docker.sock`
- `SSH_PORT_LOCAL`, `SSH_PORT_TS` — 호스트 관리자가 알려준 본인 포트
- `TAILSCALE_IP`, `LAN_IP` — 호스트 관리자에게 받기

---

## 6단계 — 워크스페이스 / SSH 키 준비

```bash
mkdir -p ~/Projects/dev-workspace
mkdir -p ~/.ssh && chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys 2>/dev/null
```

**중요** — `~/.ssh/authorized_keys`에 본인 노트북 공개키가 들어 있어야 컨테이너로 SSH 진입 가능. 보통 호스트 진입에 쓰는 키와 같은 줄을 그대로 넣으면 됨. 비어있다면.

```bash
# 본인 노트북에서 한 번만
ssh-copy-id <YOUR_USER>@<HOST_IP>
```

---

## 7단계 — 빌드 & 기동

```bash
docker compose build dev
docker compose up -d dev
```

빌드는 첫 회 5~10분. 이미지가 nvm·uv·gh·supabase CLI 등을 다 내려받음.

기동 후 healthy 까지 잠깐 대기.

```bash
docker ps --filter name=$(whoami)-dev
# STATUS가 (healthy) 라야 함
```

---

## 8단계 — 검증

컨테이너 안에서 호스트의 ollama / whisper API에 도달하는지 확인.

```bash
docker exec $(whoami)-dev curl -s -o /dev/null -w "ollama:  %{http_code}\n" http://host.docker.internal:11434/api/tags
docker exec $(whoami)-dev curl -s -o /dev/null -w "whisper: %{http_code}\n" http://host.docker.internal:8000/v1/models
```

둘 다 `200` 이면 성공.

---

## 9단계 — 본인 노트북에서 외부 진입

```bash
ssh -p <SSH_PORT> <YOUR_USER>@<HOST_IP>
```

VS Code Remote-SSH도 같은 host string으로 접속.

---

## 10단계 — 본인 작업 프로젝트 clone

dev 컨테이너의 작업 영역은 호스트의 `~/Projects/dev-workspace`와 동일 경로로 1:1 마운트돼 있음. 본인 작업 repo는 거기에 두면 호스트와 컨테이너 양쪽에서 같은 경로로 보임.

```bash
# 호스트에서든 컨테이너 안에서든 어느 쪽이든 OK (같은 폴더)
cd ~/Projects/dev-workspace
git clone <본인 작업 repo URL>
```

컨테이너에 SSH 진입 후 작업 경로 — `/home/<USER>/Projects/dev-workspace/<프로젝트>`. VS Code Remote-SSH로도 같은 폴더 열기.

**주의**

- `dev-server_dkr`(이 인프라 repo)은 절대 `dev-workspace` 안에 두지 말 것. 별개로 호스트의 `~/dev-server_dkr`에 둔 채 호스트에서 직접 편집.
- `dev-workspace` 바깥의 호스트 폴더는 컨테이너에서 보이지 않음. 다른 사용자도 의존하는 공유 인프라(`ollama-whisper-webui_dkr` 등)를 사고로부터 보호하기 위한 격리.

이걸로 셋업 끝. 본인 프로젝트에서 작업 시작.

---

## (선택) finetune 컨테이너

3단계까지 통과한 사용자만.

```bash
docker compose --profile ft build finetune
docker compose --profile ft up -d finetune

# GPU 동작 확인
docker compose --profile ft run --rm finetune python -c \
  "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
# True NVIDIA GB10 이면 OK
```

---

## 막힐 때

| 증상 | 원인 / 대처 |
|------|------------|
| `dockerd-rootless-setuptool.sh: command not found` | 호스트 패키지 미설치. lilexwisdom에게 보고 |
| `Failed to connect to bus` | systemd --user 세션 없음. 직접 ssh로 본인 계정 진입했는지 확인 |
| `permission denied ... /var/run/docker.sock` | `DOCKER_HOST` 환경변수 적용 안 됨. 새 셸로 다시 진입 |
| `host.docker.internal` 해석 안 됨 | `git pull` 받았는지 확인. 그래도 없으면 보고 |
| `host.docker.internal:8000` 연결 거부 | 호스트의 whisper 죽었거나 publish 빠짐. 보고 |
| 포트 충돌 — `port is already allocated` | `.env`의 SSH 포트가 다른 사용자와 겹침. 본인 포트표 다시 확인 |
| 빌드 시 `authorized_keys` 에러 | `chmod 600 ~/.ssh/authorized_keys` |

해결 안 되는 문제는 어느 단계의 어떤 명령에서 무슨 출력이 떴는지 메모해서 lilexwisdom에게 알리면 더 빠름.
