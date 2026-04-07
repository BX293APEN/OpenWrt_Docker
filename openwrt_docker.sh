#!/usr/bin/env bash
# =============================================================================
# openwrt_docker.sh  ―  Docker コンテナ内エントリーポイント
#
# 役割:
#   1. OpenWrt ImageBuilder をダウンロード
#   2. 追加パッケージ(nano, NetworkManager相当, openssh, 日本語等)を指定
#   3. カスタムファイル(ネットワーク設定・SSH設定等)を注入
#   4. make image でビルド
#   5. /build/openwrt-rootfs.tar.gz を出力
#
# 設定は .env を編集してください。スクリプト本体は変更不要です。
#
# 進捗確認 (別ターミナルで):
#   docker logs -f Docker_OpenWrt
# =============================================================================

set -eo pipefail

# ─────────────────────────────────────────────
# .env → compose.yml environment → ここで受け取る
# ─────────────────────────────────────────────

# ── ビルド設定 ──
OPENWRT_VERSION="${OPENWRT_VERSION:-23.05.3}"
DEVICE_PROFILE="${DEVICE_PROFILE:-x86_64}"
OPENWRT_MIRROR="${OPENWRT_MIRROR:-https://downloads.openwrt.org}"
CPU_CORE="${CPU_CORE:-4}"
WS="${WS:-build}"

# ── DEVICE_PROFILE → TARGET / SUBTARGET / PROFILE の自動解決 ──────────────
# .env で TARGET/SUBTARGET/PROFILE が直接指定されていればそちらを優先する
_resolve_target() {
    case "${DEVICE_PROFILE}" in
        x86_64)
            TARGET="${TARGET:-x86}"
            SUBTARGET="${SUBTARGET:-64}"
            PROFILE="${PROFILE:-generic}"
            EXTRA_PACKAGES_PLATFORM=""
            ;;
        rpi4)
            TARGET="${TARGET:-bcm27xx}"
            SUBTARGET="${SUBTARGET:-bcm2711}"
            PROFILE="${PROFILE:-rpi-4}"
            # ラズパイ4向け: GPIO・カメラ・USB等のカーネルモジュール追加
            EXTRA_PACKAGES_PLATFORM="\
                kmod-usb2 \
                kmod-usb3 \
                kmod-sound-core \
                kmod-i2c-bcm2835 \
                kmod-i2c-core \
                kmod-spi-bcm2835 \
                kmod-leds-gpio \
                kmod-gpio-button-hotplug \
                kmod-input-gpio-keys \
            "
            ;;
        rpi3)
            TARGET="${TARGET:-bcm27xx}"
            SUBTARGET="${SUBTARGET:-bcm2710}"
            PROFILE="${PROFILE:-rpi-3}"
            EXTRA_PACKAGES_PLATFORM="\
                kmod-usb2 \
                kmod-sound-core \
                kmod-i2c-bcm2835 \
                kmod-i2c-core \
                kmod-spi-bcm2835 \
                kmod-leds-gpio \
                kmod-gpio-button-hotplug \
            "
            ;;
        rpi2)
            TARGET="${TARGET:-bcm27xx}"
            SUBTARGET="${SUBTARGET:-bcm2709}"
            PROFILE="${PROFILE:-rpi-2}"
            EXTRA_PACKAGES_PLATFORM="\
                kmod-usb2 \
                kmod-i2c-bcm2835 \
                kmod-i2c-core \
                kmod-leds-gpio \
                kmod-gpio-button-hotplug \
            "
            ;;
        *)
            err "未知の DEVICE_PROFILE: '${DEVICE_PROFILE}'" \
                "  使用可能な値: x86_64 / rpi4 / rpi3 / rpi2"
            ;;
    esac
}
_resolve_target

# ── ネットワーク設定 ──
LAN_IP="${LAN_IP:-192.168.1.1}"
LAN_NETMASK="${LAN_NETMASK:-255.255.255.0}"
LAN_GATEWAY="${LAN_GATEWAY:-}"
LAN_DNS="${LAN_DNS:-8.8.8.8}"
WAN_PROTO="${WAN_PROTO:-dhcp}"
WAN_IP="${WAN_IP:-}"
WAN_NETMASK="${WAN_NETMASK:-}"
WAN_GATEWAY="${WAN_GATEWAY:-}"
PPPOE_USER="${PPPOE_USER:-}"
PPPOE_PASS="${PPPOE_PASS:-}"

