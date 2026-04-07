#!/usr/bin/env bash
# =============================================================================
# tar2img.sh  ―  OpenWrt rootfs.tar.gz をディスクイメージ (.img) に変換する
#
# 使い方:
#   sudo bash tar2img.sh [オプション]
#
# オプション:
#   -o <path>  出力imgファイル名 (デフォルト: ./build/openwrt.img)
#   -s <size>  imgサイズ MB単位 (デフォルト: 512)
#   -h         このヘルプを表示
#
# 依存コマンド: dd, parted, mkfs.vfat, mkfs.ext4, losetup, mount, tar
#
# 生成されたimgはそのままUSBに書き込める:
#   sudo dd if=openwrt.img of=/dev/sdX bs=4M status=progress && sync
#
# 注意: OpenWrt の ImageBuilder は combined.img.gz を直接生成するため、
#       通常はこのスクリプト不要です。rootfs.tar.gz から独自構成で
#       イメージを作りたい場合に使ってください。
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# デフォルト設定
# ─────────────────────────────────────────────
ROOTFS_TAR="./build/openwrt-rootfs.tar.gz"
DONE_FLAG="./build/FLAGS/.build_done"
OUTPUT_IMG="./build/openwrt.img"
IMG_SIZE_MB=512          # OpenWrtは小さいので 512MB で十分
MOUNT_ROOT="/mnt/openwrt_img"
LOGFILE="./build/tar2img.log"

# ─────────────────────────────────────────────
# オプション解析
# ─────────────────────────────────────────────
usage() {
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while getopts "o:s:h" opt; do
    case $opt in
        o) OUTPUT_IMG="$OPTARG" ;;
        s) IMG_SIZE_MB="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ─────────────────────────────────────────────
# ログ設定
# ─────────────────────────────────────────────
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

