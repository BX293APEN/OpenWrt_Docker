#!/usr/bin/env bash
# =============================================================================
# morning.sh  ―  朝起きたら実行(ホストUbuntu上で sudo bash morning.sh)
# 役割: OpenWrt のビルド成果物を USB / microSD に書き込む
#
# 実行前にやること:
#   1. USB または microSD を挿す
#   2. lsblk でデバイス名を確認する
#   3. sudo bash morning.sh
#
# 警告: 選択したデバイスは完全消去されます！
#
# DEVICE_PROFILE に応じて書き込み方法が自動で変わります:
#   x86_64 … combined.img.gz を dd で直接書き込み(GRUB込み)
#   rpi*   … factory.img.gz  を dd で直接書き込み(U-Boot込み)
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# .env の読み込み(DEVICE_PROFILE を取得)
# ─────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/.env"
DEVICE_PROFILE="x86_64"   # .env が無い場合のデフォルト

if [[ -f "${ENV_FILE}" ]]; then
    # コメント・空行を除いて読み込む
    _dp=$(grep -E '^DEVICE_PROFILE=' "${ENV_FILE}" | tail -1 | cut -d= -f2 | tr -d '"'"'" | xargs)
    [[ -n "${_dp}" ]] && DEVICE_PROFILE="${_dp}"
fi

# ─────────────────────────────────────────────
# パス設定(DEVICE_PROFILE に応じて成果物を選択)
# ─────────────────────────────────────────────
BUILD_DIR="./build"
DONE_FLAG="${BUILD_DIR}/FLAGS/.build_done"
LOGFILE="${BUILD_DIR}/morning.log"
MOUNT_ROOT="/mnt/openwrt"

# 成果物ファイルを検索(ビルド時にコピーされた openwrt-combined.img.gz を優先)
IMG_GZ=""
_find_image() {
    # 1. build/ 直下の openwrt-combined.img.gz
    [[ -f "${BUILD_DIR}/openwrt-combined.img.gz" ]] && { IMG_GZ="${BUILD_DIR}/openwrt-combined.img.gz"; return; }
    # 2. build/images/ 以下を検索(デバイス別に優先順位)
    case "${DEVICE_PROFILE}" in
        x86_64)
            IMG_GZ=$(find "${BUILD_DIR}/images" -name "*combined-efi*.img.gz" 2>/dev/null | grep ext4 | head -1)
            IMG_GZ="${IMG_GZ:-$(find "${BUILD_DIR}/images" -name "*combined*.img.gz" 2>/dev/null | head -1)}"
            ;;
        rpi*)
            IMG_GZ=$(find "${BUILD_DIR}/images" -name "*factory*.img.gz" 2>/dev/null | head -1)
            IMG_GZ="${IMG_GZ:-$(find "${BUILD_DIR}/images" -name "*sysupgrade*.img.gz" 2>/dev/null | head -1)}"
            IMG_GZ="${IMG_GZ:-$(find "${BUILD_DIR}/images" -name "*.img.gz" 2>/dev/null | head -1)}"
            ;;
        *)
            IMG_GZ=$(find "${BUILD_DIR}/images" -name "*.img.gz" 2>/dev/null | head -1)
            ;;
    esac
}
_find_image

# ─────────────────────────────────────────────
# ログ設定(開始前に mkdir だけ)
# ─────────────────────────────────────────────
mkdir -p "${BUILD_DIR}"
exec > >(tee -a "$LOGFILE") 2>&1

log()  { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
err()  { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; exit 1; }

echo "============================================"
log "morning.sh 開始"
echo "  DEVICE_PROFILE: ${DEVICE_PROFILE}"
echo "  イメージ      : ${IMG_GZ:-(未検出)}"
echo "============================================"

# ─────────────────────────────────────────────
# 0. 事前確認
# ─────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] || err "root権限が必要です: sudo bash morning.sh"

if [[ ! -f "$DONE_FLAG" ]]; then
    warn "ビルド完了フラグ (${DONE_FLAG}) がありません。"
    warn "ビルドが中途半端かもしれません。"
    read -rp "  続行しますか？ (yes/no): " _c
    [[ "${_c}" == "yes" ]] || { echo "中止しました。"; exit 0; }
fi

if [[ -z "${IMG_GZ}" ]] || [[ ! -f "${IMG_GZ}" ]]; then
    err "書き込むイメージが見つかりません。\n  ${BUILD_DIR}/images/ を確認してください。"
fi

# ─────────────────────────────────────────────
# 1. デバイス選択
# ─────────────────────────────────────────────
echo ""
echo "接続済みデバイス一覧:"
lsblk -po NAME,SIZE,LABEL,MOUNTPOINT | head -n1 && \
lsblk -po NAME,SIZE,LABEL,MOUNTPOINT | grep -E '^(/dev/sd|/dev/nvme)|^├─|^└─'

echo ""
case "${DEVICE_PROFILE}" in
    rpi*)  echo -n "microSD / USB デバイス (例: sdb または /dev/sdb または mmcblk0): " ;;
    *)     echo -n "USB デバイス (例: sdb または /dev/sdb): " ;;
