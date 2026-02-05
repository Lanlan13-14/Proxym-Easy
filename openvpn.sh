#!/bin/bash
# OpenVPN 一键管理脚本 (静态密钥 + AES-128-GCM + 多客户端)
# 安装后可通过 `openvpn-easy` 调出菜单

OVPN_DIR="/etc/openvpn"
SECRET_FILE="$OVPN_DIR/static.key"
SERVER_CONF="$OVPN_DIR/server.conf"
STATUS_LOG="$OVPN_DIR/status.log"
SERVICE_NAME="openvpn-server@server.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# --------------------------
# 安装 OpenVPN
# --------------------------
install_ovpn() {
    echo -e "${GREEN}安装 OpenVPN...${NC}"
    if [ -x "$(command -v apt)" ]; then
        apt update && apt install -y openvpn
    elif [ -x "$(command -v yum)" ]; then
        yum install -y epel-release
        yum install -y openvpn
    else
        echo -e "${RED}不支持的系统${NC}"
        exit 1
    fi
    mkdir -p "$OVPN_DIR"
    echo -e "${GREEN}安装完成${NC}"
}

# --------------------------
# 卸载 OpenVPN
# --------------------------
uninstall_ovpn() {
    echo -e "${RED}卸载 OpenVPN...${NC}"
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -rf "$OVPN_DIR"
    if [ -x "$(command -v apt)" ]; then
        apt remove -y openvpn
    elif [ -x "$(command -v yum)" ]; then
        yum remove -y openvpn
    fi
    echo -e "${GREEN}卸载完成${NC}"
    # 删除脚本自己
    SCRIPT_PATH="$(realpath "$0")"
    echo -e "${RED}删除脚本自身: $SCRIPT_PATH${NC}"
    rm -f "$SCRIPT_PATH"
}

# --------------------------
# 更新 OpenVPN
# --------------------------
update_ovpn() {
    echo -e "${GREEN}更新 OpenVPN...${NC}"
    if [ -x "$(command -v apt)" ]; then
        apt update && apt upgrade -y openvpn
    elif [ -x "$(command -v yum)" ]; then
        yum update -y openvpn
    fi
    echo -e "${GREEN}更新完成${NC}"
}

# --------------------------
# 获取服务器默认地址
# --------------------------
get_server_ip() {
    IPV4=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+\./){print $i; exit}}')
    IPV6=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i~/:/){print $i; exit}}')
    SERVER_IP_DEFAULT="${IPV4:-$IPV6}"
    echo "$SERVER_IP_DEFAULT"
}

# --------------------------
# 生成静态密钥和配置
# --------------------------
generate_config() {
    read -p "请输入 OpenVPN 监听端口 (默认 1194): " PORT
    PORT=${PORT:-1194}

    read -p "请选择协议 udp/tcp (默认 udp): " PROTO
    PROTO=${PROTO:-udp}

    read -p "请输入 VPN 内网 IP 池范围 (server开始IP client结束IP, 默认 10.8.0.1 10.8.0.254): " P2P
    P2P=${P2P:-"10.8.0.1 10.8.0.254"}
    SERVER_IP_POOL_START=$(echo $P2P | awk '{print $1}')
    SERVER_IP_POOL_END=$(echo $P2P | awk '{print $2}')

    # 生成静态密钥
    openvpn --genkey --secret "$SECRET_FILE"
    echo -e "${GREEN}静态密钥生成完成: $SECRET_FILE${NC}"

    # DNS 设置
    echo "选择客户端 DNS:"
    echo "1) Google (8.8.8.8 8.8.4.4)"
    echo "2) Cloudflare (1.1.1.1 1.0.0.1)"
    echo "3) Alibaba (223.5.5.5 223.6.6.6)"
    echo "4) Tencent (119.29.29.29 182.254.116.116)"
    echo "5) 系统默认"
    echo "6) 手动输入"
    read -p "请输入选项 [1-6]: " DNS_CHOICE
    case $DNS_CHOICE in
        1) DNS="8.8.8.8 8.8.4.4" ;;
        2) DNS="1.1.1.1 1.0.0.1" ;;
        3) DNS="223.5.5.5 223.6.6.6" ;;
        4) DNS="119.29.29.29 182.254.116.116" ;;
        5) DNS="" ;;
        6) read -p "请输入 DNS (空格分隔多个): " DNS ;;
        *) DNS="" ;;
    esac

    # 客户端连接地址
    DEFAULT_SERVER_IP=$(get_server_ip)
    read -p "请输入客户端连接地址 (域名或回车默认 $DEFAULT_SERVER_IP): " CLIENT_ADDR
    CLIENT_ADDR=${CLIENT_ADDR:-$DEFAULT_SERVER_IP}

    # 生成服务端配置
    cat > "$SERVER_CONF" <<EOF