log()  { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
err()  { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; exit 1; }

echo "============================================"
log "tar2img.sh 開始"
echo "============================================"

# ─────────────────────────────────────────────
# 0. 事前確認
# ─────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    err "root権限が必要です: sudo bash tar2img.sh"
fi

for cmd in dd parted mkfs.vfat mkfs.ext4 losetup mount tar blkid; do
    command -v "$cmd" &>/dev/null || err "必要なコマンドが見つかりません: $cmd"
done

if [[ ! -f "$ROOTFS_TAR" ]]; then
    err "${ROOTFS_TAR} が存在しません。ビルドが完了しているか確認してください。"
fi

if [[ ! -f "$DONE_FLAG" ]]; then
    warn "ビルド完了フラグ (${DONE_FLAG}) がありません。"
    read -rp "  続行しますか？ (yes/no): " WARN_CONFIRM
    [[ "$WARN_CONFIRM" == "yes" ]] || { echo "中止しました。"; exit 0; }
fi

echo ""
echo "========================================================"
echo "  出力ファイル : ${OUTPUT_IMG}"
echo "  イメージサイズ: ${IMG_SIZE_MB} MB"
echo "  rootfs      : ${ROOTFS_TAR}"
echo "========================================================"
read -rp "続行しますか？ (yes と入力して Enter): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "中止しました。"; exit 0; }

# ─────────────────────────────────────────────
# ループデバイス管理
# ─────────────────────────────────────────────
LOOP_DEV=""

cleanup() {
    log "クリーンアップ中..."
    umount -R "${MOUNT_ROOT}/dev"      2>/dev/null || true
    umount -R "${MOUNT_ROOT}/sys"      2>/dev/null || true
    umount    "${MOUNT_ROOT}/proc"     2>/dev/null || true
    umount    "${MOUNT_ROOT}/boot/efi" 2>/dev/null || true
    umount    "${MOUNT_ROOT}"          2>/dev/null || true
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
        log "ループデバイス解放: $LOOP_DEV"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# 1. 空のimgファイル作成
# ─────────────────────────────────────────────
log "imgファイル作成中 (${IMG_SIZE_MB}MB)..."
mkdir -p "$(dirname "$OUTPUT_IMG")"

if [[ -f "$OUTPUT_IMG" ]]; then
    read -rp "[WARN] ${OUTPUT_IMG} が既に存在します。上書きしますか？ (yes/no): " OW_CONFIRM
    [[ "$OW_CONFIRM" == "yes" ]] || { echo "中止しました。"; exit 0; }
fi

dd if=/dev/zero of="$OUTPUT_IMG" bs=1M count="${IMG_SIZE_MB}" status=progress
log "imgファイル作成完了: $(du -h "$OUTPUT_IMG" | cut -f1)"

# ─────────────────────────────────────────────
# 2. ループデバイスにアタッチ
# ─────────────────────────────────────────────
log "ループデバイスにアタッチ中..."
LOOP_DEV=$(losetup --find --show "$OUTPUT_IMG")
log "ループデバイス: $LOOP_DEV"

# ─────────────────────────────────────────────
# 3. パーティション作成
#    OpenWrt x86/64: GPT + EFI (256MiB) + root (残り)
# ─────────────────────────────────────────────
log "パーティション作成中..."

parted -s "$LOOP_DEV" \
    mklabel gpt \
    mkpart EFI  fat32 1MiB 257MiB \
    set 1 esp on \
    mkpart root ext4  257MiB 100%

# パーティションスキャン付きで再アタッチ
losetup -d "$LOOP_DEV"
LOOP_DEV=$(losetup --find --show --partscan "$OUTPUT_IMG")
log "パーティションスキャン済みループデバイス: $LOOP_DEV"

sleep 1

EFI_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

[[ -b "$EFI_PART" ]] || err "EFIパーティションデバイスが見つかりません: $EFI_PART"
[[ -b "$ROOT_PART" ]] || err "rootパーティションデバイスが見つかりません: $ROOT_PART"

# ─────────────────────────────────────────────
# 4. フォーマット
# ─────────────────────────────────────────────
log "フォーマット中..."
mkfs.vfat -F32 -n "EFI"     "$EFI_PART"
mkfs.ext4 -F   -L "openwrt" "$ROOT_PART"

# ─────────────────────────────────────────────
# 5. マウント
# ─────────────────────────────────────────────
log "マウント中..."
mkdir -p "$MOUNT_ROOT"
mount "$ROOT_PART" "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT/boot/efi"
mount "$EFI_PART"  "$MOUNT_ROOT/boot/efi"

# ─────────────────────────────────────────────
# 6. rootfs 展開
# ─────────────────────────────────────────────
log "rootfs 展開中..."
tar xpf "$ROOTFS_TAR" \
    --numeric-owner \
    -C "$MOUNT_ROOT"

# ─────────────────────────────────────────────
# 7. fstab 生成
# ─────────────────────────────────────────────
log "fstab 生成中..."
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
EFI_UUID=$(blkid  -s UUID -o value "$EFI_PART")

cat > "$MOUNT_ROOT/etc/fstab" << FSTAB_EOF
# <fs>                                  <mountpoint>  <type>  <opts>            <dump> <pass>
UUID=${ROOT_UUID}  /          ext4    defaults,noatime  0      1
UUID=${EFI_UUID}   /boot/efi  vfat    defaults          0      2
FSTAB_EOF

log "  ROOT UUID: $ROOT_UUID"
log "  EFI  UUID: $EFI_UUID"

# ─────────────────────────────────────────────
# 8. GRUB インストール(任意)
#    OpenWrt は通常 extlinux/syslinux を使うが、
#    EFI環境では GRUB の方が互換性が高い
# ─────────────────────────────────────────────
mount --types proc /proc "$MOUNT_ROOT/proc"
mount --rbind      /sys  "$MOUNT_ROOT/sys"
mount --make-rslave      "$MOUNT_ROOT/sys"
mount --rbind      /dev  "$MOUNT_ROOT/dev"
mount --make-rslave      "$MOUNT_ROOT/dev"

if [[ -x "${MOUNT_ROOT}/usr/sbin/grub-install" ]]; then
    log "GRUB インストール中..."
    chroot "$MOUNT_ROOT" /bin/bash << 'GRUB_EOF'
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=openwrt \
    --removable
grub-mkconfig -o /boot/grub/grub.cfg
echo "[CHROOT] GRUB 完了"
GRUB_EOF
else
    warn "grub-install が rootfs 内に見つかりません。"
    warn "OpenWrt の combined.img.gz はブートローダー込みのため、"
    warn "USB書き込みには tar2img.sh ではなく combined.img.gz を推奨します。"
fi

# ─────────────────────────────────────────────
# 9. アンマウント & 解放
# ─────────────────────────────────────────────
trap - EXIT
log "アンマウント中..."
umount -R "${MOUNT_ROOT}/dev"      || true
umount -R "${MOUNT_ROOT}/sys"      || true
umount    "${MOUNT_ROOT}/proc"     || true
umount    "${MOUNT_ROOT}/boot/efi"
umount    "${MOUNT_ROOT}"
sync

log "ループデバイス解放中..."
losetup -d "$LOOP_DEV"
LOOP_DEV=""

# ─────────────────────────────────────────────
# 完了メッセージ
# ─────────────────────────────────────────────
IMG_SIZE=$(du -h "$OUTPUT_IMG" | cut -f1)

echo ""
echo "============================================"
log "ディスクイメージが完成しました！"
echo ""
echo "  ファイル: ${OUTPUT_IMG}"
echo "  サイズ  : ${IMG_SIZE}"
echo ""
echo "USBへの書き込み方法:"
echo "  # dd を使う場合"
echo "  sudo dd if=${OUTPUT_IMG} of=/dev/sdX bs=4M status=progress && sync"
echo ""
echo "  # または OpenWrt 純正イメージ(推奨):"
echo "  gunzip -c ./build/openwrt-combined.img.gz | sudo dd of=/dev/sdX bs=4M status=progress && sync"
echo ""
echo "  # QEMU でテストする場合"
echo "  qemu-system-x86_64 -m 256M -drive file=${OUTPUT_IMG},format=raw -nographic"
echo "============================================"
