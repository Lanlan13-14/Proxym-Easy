#!/bin/sh
set -eu

APP_NAME="vps-substore-traffic"
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SERVICE_SCRIPT="$BASE_DIR/vps-substore-traffic.py"
PANEL_SCRIPT="$BASE_DIR/vps-substore-panel.py"
INSTALL_BIN="/usr/local/bin/vps-substore-traffic"
PANEL_BIN="/usr/local/bin/vps-substore-panel"
CONFIG_FILE="/etc/vps-substore-traffic.json"
SERVICE_FILE="/etc/systemd/system/vps-substore-traffic.service"

if [ "$(id -u)" != "0" ]; then
  echo "请使用 root 运行：sudo sh install.sh"
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令：$1"
    if command -v apt-get >/dev/null 2>&1; then
      echo "可执行：apt-get update && apt-get install -y $2"
    elif command -v yum >/dev/null 2>&1; then
      echo "可执行：yum install -y $2"
    elif command -v dnf >/dev/null 2>&1; then
      echo "可执行：dnf install -y $2"
    elif command -v apk >/dev/null 2>&1; then
      echo "可执行：apk add --no-cache $2"
    fi
    exit 1
  fi
}

need_cmd python3 python3
need_cmd awk awk

if [ ! -f "$SERVICE_SCRIPT" ] || [ ! -f "$PANEL_SCRIPT" ]; then
  echo "安装文件不完整，请在 substore-traffic 目录下运行 install.sh"
  exit 1
fi

install -m 755 "$SERVICE_SCRIPT" "$INSTALL_BIN"
install -m 755 "$PANEL_SCRIPT" "$PANEL_BIN"

if [ ! -f "$CONFIG_FILE" ]; then
  "$INSTALL_BIN" --init-config --config "$CONFIG_FILE"
fi

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS Sub-Store Traffic Userinfo Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_BIN --config $CONFIG_FILE
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl enable --now "$APP_NAME"
  systemctl restart "$APP_NAME"
  echo "服务状态：$(systemctl is-active "$APP_NAME" 2>/dev/null || true)"
else
  echo "未检测到 systemctl，已安装脚本但未创建后台服务。"
fi

port="$(python3 -c 'import json;print(json.load(open("/etc/vps-substore-traffic.json")).get("port",8899))' 2>/dev/null || echo 8899)"

echo ""
echo "安装完成。"
echo "配置面板：sudo vps-substore-panel"
echo "Sub-Store 链接：http://VPS_IP:$port/sub-userinfo"
echo "状态接口：http://VPS_IP:$port/status"
echo "卸载命令：sudo sh $BASE_DIR/uninstall.sh"
