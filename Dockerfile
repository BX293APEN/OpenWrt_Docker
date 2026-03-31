# FROM [イメージ] [タグ]
# Docker Hub (https://hub.docker.com/r/openwrt/rootfs) 参照

# 空のイメージ
FROM scratch

# tar.gzを自動展開
# ソース : https://downloads.openwrt.org/releases/25.12.2/targets/x86/64/
ADD ./image/openwrt-25.12.2-x86-64-rootfs.tar.gz /

# 環境変数を docker-compose.yml から受け取る
ARG ENTRY_POINT
ARG ENTRY_DIR
ARG PASSWORD

# 環境変数を設定
# 1000以上推奨
ENV USER_ID=1001
ENV GROUP_ID=1001

# OpenWrt 25.12.x 以降はパッケージ管理が apk に変更されているため
# apk add の前に apk update が必要。
# --no-cache オプションでキャッシュを残さずイメージサイズを削減。
# kmod-* 系はホスト kernel に依存するため Docker 上では動作しないが
# インストール自体は可能 (insmod 時にエラーになる)。
RUN apk update && \
    apk add --no-cache \
    base-files \
    luci \
    luci-base \
    luci-mod-admin-full \
    luci-i18n-base-ja \
    luci-i18n-firewall-ja \
    luci-i18n-dashboard-ja \
    luci-i18n-ttyd-ja \
    openssh-sftp-server \
    coreutils \
    irqbalance \
    luci-i18n-sqm-ja \
    luci-i18n-qos-ja \
    luci-i18n-statistics-ja \
    luci-i18n-nlbwmon-ja \
    luci-i18n-wifischedule-ja \
    luci-theme-openwrt \
    luci-theme-material \
    luci-theme-openwrt-2020 \
    luci-i18n-attendedsysupgrade-ja \
    luci-i18n-package-manager-ja \
    luci-lib-ipkg \
    luci-lua-runtime \
    block-mount \
    usbutils \
    gdisk \
    libblkid1 \
    dosfstools \
    iperf3 \
    ip-full \
    wsdd2 \
    lm-sensors \
    cfdisk \
    resize2fs \
    hdparm \
    hd-idle \
    luci-i18n-hd-idle-ja \
    ntfs-3g \
    e2fsprogs \
    f2fs-tools \
    exfat-fsck \
    ubus \
    uhttpd \
    uhttpd-mod-ucode \
    rpcd \
    rpcd-mod-luci \
    luci-mod-network \
    luci-mod-status \
    luci-mod-system \
    luci-app-firewall \
    firewall4 \
    rpcd-mod-file \
    rpcd-mod-rrdns \
    netifd \
    bash 

COPY ${ENTRY_POINT} /${ENTRY_DIR}/${ENTRY_POINT}
RUN chmod +x /${ENTRY_DIR}/${ENTRY_POINT}

RUN echo -e "${PASSWORD}\n${PASSWORD}" | passwd && \
    mkdir -p /var/lock && \
    /etc/init.d/boot start && \
    /etc/init.d/network start && \
    /etc/init.d/system start