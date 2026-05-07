<!-- 일반 사용자가 본인 계정에서 rootless docker 기반 dev/finetune 컨테이너를 셋업하기 위한 단계별 runbook. Claude Code가 읽고 그대로 실행 가능하도록 작성. -->
# 사용자 셋업 — Rootless Docker 기반 dev/finetune 컨테이너

> 이 문서를 읽고 있는 너는 Claude Code다. 사용자 본인의 일반 계정에서 본인 전용 dev 컨테이너를 띄우는 작업을 한다. 호스트 관리자(이하 "관리자")가 별도 채널로 사용자에게 전달한 값(Tailscale IP, LAN IP, 할당된 SSH 포트)이 있어야 .env 작성이 가능하다 — 사용자가 갖고 있지 않으면 멈추고 받아오라고 안내.

## 너에게 주는 지시

- 아래 Phase 0부터 Phase 6까지를 순서대로 실행한다. 필요 시 Phase 7(finetune)도.
- 각 Phase의 **검증** 명령이 통과해야 다음 Phase로 진행. 실패 시 그 자리에서 멈추고 사용자에게 무엇이 실패했는지 보고.
- 모든 명령은 사용자 본인의 셸에서 실행. **`sudo`가 필요한 명령이 나오면 즉시 멈추고 보고.** 호스트 측 셋업은 lilexwisdom이 이미 해 둔 상태라 `sudo`가 필요할 일이 없음. 만약 필요하면 이 문서의 가정이 깨진 것.
- `~/.config/docker/daemon.json`을 수동으로 편집하지 말 것. `nvidia-ctk runtime configure`가 안전하게 처리한다.
- 다른 사용자의 컨테이너/이미지/dockerd에 절대 접근하지 말 것. 본인 dockerd만 만진다 (`/run/user/$(id -u)/docker.sock`).
- Phase 진행 중 사용자에게 확인이 필요한 결정 지점이 나오면 멈추고 묻기. 임의 가정하지 말 것.
- 진행 상황은 `TaskCreate`로 추적. Phase 단위로 in_progress → completed.

## 배경 — 이 셋업의 큰 그림

- 호스트에는 lilexwisdom이 굴리는 docker daemon이 따로 돌고 있고, 거기서 ollama(:11434)와 whisper(:8000)가 떠 있다.
- 너의 사용자(이하 "본인")는 docker 그룹에 없고, 그 호스트 dockerd는 만질 수 없다.
- 대신 본인 계정에서 **rootless dockerd**를 굴린다. 이건 root 권한 없이 systemd --user 단위로 떠서, 본인 UID 네임스페이스 안에서 컨테이너를 격리 실행한다.
- 본인 컨테이너에서 ollama/whisper API는 **`host.docker.internal`** 로 호출한다 (호스트가 publish해 둔 포트로 도달). 컨테이너 DNS `ollama:11434` 같은 호출은 안 된다 (다른 dockerd의 bridge라서).
- dev 컨테이너에는 본인의 docker.sock(`/run/user/$UID/docker.sock`)이 마운트돼서, 컨테이너 안에서도 본인 dockerd를 부릴 수 있다.

## 환경 가정 (이미 충족됨, 검증만)

다음은 호스트 관리자가 이미 처리한 상태. 검증해서 5개 모두 OK가 아니면 멈추고 보고.

```bash
echo -n "1) rootless 패키지: "
dpkg -s docker-ce-rootless-extras slirp4netns uidmap fuse-overlayfs >/dev/null 2>&1 && echo OK || echo FAIL

echo -n "2) subuid/subgid: "
grep -q "^$USER:" /etc/subuid && grep -q "^$USER:" /etc/subgid && echo OK || echo FAIL

echo -n "3) 커널 userns: "
[ "$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null)" = "1" ] && echo OK || echo FAIL

echo -n "4) CDI nvidia 명세: "
[ -f /etc/cdi/nvidia.yaml ] && echo OK || echo FAIL

echo -n "5) linger: "
loginctl show-user $USER 2>/dev/null | grep -q "Linger=yes" && echo OK || echo FAIL
```

## Phase 0 — 본인 환경 변수 확보

```bash
echo "USERNAME=$USER"
echo "USER_UID=$(id -u)"
echo "USER_GID=$(id -g)"
echo "DOCKER_SOCK=/run/user/$(id -u)/docker.sock"
```

이 4개 값을 메모. Phase 4의 `.env` 작성에 그대로 사용.

