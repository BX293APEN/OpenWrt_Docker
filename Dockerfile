# =============================================================================
# Dockerfile  ―  OpenWrt ImageBuilder 実行環境
# Ubuntu 24.04 LTS ベース
# ImageBuilder の動作に必要な依存パッケージをインストールする
# =============================================================================

FROM ubuntu:24.04

ARG WS
ARG ENTRY_DIR
ARG ENTRY_POINT

ENV DEBIAN_FRONTEND=noninteractive

# ImageBuilder 公式必須依存パッケージ
# https://openwrt.org/docs/guide-user/additional-software/imagebuilder
RUN apt update && \
    apt upgrade -y && \
    apt install -y \
        build-essential \
        clang \
        flex \
        bison \
        g++ \
        gawk \
        gcc-multilib \
        g++-multilib \
        gettext \
        git \
        libncurses-dev \
        libssl-dev \
#        python3-distutils \
        python3-setuptools \
        python3-dev \
        rsync \
        unzip \
        zlib1g-dev \
        file \
        wget \
        curl \
        xz-utils \
        tar \
        gzip \
        zstd \
        dosfstools \
        e2fsprogs \
        util-linux \
        parted \
        ca-certificates \
        qemu-utils \
        bash && \
    mkdir -p /${WS} /${ENTRY_DIR} && \
    chmod 777 /${WS} && \
    chmod 777 /${ENTRY_DIR}

COPY ${ENTRY_POINT} /${ENTRY_DIR}/${ENTRY_POINT}
RUN chmod +x /${ENTRY_DIR}/${ENTRY_POINT}

WORKDIR /${WS}
