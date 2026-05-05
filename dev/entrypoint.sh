#!/usr/bin/env bash
# sshd 호스트 키 생성/권한 보정 후 sshd를 foreground로 실행
set -euo pipefail

KEYDIR=/etc/ssh/keys
mkdir -p "${KEYDIR}"

# 호스트 키가 없으면 생성 (named volume 최초 마운트 시).
if [ ! -f "${KEYDIR}/ssh_host_ed25519_key" ]; then
  ssh-keygen -t ed25519 -N '' -f "${KEYDIR}/ssh_host_ed25519_key" >/dev/null
fi
if [ ! -f "${KEYDIR}/ssh_host_rsa_key" ]; then
  ssh-keygen -t rsa -b 4096 -N '' -f "${KEYDIR}/ssh_host_rsa_key" >/dev/null
fi
chmod 600 "${KEYDIR}"/ssh_host_*_key
chmod 644 "${KEYDIR}"/ssh_host_*_key.pub

# authorized_keys 권한 보정 (ro 마운트지만 부모 디렉토리 권한은 컨테이너 책임).
USER_HOME=$(eval echo "~${USERNAME:-dev}")
if [ -d "${USER_HOME}/.ssh" ]; then
  chmod 700 "${USER_HOME}/.ssh" || true
fi
if [ -f "${USER_HOME}/.ssh/authorized_keys" ]; then
  # ro 마운트면 chmod 실패해도 무시.
  chmod 600 "${USER_HOME}/.ssh/authorized_keys" 2>/dev/null || true
fi

mkdir -p /var/run/sshd

exec /usr/sbin/sshd -D -e