**SSH 포트 할당** — 사용자별 고정 포트가 관리자에게 별도 통보돼 있음. 사용자에게 본인 포트를 물어보고 그 값을 메모. 모르겠다고 하면 멈추고 관리자에게 받아오라고 안내.

## Phase 1 — Rootless Docker 설치

```bash
dockerd-rootless-setuptool.sh install
systemctl --user enable --now docker
```

**검증**

```bash
systemctl --user is-active docker     # active 라야 함
ls -l /run/user/$(id -u)/docker.sock  # 본인 소유 소켓
```

`dockerd-rootless-setuptool.sh: command not found`가 뜨면 호스트 패키지가 없는 것. 환경 가정 검증에서 이미 잡혔어야 한다. 멈추고 보고.

## Phase 2 — 셸 환경 영구화

`~/.bashrc`에 다음 두 줄을 추가 (이미 있으면 추가하지 않음).

```bash
grep -q "DOCKER_HOST=unix:///run/user" ~/.bashrc || \
  echo 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock' >> ~/.bashrc

grep -q "^export PATH=/usr/bin:" ~/.bashrc || \
  echo 'export PATH=/usr/bin:$PATH' >> ~/.bashrc

source ~/.bashrc
```

**검증**

```bash
echo "$DOCKER_HOST"               # unix:///run/user/{본인 UID}/docker.sock
docker info 2>/dev/null | grep -E "^ Rootless: true" && echo OK || echo FAIL
docker run --rm hello-world | grep -q "Hello from Docker" && echo OK || echo FAIL
```

`Rootless: true`가 안 나오면 root daemon에 붙고 있는 것. `DOCKER_HOST` env가 현재 셸에 안 먹은 상태일 수 있음. 새 셸로 다시 시도하거나 `export DOCKER_HOST=...` 직접 설정.

## Phase 3 — Rootless GPU (finetune이 필요한 경우만)

dev 컨테이너만 쓸 거면 이 Phase 건너뛰고 Phase 4로. finetune이 필요하면 진행.

```bash
nvidia-ctk runtime configure --runtime=docker --config=$HOME/.config/docker/daemon.json
systemctl --user restart docker
```

**검증**

```bash
docker run --rm --device nvidia.com/gpu=all nvcr.io/nvidia/pytorch:25.11-py3 nvidia-smi 2>&1 | head -20
```

출력에 `NVIDIA GB10`이 보이면 OK. 처음 실행은 NGC 이미지가 수 GB라 다운로드에 시간 걸림. 다 받은 뒤 `nvidia-smi` 표가 나오면 통과.

## Phase 4 — repo clone과 .env 작성

```bash
cd ~
[ -d dev-server_dkr ] || \
  git clone https://github.com/lilexwisdom/ai_top_dev-server_dkr.git dev-server_dkr
cd dev-server_dkr
git pull --ff-only                    # 이미 clone돼 있어도 최신 동기화
[ -f .env ] || cp .env.example .env
```

`.env` 파일을 본인 값으로 작성. Phase 0에서 메모해 둔 값 사용.

```env
USERNAME=<본인 계정명>
USER_UID=<id -u 결과>
USER_GID=<id -g 결과>
DOCKER_GID=<USER_GID와 동일>
DOCKER_SOCK=/run/user/<UID>/docker.sock
SSH_PORT_LOCAL=<관리자에게 받은 포트>
SSH_PORT_TS=<관리자에게 받은 포트>
TAILSCALE_IP=<관리자에게 받기>
LAN_IP=<관리자에게 받기>
```

`USERNAME`/`USER_UID`/`USER_GID`/`DOCKER_GID`/`DOCKER_SOCK`은 Phase 0에서 직접 산출 가능. SSH 포트와 IP는 관리자가 별도 채널로 전달한 값을 사용.

작성 후 `.env`는 git에 안 올라가니 (gitignored) 안심하고 본인 환경 값을 그대로 둘 것.

## Phase 5 — 워크스페이스/SSH 키 준비

```bash
mkdir -p ~/Projects/dev-workspace
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[ -f ~/.ssh/authorized_keys ] && chmod 600 ~/.ssh/authorized_keys
```

`~/.ssh/authorized_keys`가 비어 있으면 컨테이너에 SSH로 못 들어가니, 본인의 클라이언트(노트북 등) 공개키를 거기 등록해야 함. 등록이 안 됐다면 사용자에게 공개키를 요청.

## Phase 6 — 빌드와 기동, 검증

