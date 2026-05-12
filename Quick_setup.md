<!-- 신규 사용자가 dev/finetune 컨테이너를 띄우기 위한 진입점. 자동화 스크립트 호출 안내 + 막힐 때 fallback. -->
# Quick Setup — dev/finetune 컨테이너 셋업

DGX Spark 본인 계정에서 dev(필요 시 finetune) 컨테이너를 띄우는 자동 셋업.

## 사전 — 관리자(lilexwisdom)가 본인 계정을 등록해야 함

본인이 받는 안내.

- 호스트 IP (관리자에게 받기)
- 본인 SSH 포트 (예 2229) — 관리자가 `add-user.sh` 로 할당
- Tailscale IP — 관리자가 부트스트랩에 주입

관리자가 등록을 안 했다면 본인 노트북 공개키 1줄을 관리자에게 전달하고 등록 요청.

> 공개키 만들고 전달하는 법 (ssh-keygen, ~/.ssh/config, passphrase 등) 은 [`docs/user-ssh-keys.md`](docs/user-ssh-keys.md) 참조. 비공개키는 절대 보내지 말 것.

## 1) 호스트에 SSH 진입 + repo clone

```bash
# 본인 노트북에서
ssh <YOUR_USER>@<HOST_IP>
git clone https://github.com/lilexwisdom/ai_top_dev-server_dkr.git ~/dev-server_dkr
```

## 2) 자동 셋업 — 둘 중 하나

**dev 만 — 코딩 IDE 용도.**

```bash
bash ~/dev-server_dkr/scripts/user/setup.sh
```

**dev + finetune — GPU 학습까지 필요.**

```bash
bash ~/dev-server_dkr/scripts/user/setup.sh --gpu --ft
```

스크립트가 자동으로. rootless dockerd 설치 → `.bashrc` 갱신 → (옵션) GPU 활성화 → `.env` 렌더 → 워크스페이스/SSH 준비 → `docker compose build/up dev` → healthy 폴링 → (옵션) finetune 이미지 빌드 + CUDA 스모크 → 검증 표 출력.

멱등 — 두 번 돌려도 `[skip]` 으로 끝남.

## 3) 본인 노트북에서 컨테이너 진입

스크립트가 마지막에 출력하는 `외부 진입 명령` 그대로.

```bash
ssh -p <SSH_PORT> <YOUR_USER>@<TAILSCALE_IP>
```

VS Code Remote-SSH / Cursor Remote-SSH 도 같은 host string.

## fine-tune 사용 흐름

**패턴 A (권장) — Cursor 는 dev 에 붙고 실행은 finetune.**

Cursor 를 SSH 포트(`<SSH_PORT>`) 로 dev 에 attach. dev 안에서 코드 작성·AI 사용. 학습 실행은 dev 내 터미널에서.

```bash
docker compose --profile ft run --rm finetune python train.py
# 또는 장기 세션. up -d 후 docker exec
docker compose --profile ft up -d finetune
docker exec -it -u $(whoami) $(whoami)-finetune bash
```

dev 컨테이너에 호스트 dockerd 의 socket 이 마운트돼 있어 위 명령들이 dev 안에서도 동작. 학습 산출물은 `~/Projects/dev-workspace/finetune-output/<run-name>/` 에 둘 것 (dev/finetune 양쪽에서 같은 경로로 보임).

**패턴 B (부가) — 깊은 ML 코딩 세션에 한정.**

Cursor 를 finetune 에 직접 attach 하면 transformers/peft/trl 의 정적 분석·자동완성이 정확해진다. 단점 — 세션 동안 GPU 자원 점유. 사용 빈도가 높지 않으면 패턴 A 권장.

방법. Cursor → "Remote-SSH" 로 호스트 (`<HOST_IP>` 포트 22) 진입 → 좌하단 ❯❮ → "Attach to Running Container..." → `<USER>-finetune` 선택.

## 막힐 때

| 증상 | 해결 |
|------|------|
| `.devstack-bootstrap 없음` | 관리자가 add-user.sh 등록 안 함. 본인 등록 요청. |
| `dockerd-rootless-setuptool.sh: command not found` | 호스트 패키지 미설치. 관리자에게 host-bootstrap.sh 재실행 요청. |
| `Failed to connect to bus` | systemd --user 세션 없음. `su - <user>` 대신 직접 `ssh user@host` 로 진입. |
| `port is already allocated` | 다른 사용자가 같은 포트로 떠 있음. 관리자에게 신규 포트 재할당 요청. |
| `host.docker.internal: name does not resolve` | `git pull --ff-only` 후 재시도. 그래도 안 되면 보고. |
| `Permission denied (publickey)` | 노트북 IdentityFile 확인. admin 에 공개키 등록 요청. 상세는 [`docs/user-ssh-keys.md`](docs/user-ssh-keys.md). |

손으로 따라가야 하는 상황(자동화 깨짐, 단계 이해 필요)이면 [`docs/manual-setup.md`](docs/manual-setup.md) 또는 [`docs/user-rootless-setup.md`](docs/user-rootless-setup.md) 참조.