esac
read -r INPUT

# /dev/ 付きでも無しでもOK
USB_DEV="/dev/${INPUT#/dev/}"

[[ -b "${USB_DEV}" ]] || err "${USB_DEV} が見つかりません。lsblk でデバイス名を確認してください。"

# 安全確認: ルートデバイスへの書き込みを防止
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
if [[ "${USB_DEV}" == "${ROOT_DEV}" ]]; then
    err "起動ドライブ (${ROOT_DEV}) への書き込みは危険なため中止しました。"
fi

# ─────────────────────────────────────────────
# 2. 既存マウントをアンマウント
# ─────────────────────────────────────────────
log "既存マウントの確認・解除..."
for part in "${USB_DEV}"?* "${USB_DEV}"; do
    [[ -b "$part" ]] || continue
    mp=$(lsblk -no MOUNTPOINT "$part" 2>/dev/null || true)
    if [[ -n "$mp" ]]; then
        umount "$mp" && log "  アンマウント: $part ($mp)"
    fi
done

# ─────────────────────────────────────────────
# 3. 確認プロンプト
# ─────────────────────────────────────────────
IMG_SIZE=$(du -h "${IMG_GZ}" | cut -f1)

echo ""
echo "========================================================"
echo "  警告: ${USB_DEV} を完全に上書きします！"
echo "  現在の状態:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL "${USB_DEV}" || true
echo ""
echo "  書き込むイメージ: ${IMG_GZ} (${IMG_SIZE})"
echo "  デバイス        : ${DEVICE_PROFILE}"
echo "========================================================"
read -rp "本当に続けますか？ (yes と入力して Enter): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "中止しました。"; exit 0; }

# ─────────────────────────────────────────────
# 4. img.gz を dd で直接書き込み
#
#    x86_64: combined-efi.img.gz はGRUBとパーティションテーブルが
#            全部入っているので dd 一発でOK。chrootもGRUBインストールも不要。
#    rpi*  : factory.img.gz も同様にU-Boot+パーティション込み。
# ─────────────────────────────────────────────
log "書き込み開始(イメージサイズの展開に数分かかります)..."
log "  ${IMG_GZ} → ${USB_DEV}"

gunzip -c "${IMG_GZ}" \
    | dd of="${USB_DEV}" bs=4M status=progress conv=fsync

sync
log "sync 完了"

# ─────────────────────────────────────────────
# 5. パーティションテーブルを再読み込み
# ─────────────────────────────────────────────
partprobe "${USB_DEV}" 2>/dev/null || true
sleep 1

log "書き込み後のデバイス状態:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "${USB_DEV}" || true

# ─────────────────────────────────────────────
# 完了メッセージ
# ─────────────────────────────────────────────
echo ""
echo "============================================"
log "完了！ OpenWrt を ${USB_DEV} に書き込みました"
echo ""

case "${DEVICE_PROFILE}" in
    x86_64)
        echo "次のステップ:"
        echo "  1. USB を抜いてターゲットPCに差す"
        echo "  2. BIOS/UEFI の Boot Order を USB 優先に設定"
        echo "  3. 起動！"
        echo ""
        echo "起動後のアクセス:"
        echo "  SSH : ssh root@<LAN_IP>   (.envのLAN_IPを確認)"
        echo "  Web : http://<LAN_IP>/    (LuCI 管理画面)"
        echo "  Pass: .env の ROOT_PASSWORD"
        ;;
    rpi*)
        echo "次のステップ:"
        echo "  1. microSD / USB を抜いてラズパイに差す"
        echo "  2. 電源ON"
        echo "  3. しばらく待つと起動します(初回は少し時間がかかります)"
        echo ""
        echo "起動後のアクセス:"
        echo "  SSH : ssh root@<LAN_IP>   (.envのLAN_IPを確認)"
        echo "  Web : http://<LAN_IP>/    (LuCI 管理画面)"
        echo "  Pass: .env の ROOT_PASSWORD"
        ;;
esac

echo "============================================"
