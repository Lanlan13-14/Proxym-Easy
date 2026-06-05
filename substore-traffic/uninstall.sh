#!/bin/sh
set -eu

APP_NAME="vps-substore-traffic"
INSTALL_BIN="/usr/local/bin/vps-substore-traffic"
PANEL_BIN="/usr/local/bin/vps-substore-panel"
CONFIG_FILE="/etc/vps-substore-traffic.json"
STATE_DIR="/var/lib/vps-substore-traffic"
SERVICE_FILE="/etc/systemd/system/vps-substore-traffic.service"

if [ "$(id -u)" != "0" ]; then
  echo "请使用 root 运行：sudo sh uninstall.sh"
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl stop "$APP_NAME" 2>/dev/null || true
  systemctl disable "$APP_NAME" 2>/dev/null || true
fi

rm -f "$SERVICE_FILE"
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi

rm -f "$INSTALL_BIN" "$PANEL_BIN"

echo "已删除程序和 systemd 服务。"

printf "是否删除配置文件和流量状态？这会清除 /etc/vps-substore-traffic.json 与 /var/lib/vps-substore-traffic [y/N]: "
read ans
case "$ans" in
  y|Y|yes|YES|是)
    rm -f "$CONFIG_FILE"
    rm -rf "$STATE_DIR"
    echo "已删除配置和状态。"
    ;;
  *)
    echo "已保留配置和状态。"
    ;;
esac

echo "卸载完成。"
