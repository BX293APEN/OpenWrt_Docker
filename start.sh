#!/bin/sh

# /var 以下の必要ディレクトリを作成
mkdir -p /var/lock
mkdir -p /var/log
mkdir -p /var/run
mkdir -p /var/run/ubus       # ubusd のソケット置き場 (rpcd config参照)
mkdir -p /var/state
mkdir -p /var/tmp
mkdir -p /tmp/.uci
mkdir -p /www

chmod 777 -R /www
chmod 1777 /var/lock
chmod 0700 /tmp/.uci
touch /var/log/wtmp
touch /var/log/lastlog

# /run シンボリックリンク (一部スクリプトが /run を参照する)
[ -L /run ] || ln -s /var/run /run

# /tmp/resolv.conf (network系スクリプトが参照)
mkdir -p /tmp/resolv.conf.d
touch /tmp/resolv.conf.d/resolv.conf.auto
ln -sf /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf

# ---- LuCI テーマ修正 ----
# openwrt2020 は sysauth.ut を持たないため bootstrap に変更する
uci set luci.main.mediaurlbase='/luci-static/bootstrap'
uci commit luci

# ---- ubusd 起動 ----
# /etc/init.d/ubus は存在しない。ubusd を直接起動する。
/sbin/ubusd -s /var/run/ubus/ubus.sock &
sleep 1   # ubus ソケットが生成されるまで待つ

# ---- rpcd 起動 ----
# USE_PROCD=1 のスクリプトは procd 経由での起動を前提とするため、
# procd を使わずに直接バイナリを実行する。
# ソケットパスは /etc/config/rpcd の option socket に合わせる。
/sbin/rpcd -s /var/run/ubus/ubus.sock -t 30 &
sleep 2

# ---- uhttpd 起動 ----
# こちらも USE_PROCD=1 のため直接実行。
# /etc/config/uhttpd の設定を読まずにコマンド引数で最低限指定する。
/usr/sbin/uhttpd \
    -f \
    -h /www \
    -r OpenWrt \
    -o / \
    -O /usr/share/ucode/luci/uhttpd.uc \
    -u /ubus \
    -U /var/run/ubus/ubus.sock \
    -p 0.0.0.0:80 \
    -n 3 &

echo "ubusd / rpcd / uhttpd started."

# コンテナを生かし続ける
while true; do
    sleep 3600
done
