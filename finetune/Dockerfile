# DGX Spark(GB10) ARM64+CUDA 파인튜닝 컨테이너 — transformers/peft/trl 작업용
# syntax=docker/dockerfile:1.7

FROM nvcr.io/nvidia/pytorch:25.11-py3

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# 추가 시스템 의존
RUN apt-get update && apt-get install -y --no-install-recommends \
        git git-lfs ffmpeg sudo \
 && git lfs install --system \
 && rm -rf /var/lib/apt/lists/*

# HF 스택. NGC 25.11 base에 datasets/huggingface_hub/tokenizers가 사전 포함되며,
# torch/transformer_engine/flash_attn/apex/nvidia-modelopt/torchao 등도 사전 포함이라
# pip가 알아서 보존한다(이들이 transformers의 dependency가 아니므로 건드리지 않음).
# transformers는 안정성 위해 4.x LTS 라인으로 핀. hub 1.x 비호환 회피.
RUN pip install --no-cache-dir \
        "transformers>=4.46,<5" \
        "accelerate>=1.0" \
        "peft>=0.13" \
        "trl>=0.11" \
        "sentencepiece>=0.2" \
        "einops>=0.8" \
        "wandb" "evaluate"

# NGC base에 사전 존재하는 UID/GID 1000 사용자 제거 후, 호스트와 일치하는 ${USERNAME} 생성
RUN existing=$(getent passwd ${USER_UID} | cut -d: -f1) ; \
    if [ -n "${existing}" ]; then userdel -r "${existing}" 2>/dev/null || true; fi && \
    existing_grp=$(getent group ${USER_GID} | cut -d: -f1) ; \
    if [ -n "${existing_grp}" ] && [ "${existing_grp}" != "${USERNAME}" ]; then groupdel "${existing_grp}" 2>/dev/null || true; fi && \
    groupadd -g ${USER_GID} ${USERNAME} 2>/dev/null || true && \
    useradd -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash ${USERNAME} && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USERNAME}
WORKDIR /home/${USERNAME}/Projects