# ── ロケール・タイムゾーン ──
TIME_ZONE="${TIME_ZONE:-Asia/Tokyo}"
OPENWRT_TZ="${OPENWRT_TZ:-JST-9}"

# ── SSH ──
SSH_PORT="${SSH_PORT:-22}"
WAN_SSH="${WAN_SSH:-false}"
WAN_SSH_ALLOW_IP="${WAN_SSH_ALLOW_IP:-}"

# ── 認証 ──
ROOT_PASSWORD="${ROOT_PASSWORD:-password}"

# ── パス ──
BUILD_DIR="/${WS}"
IB_DIR="${BUILD_DIR}/imagebuilder"
CUSTOM_FILES_DIR="${BUILD_DIR}/custom_files"
OUTPUT_TAR="${BUILD_DIR}/openwrt-rootfs.tar.gz"
FLAG_DIR="${BUILD_DIR}/FLAGS"
DONE_FLAG="${FLAG_DIR}/.build_done"

# ─────────────────────────────────────────────
# ログ関数
# ─────────────────────────────────────────────
log()  { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
err()  { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; exit 1; }

echo "============================================"
log "OpenWrt ImageBuilder ビルド開始"
echo "  デバイス    : ${DEVICE_PROFILE}"
echo "  バージョン  : ${OPENWRT_VERSION}"
echo "  ターゲット  : ${TARGET}/${SUBTARGET} (PROFILE=${PROFILE})"
echo "  ミラー      : ${OPENWRT_MIRROR}"
echo "  LAN IP      : ${LAN_IP}/${LAN_NETMASK}"
echo "  WAN プロト  : ${WAN_PROTO}"
echo "  タイムゾーン: ${OPENWRT_TZ}"
echo "  出力先      : ${OUTPUT_TAR}"
echo "============================================"

# ─────────────────────────────────────────────
# ビルド済みチェック
# ─────────────────────────────────────────────
if [[ -f "${DONE_FLAG}" ]]; then
    log "ビルド済みフラグを検出。スキップします。"
    echo "  削除して再ビルドする場合: rm ${DONE_FLAG}"
    exit 0
fi

mkdir -p "${FLAG_DIR}"
chmod 777 -R "${FLAG_DIR}"

# ─────────────────────────────────────────────
# 1. ImageBuilder のダウンロード
# ─────────────────────────────────────────────
IB_NAME="openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET}-${SUBTARGET}.Linux-x86_64"
IB_URL="${OPENWRT_MIRROR}/releases/${OPENWRT_VERSION}/targets/${TARGET}/${SUBTARGET}/${IB_NAME}.tar.xz"
IB_ARCHIVE="${BUILD_DIR}/${IB_NAME}.tar.xz"

log "ImageBuilder URL: ${IB_URL}"

if [[ -f "${IB_ARCHIVE}" ]]; then
    log "キャッシュ済み: ${IB_ARCHIVE}、ダウンロードをスキップ"
else
    log "ダウンロード中: ${IB_NAME}.tar.xz"
    wget -c "${IB_URL}" -O "${IB_ARCHIVE}.tmp" || err "ImageBuilder のダウンロードに失敗しました。バージョン・ターゲットを確認してください。"
    mv "${IB_ARCHIVE}.tmp" "${IB_ARCHIVE}"
fi

# ─────────────────────────────────────────────
# 2. 展開
# ─────────────────────────────────────────────
if [[ ! -d "${IB_DIR}" ]]; then
    log "展開中: ${IB_NAME}.tar.xz"
    mkdir -p "${IB_DIR}"
    tar xf "${IB_ARCHIVE}" -C "${IB_DIR}" --strip-components=1
else
    log "ImageBuilder 展開済みをスキップ"
fi

# ─────────────────────────────────────────────
# 3. カスタムファイル(files/)の準備
#    ImageBuilder の files/ ディレクトリに置いたファイルは
#    rootfs に直接展開される(/etc/config/ 等に上書き可)
# ─────────────────────────────────────────────
log "カスタムファイル準備中..."

CUSTOM="${IB_DIR}/files"
mkdir -p \
    "${CUSTOM}/etc/config" \
    "${CUSTOM}/etc/dropbear" \
    "${CUSTOM}/etc/uci-defaults" \
    "${CUSTOM}/usr/bin"

# ── 3-1. ネットワーク設定 (/etc/config/network) ──────────────────────────
cat > "${CUSTOM}/etc/config/network" << NETEOF
config interface 'loopback'
    option ifname 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config globals 'globals'
    option ula_prefix 'auto'

config interface 'lan'
    option type 'bridge'
    option ifname 'eth0'
    option proto 'static'
    option ipaddr '${LAN_IP}'
    option netmask '${LAN_NETMASK}'
NETEOF

# LAN_GATEWAY が設定されている場合のみ追記
if [[ -n "${LAN_GATEWAY}" ]]; then
    echo "    option gateway '${LAN_GATEWAY}'" >> "${CUSTOM}/etc/config/network"
fi

# DNS設定(カンマ区切り → スペース区切りに変換)
LAN_DNS_SPACE="${LAN_DNS//,/ }"
echo "    list dns '${LAN_DNS_SPACE}'" >> "${CUSTOM}/etc/config/network"

# WAN設定
cat >> "${CUSTOM}/etc/config/network" << WANEOF

config interface 'wan'
    option ifname 'eth1'
    option proto '${WAN_PROTO}'
WANEOF

case "${WAN_PROTO}" in
    static)
        [[ -n "${WAN_IP}" ]]      && echo "    option ipaddr '${WAN_IP}'"      >> "${CUSTOM}/etc/config/network"
        [[ -n "${WAN_NETMASK}" ]] && echo "    option netmask '${WAN_NETMASK}'">> "${CUSTOM}/etc/config/network"
        [[ -n "${WAN_GATEWAY}" ]] && echo "    option gateway '${WAN_GATEWAY}'">> "${CUSTOM}/etc/config/network"
        ;;
    pppoe)
        [[ -n "${PPPOE_USER}" ]]  && echo "    option username '${PPPOE_USER}'">> "${CUSTOM}/etc/config/network"
        [[ -n "${PPPOE_PASS}" ]]  && echo "    option password '${PPPOE_PASS}'">> "${CUSTOM}/etc/config/network"
        ;;
