# DGX Spark(ARM64+CUDA) 단독사용자 dev 컨테이너 — VS Code Remote-SSH 진입점
# syntax=docker/dockerfile:1.7

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG DOCKER_GID=988
ARG NODE_VERSION=22.11.0
ARG NVM_VERSION=v0.40.3
ARG SUPABASE_CLI_VERSION=2.98.1

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Seoul \
    USERNAME=${USERNAME}

# 시스템 도구 + sshd
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server git curl wget ca-certificates gnupg lsb-release \
        build-essential pkg-config \
        ripgrep fd-find fzf jq unzip zsh tmux less locales tzdata iproute2 \
        python3 python3-venv python3-pip python-is-python3 \
        sudo \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && echo ${TZ} > /etc/timezone \
 && rm -rf /var/lib/apt/lists/*

# devcontainer 베이스의 기본 vscode 사용자(UID 1000)와 충돌 회피.
# 기본 vscode 사용자 제거 후, 호스트와 일치하는 ${USERNAME}/${USER_UID}로 신규 생성.
RUN if id -u vscode >/dev/null 2>&1; then userdel -r vscode 2>/dev/null || true; fi \
 && groupadd -g ${USER_GID} ${USERNAME} 2>/dev/null || true \
 && useradd -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash ${USERNAME} \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
 && chmod 0440 /etc/sudoers.d/${USERNAME}

# 호스트 docker 그룹 GID와 일치하는 그룹 추가 후 사용자 가입 (호스트 docker.sock 접근용).
# DOCKER_GID == USER_GID인 경우(rootless dockerd 사용자 패턴)에는 socket이 본인 소유라
# 별도 그룹 가입이 불필요. 이때 같은 GID로 그룹을 또 만들면 충돌하므로 skip.
RUN if [ "${DOCKER_GID}" != "${USER_GID}" ]; then \
      if ! getent group ${DOCKER_GID} >/dev/null; then \
        groupadd -g ${DOCKER_GID} hostdocker; \
      fi; \
      existing=$(getent group ${DOCKER_GID} | cut -d: -f1); \
      usermod -aG "${existing}" ${USERNAME}; \
    fi

# uv (Python 패키지/벤브 통합 도구, ARM64 정적 바이너리)
RUN curl -LsSf https://astral.sh/uv/install.sh \
      | env UV_INSTALL_DIR=/usr/local/bin sh

# GitHub CLI (공식 apt repo, arm64)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=arm64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Supabase CLI (정적 바이너리 .deb, ARM64). 파일명에 버전이 포함되므로 핀 처리.
RUN curl -fsSL -o /tmp/supabase.deb \
      "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/supabase_${SUPABASE_CLI_VERSION}_linux_arm64.deb" \
 && dpkg -i /tmp/supabase.deb && rm /tmp/supabase.deb

# Docker CLI 만 설치 (호스트 데몬 소켓 마운트 경유 사용)
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-compose-plugin docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

# sshd 설정 + 호스트 키 디렉토리
COPY sshd_config /etc/ssh/sshd_config
RUN mkdir -p /etc/ssh/keys /var/run/sshd /home/${USERNAME}/.ssh \
 && chmod 700 /home/${USERNAME}/.ssh \
 && chown -R ${USER_UID}:${USER_GID} /home/${USERNAME}/.ssh

# Node via nvm (사용자 홈에 설치, NODE_VERSION 핀)
USER ${USERNAME}
ENV NVM_DIR=/home/${USERNAME}/.nvm \
    NODE_VERSION=${NODE_VERSION}
RUN mkdir -p ${NVM_DIR} \
 && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash \
 && . ${NVM_DIR}/nvm.sh \
 && nvm install ${NODE_VERSION} \
 && nvm alias default ${NODE_VERSION} \
 && npm install -g pnpm \
 && nvm cache clear
ENV PATH=${NVM_DIR}/versions/node/v${NODE_VERSION}/bin:$PATH

USER root

# entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
