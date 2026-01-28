#!/bin/bash
# Proxym-Easy Xray 管理主脚本
# Author: Andy Bright

XRAY_DIR="/usr/local/bin/xray"
CONFIG_DIR="/etc/xray"
MAIN_CONFIG="$CONFIG_DIR/main.json"
SCRIPT_DIR="$(dirname $(realpath $0))"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# root 判断
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}请使用root执行脚本${NC}" 
   exit 1
fi

# 安装/更新 Xray 并支持多配置启动
install_xray() {
    echo -e "${BLUE}安装/更新 Xray...${NC}"
    # 使用官方脚本安装
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
    mkdir -p "$CONFIG_DIR"
    echo -e "${GREEN}Xray 安装完成${NC}"

    # 配置 systemd 服务支持多配置文件
    XRAY_SERVICE="/etc/systemd/system/xray.service"
    echo -e "${BLUE}配置 systemd 服务支持多配置文件...${NC}"
    cat > "$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
User=root
ExecStart=$XRAY_DIR run -config $MAIN_CONFIG -config-dir $CONFIG_DIR
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    echo -e "${GREEN}Xray 服务已启动并支持多配置文件加载${NC}"
}

# 更新主脚本
update_script() {
    echo -e "${BLUE}更新 Proxym-Easy 主脚本...${NC}"
    curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/main.sh -o "$SCRIPT_DIR/main.sh"
    chmod +x "$SCRIPT_DIR/main.sh"
    echo -e "${GREEN}主脚本更新完成${NC}"
}

# DNS 配置交互式生成
generate_dns_config() {
    echo -e "${BLUE}生成 DNS 配置...${NC}"
    read -rp "请输入 DNS 服务器，用逗号分隔 (默认 1.1.1.1,8.8.8.8): " DNS_INPUT
    DNS_INPUT="${DNS_INPUT:-1.1.1.1,8.8.8.8}"
    
    IFS=',' read -ra DNS_ARRAY <<< "$DNS_INPUT"
    DNS_JSON=$(printf '"%s",' "${DNS_ARRAY[@]}")
    DNS_JSON="[${DNS_JSON%,}]"

    DNS_CONFIG_FILE="$CONFIG_DIR/dns.json"
    cat > "$DNS_CONFIG_FILE" <<EOF
{
  "dns": {
    "servers": $DNS_JSON
  }
}
EOF

    echo -e "${GREEN}DNS 配置生成完成：$DNS_CONFIG_FILE${NC}"
}

# 生成主配置（无入站）
generate_main_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$MAIN_CONFIG" <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
    echo -e "${GREEN}主配置生成完成（无入站）：$MAIN_CONFIG${NC}"
}

# 调用子脚本生成 VLESS+Reality 入站
add_reality_inbound() {
    echo -e "${BLUE}生成 VLESS+Reality 入站配置...${NC}"
    curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/script/vless-reality.sh -o /tmp/vless-reality.sh
    chmod +x /tmp/vless-reality.sh
    bash /tmp/vless-reality.sh "$CONFIG_DIR"
}

# 显示菜单
menu() {
    clear
    echo -e "${BLUE}=== Proxym-Easy Xray 管理 ===${NC}"
    echo "1. 安装/更新 Xray"
    echo "2. 更新主脚本"
    echo "3. 生成主配置（无入站）"
    echo "4. 生成 DNS 配置"
    echo "5. 添加 VLESS+Reality 入站"
    echo "0. 退出"
    read -rp "请选择操作: " choice
    case $choice in
        1) install_xray ;;
        2) update_script ;;
        3) generate_main_config ;;
        4) generate_dns_config ;;
        5) add_reality_inbound ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1; menu ;;
    esac
}

# 支持命令行参数直接执行
case $1 in
    install) install_xray ;;
    update) update_script ;;
    gen-main) generate_main_config ;;
    gen-dns) generate_dns_config ;;
    add-reality) add_reality_inbound ;;
    *) menu ;;
esac