#!/bin/bash
# SoftEther Easy Manager - 完整菜单版
# Author: Andy Bright style

set -e

BASE_DIR="/usr/local/vpnserver"
VPNCMD="$BASE_DIR/vpncmd"
VPNSERVER="$BASE_DIR/vpnserver"
HUB="EASY"
LOG_FILE="$BASE_DIR/server.log"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

require_root() {
    [ "$(id -u)" != "0" ] && echo -e "${RED}请使用 root 运行${NC}" && exit 1
}

install_deps() {
    if command -v apt >/dev/null; then
        apt update
        apt install -y build-essential jq curl tar
    elif command -v yum >/dev/null; then
        yum install -y gcc make jq curl tar
    fi
}

get_latest_version() {
    curl -s "https://api.github.com/repos/SoftEtherVPN/SoftEtherVPN/releases/latest" | jq -r '.tag_name'
}

get_local_version() {
    if [ -x "$VPNCMD" ]; then
        $VPNCMD localhost /SERVER /CMD Version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    else
        echo "0"
    fi
}

install_softether() {
    if [ -x "$VPNSERVER" ]; then
        echo -e "${GREEN}SoftEther 已安装${NC}"
        return
    fi

    install_deps
    VERSION=$(get_latest_version)
    PKG="softether-vpnserver-v${VERSION}-linux-x64-64bit.tar.gz"
    URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v${VERSION}/${PKG}"

    echo -e "${GREEN}检测到最新版本: $VERSION${NC}"
    echo "下载: $URL"
    mkdir -p /usr/local/src
    cd /usr/local/src
    curl -LO "$URL"

    tar zxf "$PKG"
    cd vpnserver
    yes 1 | make

    cd ..
    mv vpnserver "$BASE_DIR"
    cd "$BASE_DIR"
    chmod 600 ./*
    chmod 700 vpncmd vpnserver

    echo -e "${GREEN}SoftEther 安装完成${NC}"
}

uninstall_softether() {
    systemctl stop softether-vpnserver 2>/dev/null || true
    rm -rf "$BASE_DIR"
    rm -f /etc/systemd/system/softether.service
    systemctl daemon-reload
    echo -e "${RED}SoftEther 已卸载${NC}"
}

configure_softether() {
    read -rp "请输入监听端口 (默认 443): " PORT
    PORT=${PORT:-443}

    echo "选择加密算法："
    echo "[1] AES128"
    echo "[2] AES256"
    read -rp "选择: " cipher_choice
    case $cipher_choice in
        1) CIPHER="AES128" ;;
        2) CIPHER="AES256" ;;
        *) echo "默认 AES128"; CIPHER="AES128" ;;
    esac

    echo "选择 DNS 推送设置："
    echo "[1] Google"
    echo "[2] Cloudflare"
    echo "[3] 阿里"
    echo "[4] 腾讯"
    echo "[5] 系统"
    echo "[6] 自定义"
    read -rp "选择: " d
    case $d in
        1) DNS="8.8.8.8,8.8.4.4" ;;
        2) DNS="1.1.1.1,1.0.0.1" ;;
        3) DNS="223.5.5.5,223.6.6.6" ;;
        4) DNS="119.29.29.29,182.254.116.116" ;;
        5) DNS="" ;;
        6) read -rp "输入 DNS（逗号分隔）: " DNS ;;
        *) DNS="" ;;
    esac

    # 删除已有 Listener 并创建新 TCP Listener
    $VPNCMD localhost /SERVER <<EOF
ListenerDeleteAll
ListenerCreate $PORT /TCP
EOF

    # 配置 Hub, SecureNAT, Cipher, DNS
    $VPNCMD localhost /SERVER <<EOF
Hub $HUB
SecureNatEnable
CipherSet $CIPHER
DhcpSet /DNS:$DNS
EOF

    echo -e "${GREEN}生成 SoftEther 配置文件完成${NC}"
}

show_clients() {
    $VPNCMD localhost /SERVER <<EOF
Hub $HUB
SessionList
EOF
}

view_log() {
    echo -e "${GREEN}==== SoftEther 日志 ==== ${NC}"
    tail -n 50 "$LOG_FILE"
}

view_status() {
    systemctl status softether-vpnserver --no-pager
}

install_service() {
    cat >/etc/systemd/system/softether-vpnserver.service <<EOF
[Unit]
Description=SoftEther VPN Server
After=network.target

[Service]
Type=forking
ExecStart=$VPNSERVER start
ExecStop=$VPNSERVER stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable softether-vpnserver
}

update_softether() {
    CURRENT_VER=$(get_local_version)
    LATEST_VER=$(get_latest_version)
    echo -e "当前版本: $CURRENT_VER, 最新版本: $LATEST_VER"
    if [ "$CURRENT_VER" = "$LATEST_VER" ]; then
        echo "已是最新版本"
        return
    fi
    read -rp "检测到新版本，是否更新 SoftEther？[y/N] " yn
    case $yn in
        [Yy]*)
            echo "更新 SoftEther..."
            systemctl stop softether-vpnserver || true
            BACKUP_DIR="/usr/local/vpnserver.backup.$(date +%F-%H%M)"
            cp -a "$BASE_DIR" "$BACKUP_DIR"
            echo "已备份当前版本到 $BACKUP_DIR"
            PKG="softether-vpnserver-v${LATEST_VER}-linux-x64-64bit.tar.gz"
            URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v${LATEST_VER}/${PKG}"
            cd /tmp
            curl -LO "$URL"
            tar zxf "$PKG"
            cd vpnserver
            yes 1 | make
            cp vpnserver vpncmd "$BASE_DIR/"
            chmod 600 "$BASE_DIR"/*
            chmod 700 "$BASE_DIR"/vpnserver "$BASE_DIR"/vpncmd
            systemctl start softether-vpnserver
            echo -e "${GREEN}更新完成${NC}"
            ;;
        *) echo "已取消更新" ;;
    esac
}

require_root
install_deps
install_service

while true; do
    clear
    echo "SoftEther Easy Manager"
    echo "====================="
    echo "[1] 安装 SoftEther VPN Server"
    echo "[2] 卸载 SoftEther"
    echo "[3] 启动 / 停止 / 重启"
    echo "[4] 生成 SoftEther 配置文件"
    echo "[5] 查看客户端连接"
    echo "[6] 查看日志 / 状态"
    echo "[7] 更新 SoftEther"
    echo "[0] 退出"
    read -rp "选择: " c
    case $c in
        1) install_softether ;;
        2) uninstall_softether ;;
        3)
            echo "[1] 启动 [2] 停止 [3] 重启"
            read -rp "选择: " s
            case $s in
                1) systemctl start softether-vpnserver ;;
                2) systemctl stop softether-vpnserver ;;
                3) systemctl restart softether-vpnserver ;;
                *) echo "无效选择" ;;
            esac
            ;;
        4) configure_softether ;;
        5) show_clients ;;
        6)
            echo "[1] 查看日志 [2] 查看系统状态"
            read -rp "选择: " s
            case $s in
                1) view_log ;;
                2) view_status ;;
                *) echo "无效选择" ;;
            esac
            read -rp "回车继续..."
            ;;
        7) update_softether ;;
        0)
            echo -e "退出 softether-easy，下次使用请输入 ${GREEN}softether-easy${NC}"
            exit 0
            ;;
        *) echo "无效选择" ;;
    esac
    read -rp "回车继续..."
done