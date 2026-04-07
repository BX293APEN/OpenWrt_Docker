# OpenWrt ビルド on Docker

Docker 上で OpenWrt の ImageBuilder を動かし、
カスタム設定済みのイメージを生成して USB に焼けるプロジェクトです。

---

## 📁 ファイル構成

```
.
├── compose.yml             # Docker Compose 設定
├── Dockerfile              # Ubuntu 24.04 ベースのビルド環境
├── .env                    # 環境変数（IP設定・バージョン等）← ここを編集
├── openwrt_docker.sh       # コンテナ内ビルドスクリプト（エントリーポイント）
├── tar2img.sh              # rootfs.tar.gz → .img 変換スクリプト（任意）
└── build/                  # ビルド成果物（gitignore 推奨）
    ├── imagebuilder/       # ImageBuilder 作業ディレクトリ
    ├── images/             # 全ビルド成果物
    ├── openwrt-rootfs.tar.gz       # rootfs アーカイブ
    ├── openwrt-combined.img.gz     # USB書き込み用イメージ（メイン成果物）
    ├── build.log           # ビルドログ
    └── FLAGS/.build_done   # ビルド完了フラグ
```

---

## ⚙️ カスタマイズ（`.env` を編集）

| 変数 | 説明 | デフォルト |
|------|------|-----------|
| `DEVICE_PROFILE` | **ターゲットデバイス**（下表参照） | `x86_64` |
| `OPENWRT_VERSION` | OpenWrtバージョン | `23.05.3` |
| `LAN_IP` | LAN側IPアドレス | `192.168.1.1` |
| `LAN_NETMASK` | サブネットマスク | `255.255.255.0` |
| `LAN_GATEWAY` | 上流ゲートウェイ（任意） | 空 |
| `LAN_DNS` | DNSサーバー（カンマ区切り） | `8.8.8.8,8.8.4.4` |
| `WAN_PROTO` | WANプロトコル (`dhcp`/`static`/`pppoe`) | `dhcp` |
| `OPENWRT_TZ` | タイムゾーン（OpenWrt形式） | `JST-9` |
| `SSH_PORT` | SSHポート番号 | `22` |
| `ROOT_PASSWORD` | rootパスワード | `password` |
| `CPU_CORE` | ビルド並列数 | `4` |

### DEVICE_PROFILE の選択肢

| 値 | 対象デバイス | TARGET/SUBTARGET | 書き込み先 |
|----|-------------|-----------------|-----------|
| `x86_64` | PC / VM / x86 USB | x86/64 | USB / HDD |
| `rpi4` | Raspberry Pi 4 / 400 / CM4 | bcm27xx/bcm2711 | microSD / USB |
| `rpi3` | Raspberry Pi 3 / 3B+ / CM3 | bcm27xx/bcm2710 | microSD / USB |
| `rpi2` | Raspberry Pi 2 | bcm27xx/bcm2709 | microSD |

> **TARGET/SUBTARGET/PROFILE を直接指定したい場合**（TP-Link等の特殊ターゲット）は、
> `.env` の `TARGET=` / `SUBTARGET=` / `PROFILE=` に直接記入すると `DEVICE_PROFILE` より優先されます。

---

## 🌙 ビルド手順

### 1. `.env` を編集

```bash
nano .env
```

最低限変更すべき設定:
- `LAN_IP` — OpenWrt の LAN 側 IP アドレス
- `ROOT_PASSWORD` — root パスワード

### 2. ビルド開始

```bash
docker compose up --build -d
```

### 3. 進捗確認

```bash
docker logs -f Docker_OpenWrt
```

ビルドには **5〜30分** かかります（回線速度・CPU による）。

---

## ☀️ USB に書き込む

### 方法 A：純正イメージ（推奨・ブートローダー込み）

```bash
# /dev/sdX を実際のUSBデバイスに置き換えること
gunzip -c ./build/openwrt-combined.img.gz | sudo dd of=/dev/sdX bs=4M status=progress && sync
```

### 方法 B：tar2img.sh でカスタムイメージ作成

```bash
sudo bash tar2img.sh
# オプション: -o 出力パス -s サイズ(MB)
```

---

## 🖥️ 動作確認（QEMU）

```bash
# img.gz 展開
gunzip -k ./build/openwrt-combined.img.gz

# QEMU 起動（NICを2枚追加: eth0=LAN, eth1=WAN）
qemu-system-x86_64 \
    -m 256M \
    -drive file=./build/images/openwrt-*combined-efi*.img,format=raw \
    -device e1000,netdev=lan \
    -netdev user,id=lan,net=192.168.1.0/24,dhcpstart=192.168.1.10 \
    -device e1000,netdev=wan \
    -netdev user,id=wan \
    -nographic
```

起動後のアクセス:
- ログイン: `root` / パスワード: `.env` の `ROOT_PASSWORD`
- LuCI Web UI: `http://192.168.1.1/` （LAN側 IP）
- SSH: `ssh root@192.168.1.1`

---

## 🔁 再ビルドしたい場合

```bash
rm ./build/FLAGS/.build_done
docker compose up --build -d
```

ImageBuilder キャッシュも消したい場合:

```bash
rm -rf ./build/
docker compose up --build -d
```

---

## 📦 インストール済みパッケージ

| カテゴリ | パッケージ |
|---------|-----------|
| Web UI | luci, luci-i18n-base-ja（日本語化） |
| ネットワーク | netifd, dnsmasq, odhcp6c, ppp/pppoe |
| SSH | dropbear（組み込み SSH サーバー） |
| エディタ | nano, vim |
| ツール | curl, wget, htop, tcpdump, nmap, iperf3 |
| ストレージ | block-mount, e2fsprogs, dosfstools, parted |
| 統計 | luci-app-statistics, collectd |

> **日本語入力について**
> OpenWrt は GUI デスクトップ環境を持たないため、fcitx/mozc のような
> 日本語IMEは不要です。LuCI の Web UI が日本語化（`luci-i18n-base-ja`）
> されており、SSH 端末では UTF-8 エンコーディングで日本語表示できます。

---

## 🐛 トラブルシューティング

**ビルドが失敗する（パッケージが見つからない）**

`OPENWRT_VERSION` と `TARGET`/`SUBTARGET` の組み合わせを確認:
```
https://downloads.openwrt.org/releases/
```

**ImageBuilder のダウンロードに失敗する**

ミラーを変更:
```bash
# .env で
OPENWRT_MIRROR=https://mirror.math.princeton.edu/pub/openwrt
```

**ビルドが途中で止まった**

```bash
docker compose down
rm ./build/FLAGS/.build_done
docker compose up -d   # ImageBuilder は再利用される
```
