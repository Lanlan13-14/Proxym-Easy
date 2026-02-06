#!/bin/bash
export TERM=xterm

#================ 颜色定义 =================#
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

BASE_DIR="/usr/local/vpnserver"
VPNSERVER="$BASE_DIR/vpnserver"
VPNCMD="$BASE_DIR/vpncmd"

#================ 工具函数 =================#
install_deps() {
    apt update && apt install -y build-essential curl tar systemctl
}

get_latest_version() {
    curl -s https://api.github.com/repos/SoftEtherVPN/SoftEtherVPN_Stable/releases/latest \
    | grep tag_name | cut -d '"' -f4 | sed 's/^v//'
}

get_local_version() {
    if [ -x "$VPNSERVER" ]; then
        "$VPNSERVER" --version | awk '{print $NF}'
    else
        echo "未安装"
    fi
}

#================ 安装 =================#
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
    cd /usr/local/src || exit
    curl -LO "$URL"

    # 用子 shell避免 cd 回退
    (
        tar zxf "$PKG"
        cd vpnserver || exit
        yes 1 | make
    )

    mv vpnserver "$BASE_DIR"
    cd "$BASE_DIR" || exit
    chmod 600 ./*
    chmod 700 vpncmd vpnserver

    # systemd 服务文件
    cat >/etc/systemd/system/softether-vpnserver.service <<EOF
[Unit]
Description=SoftEther VPN Server
After=network.target

[Service]
Type=forking
ExecStart=$BASE_DIR/vpnserver start
ExecStop=$BASE_DIR/vpnserver stop
WorkingDirectory=$BASE_DIR

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable softether-vpnserver
    systemctl start softether-vpnserver

    echo -e "${GREEN}SoftEther 安装完成${NC}"
}

#================ 更新 =================#
update_softether() {
    CURRENT_VER=$(get_local_version)
    LATEST_VER=$(get_latest_version)

    echo -e "当前版本: ${CURRENT_VER}, 最新版本: ${LATEST_VER}"

    if [ "$CURRENT_VER" = "$LATEST_VER" ]; then
        echo -e "${GREEN}已经是最新版本，无需更新${NC}"
        return
    fi

    read -rp "检测到新版本，是否更新 SoftEther？[y/N] " yn
    case "$yn" in
        [Yy]* )
            echo -e "${GREEN}开始更新 SoftEther...${NC}"
            
            systemctl stop softether-vpnserver || true
            
            BACKUP_DIR="/usr/local/vpnserver.backup.$(date +%F-%H%M)"
            cp -a "$BASE_DIR" "$BACKUP_DIR"
            echo -e "已备份当前版本到: ${BACKUP_DIR}"

            PKG="softether-vpnserver-v${LATEST_VER}-linux-x64-64bit.tar.gz"
            URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v${LATEST_VER}/${PKG}"
            cd /tmp || exit
            curl -LO "$URL"

            (
                tar zxf "$PKG"
                cd vpnserver || exit
                yes 1 | make
            )

            cp vpnserver vpncmd "$BASE_DIR/"
            chmod 600 "$BASE_DIR"/*
            chmod 700 "$BASE_DIR"/vpnserver "$BASE_DIR"/vpncmd

            systemctl start softether-vpnserver

            echo -e "${GREEN}更新完成！${NC}"
            ;;
        * )
            echo "已取消更新"
            ;;
    esac
}

#================ 卸载 =================#
uninstall_softether() {
    systemctl stop softether-vpnserver || true
    systemctl disable softether-vpnserver || true
    rm -f /etc/systemd/system/softether-vpnserver.service
    systemctl daemon-reload
    rm -rf "$BASE_DIR"
    echo -e "${RED}SoftEther 已卸载${NC}"
}

#================ 服务管理 =================#
service_softether() {
    while true; do
        echo -e "\n--- 服务管理 ---"
        echo "[1] 启动"
        echo "[2] 停止"
        echo "[3] 重启"
        echo "[0] 返回主菜单"
        read -rp "请选择: " s
        case "$s" in
            1) systemctl start softether-vpnserver ;;
            2) systemctl stop softether-vpnserver ;;
            3) systemctl restart softether-vpnserver ;;
            0) break ;;
            *) echo "无效选项" ;;
        esac
    done
}

#================ 配置生成 =================#
config_softether() {
    echo -e "${GREEN}生成 SoftEther 配置文件...${NC}"
    # 示例配置，可根据需求修改
    cat >"$BASE_DIR/config.txt" <<EOF
# SoftEther 配置示例
# TCP + AES128/AES256 + DNS 推送
EOF
    echo -e "${GREEN}配置文件已生成: $BASE_DIR/config.txt${NC}"
}

#================ 查看客户端连接 =================#
show_clients() {
    echo -e "${GREEN}查看客户端连接...${NC}"
    $VPNCMD localhost /SERVER /CMD SessionList
}

#================ 查看日志/状态 =================#
show_logs() {
    while true; do
        echo -e "\n--- 日志/状态 ---"
        echo "[1] 查看日志"
        echo "[2] 查看系统状态"
        echo "[0] 返回主菜单"
        read -rp "请选择: " l
        case "$l" in
            1) journalctl -u softether-vpnserver -n 50 ;;
            2) systemctl status softether-vpnserver ;;
            0) break ;;
            *) echo "无效选项" ;;
        esac
    done
}

#================ 主菜单 =================#
menu() {
    while true; do
        echo -e "\nSoftEther Easy Manager"
        echo "====================="
        echo "[1] 安装 SoftEther VPN Server"
        echo "[2] 卸载 SoftEther"
        echo "[3] 启动 / 停止 / 重启"
        echo "[4] 生成 SoftEther 配置文件"
        echo "[5] 查看客户端连接"
        echo "[6] 查看日志 / 状态"
        echo "[7] 更新 SoftEther"
        echo "[0] 退出"
        read -rp "请选择操作: " choice

        case "$choice" in
            1) install_softether ;;
            2) uninstall_softether ;;
            3) service_softether ;;
            4) config_softether ;;
            5) show_clients ;;
            6) show_logs ;;
            7) update_softether ;;
            0) echo "下次使用请输入 softether-easy"; break ;;
            *) echo "无效选项" ;;
        esac
    done
}

menu