esac

cat >> "${CUSTOM}/etc/config/network" << 'WAN6EOF'

config interface 'wan6'
    option ifname 'eth1'
    option proto 'dhcpv6'
WAN6EOF

log "ネットワーク設定完了: LAN=${LAN_IP}/${LAN_NETMASK}, WAN=${WAN_PROTO}"

# ── 3-2. SSH設定 (Dropbear) /etc/config/dropbear ─────────────────────────
# WAN_SSH=true の場合は Interface 制限を外す(全NICで待ち受け)
if [[ "${WAN_SSH}" == "true" ]]; then
    cat > "${CUSTOM}/etc/config/dropbear" << SSHEOF
config dropbear
    option PasswordAuth 'on'
    option RootPasswordAuth 'on'
    option Port '${SSH_PORT}'
SSHEOF
    log "SSH設定完了: port=${SSH_PORT} (WAN開放モード)"
else
    cat > "${CUSTOM}/etc/config/dropbear" << SSHEOF
config dropbear
    option PasswordAuth 'on'
    option RootPasswordAuth 'on'
    option Port '${SSH_PORT}'
    option Interface 'lan'
SSHEOF
    log "SSH設定完了: port=${SSH_PORT} (LANのみ)"
fi

# ── 3-3. タイムゾーン設定 /etc/config/system ────────────────────────────
cat > "${CUSTOM}/etc/config/system" << SYSEOF
config system
    option hostname 'OpenWrt'
    option timezone '${OPENWRT_TZ}'
    option ttylogin '0'
    option log_size '64'
    option urandom_seed '0'

config timeserver 'ntp'
    option enabled '1'
    option enable_server '0'
    list server '0.openwrt.pool.ntp.org'
    list server '1.openwrt.pool.ntp.org'
    list server '2.openwrt.pool.ntp.org'
    list server '3.openwrt.pool.ntp.org'
SYSEOF

log "タイムゾーン設定完了: ${OPENWRT_TZ}"

# ── 3-4. UCI defaults スクリプト(起動時に一度だけ実行) ─────────────────
# rootパスワード・日本語入力・その他の初回設定
cat > "${CUSTOM}/etc/uci-defaults/99-custom-setup.sh" << UCIEOF
#!/bin/sh
# 初回起動時に一度だけ実行される設定スクリプト

# ── root パスワード設定 ──
echo "root:${ROOT_PASSWORD}" | chpasswd 2>/dev/null || true

# ── LuCI 日本語化 ──
# luci-i18n-base-ja がインストールされていれば自動で有効化
if [ -f /usr/lib/lua/luci/i18n/base.ja.lmo ]; then
    uci set luci.main.lang='ja'
    uci commit luci
fi

# ── LuCI タイムゾーン表示設定 ──
uci set system.@system[0].zonename='Asia/Tokyo'
uci set system.@system[0].timezone='${OPENWRT_TZ}'
uci commit system

