#!/usr/bin/env bash
# =============================================================================
# morning.sh  ―  朝起きたら実行(ホストUbuntu上で sudo bash morning.sh)
# 役割: OpenWrt のビルド成果物を USB / microSD に書き込む
#
# 実行前にやること:
#   1. USB または microSD を挿す
#   2. lsblk でデバイス名を確認する
#   3. sudo bash morning.sh [オプション]
#
# オプション:
#   --size <MB>   書き込み後の rootfs パーティション上限サイズ(MB単位)
#                 例: --size 2048  → 2 GB に制限
#                 例: --size 0     → デバイス全容量を使う(デフォルト)
#                 .env の USB_SIZE_MB でも指定可能(コマンドライン引数が優先)
#
# 警告: 選択したデバイスは完全消去されます！
#
# DEVICE_PROFILE に応じて書き込み方法が自動で変わります:
#   x86_64 … combined.img.gz を dd で直接書き込み(GRUB込み)
#   rpi*   … factory.img.gz  を dd で直接書き込み(U-Boot込み)
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# コマンドライン引数パース
# ─────────────────────────────────────────────
# --size <MB> : rootfs パーティションの上限サイズ(MB)
#               0 または未指定 → デバイス全容量を使う
_CLI_SIZE_MB=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --size)
            [[ -n "${2:-}" ]] || { echo "[ERROR] --size にはMB数を指定してください" >&2; exit 1; }
            _CLI_SIZE_MB="$2"
            shift 2
            ;;
        --size=*)
            _CLI_SIZE_MB="${1#--size=}"
            shift
            ;;
        *)
            echo "[ERROR] 不明なオプション: $1" >&2
            echo "使い方: sudo bash morning.sh [--size <MB>]" >&2
            exit 1
            ;;
    esac
done

# ─────────────────────────────────────────────
# .env の読み込み(DEVICE_PROFILE / USB_SIZE_MB を取得)
# ─────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/.env"
DEVICE_PROFILE="x86_64"   # .env が無い場合のデフォルト
USB_SIZE_MB=0              # 0 = デバイス全容量を使う

if [[ -f "${ENV_FILE}" ]]; then
    # コメント・空行を除いて読み込む
    _dp=$(grep -E '^DEVICE_PROFILE=' "${ENV_FILE}" | tail -1 | cut -d= -f2 | tr -d '"'"'" | xargs)
    [[ -n "${_dp}" ]] && DEVICE_PROFILE="${_dp}"

    _sz=$(grep -E '^USB_SIZE_MB=' "${ENV_FILE}" | tail -1 | cut -d= -f2 | tr -d '"'"'" | xargs)
    [[ -n "${_sz}" ]] && USB_SIZE_MB="${_sz}"
fi

# コマンドライン引数は .env より優先
[[ -n "${_CLI_SIZE_MB}" ]] && USB_SIZE_MB="${_CLI_SIZE_MB}"