```bash
docker compose build dev
docker compose up -d dev

# healthy 까지 대기 (최대 60초)
for i in $(seq 1 30); do
  s=$(docker inspect -f '{{.State.Health.Status}}' ${USER}-dev 2>/dev/null)
  [ "$s" = "healthy" ] && break
  sleep 2
done
echo "health=$s"
```

**검증**

```bash
docker exec ${USER}-dev curl -s -o /dev/null -w "ollama:    %{http_code}\n"  http://host.docker.internal:11434/api/tags
docker exec ${USER}-dev curl -s -o /dev/null -w "ollama/v1: %{http_code}\n"  http://host.docker.internal:11434/v1/models
docker exec ${USER}-dev curl -s -o /dev/null -w "whisper:   %{http_code}\n"  http://host.docker.internal:8000/v1/models
docker exec -u $USER ${USER}-dev docker ps --format '{{.Names}}' | head -5
```

세 줄 모두 200이고 `docker ps`가 본인 컨테이너 리스트(rootless dockerd가 보는 본인 컨테이너만)를 출력하면 dev 셋업 완료.

## Phase 7 — finetune (선택)

dev만 쓸 거면 생략. Phase 3을 통과한 사용자만 진행.

```bash
docker compose --profile ft build finetune
docker compose --profile ft up -d finetune

docker compose --profile ft run --rm finetune python -c \
  "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

출력이 `True NVIDIA GB10`이면 OK.

## SSH 외부 진입 검증 (사용자 본인 클라이언트에서)

```bash
ssh -p <SSH_PORT> $USER@<HOST_IP>
```

VS Code Remote-SSH 진입도 같은 host string.

## 흔한 실패와 대처

### `dockerd-rootless-setuptool.sh: command not found`
호스트 패키지 미설치. 환경 가정 검증 단계에서 잡혔어야 한다. 멈추고 lilexwisdom에게 보고.

### `Failed to connect to bus` 또는 `Could not connect: No such file or directory`
systemd --user 세션이 없는 상태. 보통 비대화형 ssh 또는 `su - <user>` 결과. 본인 계정으로 직접 ssh 진입한 셸에서 다시 시도. linger가 부여돼있는데도 발생하면 멈추고 보고.

### `permission denied while trying to connect to the Docker daemon socket /var/run/docker.sock`
환경변수 `DOCKER_HOST`가 안 먹은 상태에서 root daemon에 붙으려는 것. `echo $DOCKER_HOST`로 확인 후 비어있으면 Phase 2를 다시. 새 셸에서는 `source ~/.bashrc` 또는 재로그인 필요.

### `docker compose build` 시 authorized_keys 관련 에러
`~/.ssh/authorized_keys` 권한 문제. `chmod 600 ~/.ssh/authorized_keys`로 정렬.

### 컨테이너에서 `host.docker.internal: name does not resolve`
compose의 `extra_hosts: - "host.docker.internal:host-gateway"` 줄이 빠진 것. `git pull --ff-only`로 최신 main 받았는지 확인. 그래도 없으면 보고.

### `host.docker.internal:8000` connection refused
호스트의 whisper 컨테이너가 죽었거나 publish가 빠진 것. 멈추고 lilexwisdom에게 보고 (사용자 권한으로 호스트 dockerd를 만질 수 없음).

### finetune `--device nvidia.com/gpu=all` 에러
CDI가 본인 dockerd에 안 등록된 것. Phase 3을 다시. `docker info | grep -A2 -i runtime` 출력에 `nvidia` 런타임이 보여야 함.

### 포트 충돌 — `Bind for <HOST_IP>:<PORT> failed: port is already allocated`
다른 사용자가 같은 포트로 이미 떠 있는 것. SSH 포트 할당표 다시 확인하고 본인 포트로 `.env` 수정.

## 완료 보고 양식

셋업이 끝나면 사용자에게 다음 항목을 보고.

```
- 본인 계정/UID: <USER>/<UID>
- SSH 포트: <PORT>
- 컨테이너: ${USER}-dev (healthy)
- API 검증
  - ollama  http://host.docker.internal:11434  → 200
  - whisper http://host.docker.internal:8000   → 200
- finetune 셋업: <yes/no>  (yes면 nvidia-smi 결과 1줄)
- 외부 진입 명령: ssh -p <PORT> <USER>@<HOST_IP>
```

이 보고를 사용자가 받으면 본인 클라이언트에서 ssh로 진입해서 본격 작업 시작 가능.