# ── SSH: DropBear の鍵生成(未生成の場合) ──
[ -f /etc/dropbear/dropbear_rsa_host_key ] || dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key
[ -f /etc/dropbear/dropbear_ed25519_host_key ] || dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key

# ── WAN SSH ファイアウォール設定 ──
# WAN_SSH=true のときのみ firewall に穴を開ける
# OpenWrtのfirewall4はUCIで管理する
if [ '${WAN_SSH}' = 'true' ]; then
    # WAN → device 向けのSSH許可ルールを追加
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-WAN-SSH'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest_port='${SSH_PORT}'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci set firewall.@rule[-1].family='ipv4'
    # 接続元IPが指定されていれば追加
    if [ -n '${WAN_SSH_ALLOW_IP}' ]; then
        uci set firewall.@rule[-1].src_ip='${WAN_SSH_ALLOW_IP}'
    fi
    uci commit firewall
fi

exit 0
UCIEOF
chmod +x "${CUSTOM}/etc/uci-defaults/99-custom-setup.sh"

log "UCI defaults スクリプト設定完了"

# ─────────────────────────────────────────────
# 4. インストールするパッケージリスト
#
# OpenWrt の "NetworkManager" 相当は netifd(デフォルト組み込み)
# + luci(Web UI)+ luci-proto-* が担う。
# 別途 network-manager パッケージ は OpenWrt には存在しないため、
# OpenWrt ネイティブの netifd ベースで設定する。
# ─────────────────────────────────────────────
PACKAGES="\
    base-files \
    libc \
    libgcc \
    busybox \
    dropbear \
    uci \
    netifd \
    dnsmasq \
    firewall4 \
    nftables \
    kmod-nft-offload \
    odhcp6c \
    odhcpd-ipv6only \
    ppp \
    ppp-mod-pppoe \
    luci \
    luci-base \
    luci-mod-admin-full \
    luci-theme-bootstrap \
    luci-i18n-base-ja \
    luci-app-firewall \
    luci-i18n-firewall-ja \
    luci-app-opkg \
    uhttpd \
    uhttpd-mod-ubus \
    rpcd \
    rpcd-mod-rpcsys \
    nano \
    vim-full \
    openssh-sftp-server \
    curl \
    wget \
    ca-certificates \
    htop \
    lsblk \
    block-mount \
    kmod-usb-storage \
    kmod-fs-ext4 \
    kmod-fs-vfat \
    e2fsprogs \
    dosfstools \
    parted \
    fdisk \
    usbutils \
    ip-full \
    tc-full \
    iperf3 \
    tcpdump \
    bind-dig \
    nmap \
    ethtool \
    luci-app-statistics \
    luci-i18n-statistics-ja \
    collectd \
    collectd-mod-cpu \
    collectd-mod-memory \
    collectd-mod-network \
    collectd-mod-rrdtool \
    luci-app-uhttpd \
"

# ── 日本語入力(fcitx/mozc等はOpenWrtにないため、端末での日本語表示に対応) ──
# OpenWrtはGUI非対応のため、端末エンコーディング対応のみ行う
# lcgi/UTF-8対応は luci-i18n-* パッケージで対応済み

# ── プラットフォーム固有パッケージを追記 ──────────────────────────────────
if [[ -n "${EXTRA_PACKAGES_PLATFORM:-}" ]]; then
    PACKAGES="${PACKAGES} ${EXTRA_PACKAGES_PLATFORM}"
    log "プラットフォーム固有パッケージを追加: ${DEVICE_PROFILE}"
fi

log "パッケージリスト決定完了"

# ─────────────────────────────────────────────
# 5. イメージビルド
#    make image で以下が生成される(x86/64の場合):
#      bin/targets/x86/64/openwrt-x86-64-generic-ext4-combined-efi.img.gz
#      bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img.gz
#      bin/targets/x86/64/openwrt-x86-64-rootfs.tar.gz  ← これを使う
# ─────────────────────────────────────────────
log "イメージビルド開始(数分〜数十分かかります)..."

cd "${IB_DIR}"

# パッケージリスト整形(改行・余分スペース除去)
PKG_LIST=$(echo "${PACKAGES}" | tr '\n' ' ' | sed 's/  */ /g' | xargs)

make image \
    PROFILE="${PROFILE}" \
    PACKAGES="${PKG_LIST}" \
    FILES="${CUSTOM}" \
    JOBS="${CPU_CORE}" \
    2>&1 | tee "${BUILD_DIR}/build.log"