dev tun
proto $PROTO
port $PORT
mode server
ifconfig $SERVER_IP_POOL_START $SERVER_IP_POOL_END
secret $SECRET_FILE
cipher AES-128-GCM
auth SHA256
keepalive 10 60
persist-key
persist-tun
status $STATUS_LOG
verb 3
EOF

    # 添加 DNS 推送
    if [ -n "$DNS" ]; then
        for d in $DNS; do
            echo "push \"dhcp-option DNS $d\"" >> "$SERVER_CONF"
        done
    fi

    # systemd 服务
    if [ ! -f "/etc/systemd/system/$SERVICE_NAME" ]; then
        cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=OpenVPN static key server
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/openvpn --config $SERVER_CONF
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME"
    fi

    # 启动服务
    systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}OpenVPN 服务已启动并设置开机自启${NC}"

    # 生成客户端模板
    CLIENT_TEMPLATE="$OVPN_DIR/client-template.ovpn"
    cat > "$CLIENT_TEMPLATE" <<EOF
client
dev tun
proto $PROTO
remote $CLIENT_ADDR $PORT
secret static.key
cipher AES-128-GCM
auth SHA256
persist-key
persist-tun
verb 3
EOF

    echo -e "${GREEN}客户端模板生成完成: $CLIENT_TEMPLATE${NC}"
    echo -e "${GREEN}请将 $SECRET_FILE 和 client-template.ovpn 分发给客户端即可，服务器会自动分配 VPN 内网 IP${NC}"
}

# --------------------------
# 打印客户端连接信息
# --------------------------
print_clients() {
    echo -e "${GREEN}当前客户端连接信息:${NC}"
    if [ -f "$STATUS_LOG" ]; then
        cat "$STATUS_LOG"
    else
        echo "暂无客户端连接信息"
    fi
}

# --------------------------
# 启动 / 停止服务
# --------------------------
control_service() {
    read -p "输入 start / stop / restart: " ACTION
    systemctl "$ACTION" "$SERVICE_NAME"
}

# --------------------------
# 主菜单
# --------------------------
main_menu() {
    while true; do
        echo "=============================="
        echo " OpenVPN 一键管理脚本 (静态密钥 + AES-128-GCM)"
        echo "=============================="
        echo "1) 安装 OpenVPN"
        echo "2) 卸载 OpenVPN（包含删除本脚本）"
        echo "3) 更新 OpenVPN"
        echo "4) 生成 AES-128-GCM + 静态密钥 + 多客户端配置"
        echo "5) 查看客户端连接信息"
        echo "6) 启动 / 停止 OpenVPN 服务"
        echo "0) 退出"
        read -p "请选择操作 [0-6]: " CHOICE

        case $CHOICE in
            1) install_ovpn ;;
            2) uninstall_ovpn ;;
            3) update_ovpn ;;
            4) generate_config ;;
            5) print_clients ;;
            6) control_service ;;
            0) exit 0 ;;
            *) echo "无效选择" ;;
        esac
    done
}

# --------------------------
# 安装 openvpn-easy 命令
# --------------------------
if [ "$1" == "install-cmd" ]; then
    SCRIPT_PATH="$(realpath "$0")"
    ln -sf "$SCRIPT_PATH" /usr/local/bin/openvpn-easy
    echo -e "${GREEN}安装 openvpn-easy 命令成功，现在可输入 openvpn-easy 调出菜单${NC}"
    exit 0
fi

# --------------------------
# 调用主菜单
# --------------------------
main_menu