# 値の検証
if ! [[ "${USB_SIZE_MB}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] USB_SIZE_MB は 0 以上の整数で指定してください: ${USB_SIZE_MB}" >&2
    exit 1
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
if [[ "${USB_SIZE_MB}" -eq 0 ]]; then
    echo "  容量制限      : なし(デバイス全容量を使用)"
else
    echo "  容量制限      : ${USB_SIZE_MB} MB"
fi
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
if [[ "${USB_SIZE_MB}" -eq 0 ]]; then
    echo "  rootfs サイズ   : デバイス全容量(制限なし)"
else
    echo "  rootfs サイズ   : ${USB_SIZE_MB} MB に制限"
fi
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
# 6. rootfs パーティションのサイズ調整
#
#  【書き込み後のイメージサイズ】を基準に 4 ケースで動作:
#
#   ケース A: 指定サイズ > デバイス容量
#             → 何もしない(書き込んだイメージのまま)
#
#   ケース B: 指定サイズ = 0  OR  指定サイズ >= デバイス容量
#             → デバイス全容量を使うように rootfs を最大拡張
#
#   ケース C: 指定サイズ < 書き込みイメージの rootfs サイズ
#             → 最小限(書き込み済みサイズのまま)。何もしない。
#
#   ケース D: 書き込みイメージの rootfs サイズ <= 指定サイズ <= デバイス容量
#             → 指定サイズまで rootfs を拡張
#
#    ※ OpenWrt x86_64 の combined.img は通常2パーティション構成:
#       sda1 = BIOS/EFI boot,  sda2 = rootfs (ext4)
#    ※ rpi の factory.img も同様の2パーティション構成
# ─────────────────────────────────────────────

# parted / resize2fs の存在確認(リサイズが必要になる前に行う)
for _cmd in parted resize2fs e2fsck blockdev; do
    command -v "${_cmd}" &>/dev/null \
        || err "${_cmd} が見つかりません。apt install parted e2fsprogs util-linux で導入してください。"
done

# ── デバイス・パーティション情報を収集 ──────────────────────────
_dev_total_mb=$(( $(blockdev --getsize64 "${USB_DEV}") / 1024 / 1024 ))
log "  デバイス総容量: ${_dev_total_mb} MB"

# 最後のパーティション番号とデバイスパスを特定
_last_partnum=$(parted -s "${USB_DEV}" print \
    | awk '/^ *[0-9]/{last=$1} END{print last}')
_last_part="${USB_DEV}${_last_partnum}"
# nvme / mmcblk は "p" セパレータが必要 (例: /dev/mmcblk0p2)
if [[ "${USB_DEV}" =~ (nvme|mmcblk) ]]; then
    _last_part="${USB_DEV}p${_last_partnum}"
fi
log "  対象パーティション: ${_last_part} (No.${_last_partnum})"

# パーティションの開始・現在の終了位置を取得(MiB単位)
_start_mb=$(parted -s "${USB_DEV}" unit MiB print \
    | awk -v n="${_last_partnum}" '$1==n{gsub(/MiB/,"",$2); printf "%d", $2}')
_current_end_mb=$(parted -s "${USB_DEV}" unit MiB print \
    | awk -v n="${_last_partnum}" '$1==n{gsub(/MiB/,"",$3); printf "%d", $3}')

# 書き込み済み rootfs パーティションの現在サイズ(MiB)
_written_size_mb=$(( _current_end_mb - _start_mb ))
log "  書き込み済み rootfs: 開始 ${_start_mb} MiB / 終了 ${_current_end_mb} MiB / サイズ ${_written_size_mb} MiB"

# ── ケース分岐 ───────────────────────────────────────────────────

# ケース A: 指定サイズ > デバイス容量 → 何もしない
if [[ "${USB_SIZE_MB}" -gt "${_dev_total_mb}" ]]; then
    warn "  指定サイズ(${USB_SIZE_MB} MB) > デバイス容量(${_dev_total_mb} MB)のため、リサイズをスキップします。"
    log "  書き込んだイメージのままです。"

# ケース B: 0 指定 OR 指定サイズ >= デバイス容量 → 全容量使用
elif [[ "${USB_SIZE_MB}" -eq 0 || "${USB_SIZE_MB}" -ge "${_dev_total_mb}" ]]; then
    log "  rootfs をデバイス全容量(${_dev_total_mb} MB)まで拡張します..."
    # デバイス末尾の 1 MiB をパーティションテーブル保護領域として残す
    _end_mb=$(( _dev_total_mb - 1 ))
    _do_resize=1

# ケース C: 指定サイズ < 書き込み済みサイズ → 最小限(何もしない)
elif [[ "${USB_SIZE_MB}" -lt "${_written_size_mb}" ]]; then
    warn "  指定サイズ(${USB_SIZE_MB} MB) < 書き込み済みサイズ(${_written_size_mb} MB)のため、リサイズをスキップします。"
    log "  縮小はサポートしていません。書き込んだイメージのままです。"

# ケース D: 書き込み済みサイズ <= 指定サイズ <= デバイス容量 → 指定サイズまで拡張
else
    log "  rootfs を ${USB_SIZE_MB} MB に拡張します..."
    _end_mb=$(( _start_mb + USB_SIZE_MB ))
    # デバイス末尾を超えないよう安全マージンを確保
    if [[ "${_end_mb}" -ge "${_dev_total_mb}" ]]; then
        _end_mb=$(( _dev_total_mb - 1 ))
        log "  終端をデバイス末尾(${_end_mb} MiB)に調整しました"
    fi
    _do_resize=1
fi

# ── 実際のリサイズ処理 ────────────────────────────────────────────
if [[ "${_do_resize:-0}" -eq 1 ]]; then
    log "  リサイズ: ${_start_mb} MiB → ${_end_mb} MiB"

    # parted でパーティションをリサイズ
    parted -s "${USB_DEV}" resizepart "${_last_partnum}" "${_end_mb}MiB"
    partprobe "${USB_DEV}" 2>/dev/null || true
    sleep 1

    # ext2/3/4 ならファイルシステムも拡張
    _fstype=$(lsblk -no FSTYPE "${_last_part}" 2>/dev/null || true)
    if [[ "${_fstype}" == "ext4" || "${_fstype}" == "ext3" || "${_fstype}" == "ext2" ]]; then
        log "  e2fsck でファイルシステムを検査..."
        e2fsck -f -y "${_last_part}" || true   # エラーでもリサイズは試みる
        log "  resize2fs でファイルシステムを拡張..."
        resize2fs "${_last_part}"
        log "  ファイルシステム拡張完了"
    elif [[ -n "${_fstype}" ]]; then
        warn "  fstype=${_fstype} は自動拡張に非対応。パーティションのみリサイズしました。"
    else
        warn "  ファイルシステムタイプを検出できませんでした。パーティションのみリサイズしました。"
    fi

    log "リサイズ後のデバイス状態:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "${USB_DEV}" || true
fi

# ─────────────────────────────────────────────
# 完了メッセージ
# ─────────────────────────────────────────────
echo ""
echo "============================================"
log "完了！ OpenWrt を ${USB_DEV} に書き込みました"
if [[ "${_do_resize:-0}" -eq 1 ]]; then
    log "  rootfs を ${_end_mb:-?} MiB に調整しました"
fi
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