log "イメージビルド完了"

# ─────────────────────────────────────────────
# 6. 成果物の収集
#    x86_64: *combined-efi.img.gz  (EFI + BIOS 両対応)
#    rpi*  : *factory.img.gz / *sysupgrade.img.gz
# ─────────────────────────────────────────────
BINS_DIR="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}"

log "成果物を収集中: ${BINS_DIR}"
ls -lh "${BINS_DIR}/" 2>/dev/null || err "ビルド成果物が見つかりません: ${BINS_DIR}"

# rootfs tar.gz のコピー
ROOTFS_TAR=$(find "${BINS_DIR}" -name "*rootfs.tar.gz" | head -1)
if [[ -n "${ROOTFS_TAR}" ]]; then
    cp "${ROOTFS_TAR}" "${OUTPUT_TAR}"
    log "rootfs tar.gz をコピー: ${OUTPUT_TAR}"
else
    warn "rootfs.tar.gz が見つかりませんでした"
fi

# ディスクイメージの選択
#   x86_64 → ext4 combined-efi を優先(USB書き込みに最適)
#   rpi*   → factory イメージを優先(SDカード / USB 書き込み用)
case "${DEVICE_PROFILE}" in
    x86_64)
        IMG_GZ=$(find "${BINS_DIR}" -name "*combined-efi.img.gz" | grep ext4 | head -1)
        IMG_GZ="${IMG_GZ:-$(find "${BINS_DIR}" -name "*combined*.img.gz" | head -1)}"
        ;;
    rpi*)
        IMG_GZ=$(find "${BINS_DIR}" -name "*factory.img.gz" | head -1)
        IMG_GZ="${IMG_GZ:-$(find "${BINS_DIR}" -name "*sysupgrade*.img.gz" | head -1)}"
        IMG_GZ="${IMG_GZ:-$(find "${BINS_DIR}" -name "*.img.gz" | head -1)}"
        ;;
    *)
        IMG_GZ=$(find "${BINS_DIR}" -name "*.img.gz" | head -1)
        ;;
esac

if [[ -n "${IMG_GZ}" ]]; then
    cp "${IMG_GZ}" "${BUILD_DIR}/openwrt-combined.img.gz"
    log "ディスクイメージをコピー: ${BUILD_DIR}/openwrt-combined.img.gz"
fi

# すべての成果物をコピー
mkdir -p "${BUILD_DIR}/images"
cp "${BINS_DIR}"/*.img.gz "${BUILD_DIR}/images/" 2>/dev/null || true
cp "${BINS_DIR}"/*.img    "${BUILD_DIR}/images/" 2>/dev/null || true

# ─────────────────────────────────────────────
# 完了
# ─────────────────────────────────────────────
date '+%Y-%m-%d %H:%M:%S' > "${DONE_FLAG}"

echo ""
echo "============================================"
log "ビルド完了！"
echo ""
echo "  デバイス         : ${DEVICE_PROFILE}"
echo "  rootfs tar.gz    : ${OUTPUT_TAR}"
echo "  ディスクイメージ : ${BUILD_DIR}/openwrt-combined.img.gz"
echo "  全成果物         : ${BUILD_DIR}/images/"
echo ""
echo "── 書き込み方法 ──────────────────────────────────"
case "${DEVICE_PROFILE}" in
    x86_64)
        echo "  # USB / ディスクへの書き込み(/dev/sdX を要確認):"
        echo "  gunzip -c ${BUILD_DIR}/openwrt-combined.img.gz | sudo dd of=/dev/sdX bs=4M status=progress && sync"
        echo ""
        echo "  # QEMU でのテスト:"
        echo "  gunzip -k ${BUILD_DIR}/openwrt-combined.img.gz"
        echo "  qemu-system-x86_64 -m 256M -drive file=${BUILD_DIR}/images/openwrt-*combined-efi*.img,format=raw -nographic"
        ;;
    rpi*)
        echo "  # microSD / USB への書き込み(/dev/sdX または /dev/mmcblkX を要確認):"
        echo "  gunzip -c ${BUILD_DIR}/openwrt-combined.img.gz | sudo dd of=/dev/sdX bs=4M status=progress && sync"
        echo ""
        echo "  ※ ラズパイは起動後 SSH でアクセス:"
        echo "     ssh root@${LAN_IP}"
        ;;
esac
echo ""
echo "  # tar2img.sh でカスタムイメージを作る場合:"
echo "  sudo bash tar2img.sh"
echo "============================================"
