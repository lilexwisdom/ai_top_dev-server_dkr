<!-- 신규 사용자가 노트북에서 SSH 키쌍을 만들고 dev/finetune 컨테이너까지 접속하는 절차 -->
# 사용자용 SSH 키 설정

dev/finetune 컨테이너에 접속하려면 **노트북에서 만든 공개키 한 줄** 을 admin 에게 전달해야 한다. 이 문서는 그 한 줄을 어떻게 만들고, 어떻게 보호하며, 어떻게 실제 접속까지 이어지는지 정리한다.

## 왜 키 인증인가

호스트 sshd 와 컨테이너 sshd 모두 `PasswordAuthentication no` 로 운영한다 (`dev/sshd_config:14`). 즉 비밀번호 로그인은 막혀 있고 공개키 인증만 통과한다.

## 한 키로 두 단계 통과

접속은 두 단계로 일어난다.

```
[노트북] --(:22)--> [호스트 OS 계정]  ← 호스트 sshd, ~/.ssh/authorized_keys
[노트북] --(:<SSH_PORT>)--> [dev 컨테이너]   ← 컨테이너 sshd, 같은 authorized_keys 가 ro 마운트
```

`docker-compose.yml:43` 이 호스트의 `~/.ssh/authorized_keys` 를 컨테이너 같은 경로로 read-only 바인드한다. 즉 **공개키 한 번 등록 = 두 단계 모두 통과** 다. 컨테이너에서 따로 등록할 필요 없음.

## 1) 노트북에서 키쌍 생성

이미 쓰는 키(`~/.ssh/id_ed25519`) 가 있으면 그걸 그대로 써도 된다. 새로 만든다면.

```bash
# 노트북(macOS/Linux/WSL)
ssh-keygen -t ed25519 -C "<USERNAME>@dgx-spark" -f ~/.ssh/id_ed25519_dgx
```

passphrase 는 비워도 동작하지만 **입력 권장**. 노트북이 털려도 키 단독으로는 못 쓰게 된다.

생성물.

| 파일 | 역할 | 어디에 두나 |
|---|---|---|
| `~/.ssh/id_ed25519_dgx` | **비공개키 (secret)** | **노트북에만**. 호스트·컨테이너·git·메신저 어디에도 복사 X |
| `~/.ssh/id_ed25519_dgx.pub` | **공개키 (public)** | admin 에게 한 줄 전달 |

권한 정렬.

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519_dgx
chmod 644 ~/.ssh/id_ed25519_dgx.pub
```

## 2) 공개키만 admin 에게 전달

```bash
cat ~/.ssh/id_ed25519_dgx.pub
# 출력 예. ssh-ed25519 AAAAC3Nz...XYZ <USERNAME>@dgx-spark
```

이 **한 줄** 을 슬랙·메일·DM 으로 admin 에게 보낸다.

> **중요. 비공개키(`~/.ssh/id_ed25519_dgx`) 는 절대 보내지 않는다.** 보낸 순간 그 키는 폐기 대상이다. admin 도 비공개키를 요구하지 않는다. 만약 요구받으면 잘못된 요청이니 거부할 것.

admin 에게서 응답으로 받을 정보.

- 호스트 IP (LAN 또는 Tailscale)
- 본인에게 할당된 SSH 포트 (예 `2225`)

## 3) admin 측 처리 (참고)

admin 은 받은 공개키를 `scripts/admin/add-user.sh` 로 등록한다. `install_authorized_key` (`scripts/admin/add-user.sh:146`) 가 자동으로.

- `~<USERNAME>/.ssh/` 디렉토리 0700 / 본인 소유로 생성
- `authorized_keys` 0600 / 본인 소유로 생성·append
- 중복 키 자동 감지 (멱등 — 같은 키 두 번 들어가지 않음)
- 포트 할당 (`/etc/devstack/port-registry.tsv`) 과 `.devstack-bootstrap` 작성

사용자가 직접 호스트 `authorized_keys` 를 편집할 필요는 없다.

## 4) 본인 노트북에서 접속

### (a) 호스트 진입 — 초기 셋업 1회

```bash
ssh -i ~/.ssh/id_ed25519_dgx <USERNAME>@<HOST_IP>
# 호스트에 들어와서
git clone https://github.com/lilexwisdom/ai_top_dev-server_dkr.git ~/dev-server_dkr
bash ~/dev-server_dkr/scripts/user/setup.sh           # dev 만
# 또는
bash ~/dev-server_dkr/scripts/user/setup.sh --gpu --ft   # finetune 까지
```

`setup.sh` 가 dev 컨테이너를 띄우고 마지막에 외부 진입 명령을 출력한다.

### (b) dev 컨테이너 직접 진입 — 평소 사용

```bash
ssh -i ~/.ssh/id_ed25519_dgx -p <SSH_PORT> <USERNAME>@<TAILSCALE_IP>
```

VS Code Remote-SSH / Cursor Remote-SSH 도 동일 host string 으로 접속.

## 5) `~/.ssh/config` 정리 권장

매번 `-i`, `-p` 를 치는 대신 노트북의 `~/.ssh/config` 에.

```sshconfig
Host dgx-host
  HostName <HOST_IP>
  User <USERNAME>
  IdentityFile ~/.ssh/id_ed25519_dgx
  IdentitiesOnly yes

Host dgx-dev
  HostName <TAILSCALE_IP>
  Port <SSH_PORT>
  User <USERNAME>
  IdentityFile ~/.ssh/id_ed25519_dgx
  IdentitiesOnly yes
```

이후. `ssh dgx-host` (호스트), `ssh dgx-dev` (컨테이너). VS Code/Cursor 에는 `dgx-dev` Host string 하나만 입력하면 된다.

> NVIDIA 사내망 환경의 NVSync 같은 별도 IdentityFile 이 추가로 필요한 경우도 있다 (`local-env.md` 의 lilexwisdom 사례 참고).

## 6) passphrase + ssh-agent

passphrase 를 걸어 둔 경우 매번 입력하지 않으려면 ssh-agent 에 한 번 로드.

```bash
# macOS
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_dgx
# Linux
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519_dgx
```

## 7) 다중 PC / 키 교체

- **새 PC 추가.** 그 PC 에서 새 키쌍을 만들고 공개키만 admin 에게 추가로 보낸다. `authorized_keys` 는 여러 줄 append 가능하므로 기존 키는 그대로 유지된다.
- **키 유출·분실.** admin 에게 해당 줄 삭제 + 새 키 등록을 요청한다. 컨테이너는 호스트 파일을 ro 마운트라 별도 작업 없이 자동 반영된다.
- **비공개키는 옮기지 않는다.** PC 마다 새로 만드는 편이 안전하다.

## 트러블슈팅

| 증상 | 흔한 원인 |
|---|---|
| `Permission denied (publickey)` 가 호스트 진입에서 뜸 | 잘못된 IdentityFile (`ssh -i ...` 또는 `~/.ssh/config` 확인) / admin 이 아직 등록 안 함 (`~/.devstack-bootstrap` 부재면 setup.sh 도 멈춤) / 호스트 `~/.ssh/authorized_keys` 가 0600 아닌 권한 |
| `Permission denied (publickey)` 가 컨테이너 진입에서만 뜸 | 호스트 sshd 는 통과했는데 dev 컨테이너만 막힌 경우. `docker compose up -d dev` 가 끝나기 전에 시도했거나 컨테이너 재기동 직후 sshd 가 아직 안 떴을 수 있다. 30초 후 재시도 |
| `Connection refused` | dev 컨테이너 미기동. 호스트로 먼저 들어가 `docker compose ps` 후 `up -d dev` |
| `Host key verification failed` | 컨테이너 재빌드 등으로 host key 가 바뀐 경우는 거의 없음(named volume `dev-sshd-keys`). 그래도 뜨면 노트북의 `~/.ssh/known_hosts` 에서 해당 라인 삭제 후 재시도 |
