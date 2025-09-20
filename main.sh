#!/bin/bash

# 主脚本用于管理 mihomo 服务器，调用 generate_vless_listener.sh 生成 VLESS 配置。
# 功能：
# - 可扩展的 Listener 管理：通过独立脚本生成 VLESS 配置，追加到 inbounds 列表，保留或覆盖 dns 配置。
# - 使用 yq 确保 YAML 语法准确，日志级别设为 error。
# - 自动检查端口占用，推荐可用端口。
# - 动态获取最新 mihomo 版本。
# - 自动安装依赖（不包括 vim）。
# - 使用 systemd 管理 mihomo 服务。
# - 命令行管理面板，支持启动、停止、重启、状态、日志、测试配置、添加 Listener、编辑配置、安装、更新、卸载。
# 使用方法：./mihomo-server.sh [menu|start|stop|restart|status|log|test|install|update|uninstall]
# 依赖：yq, generate_vless_listener.sh

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

# 路径定义
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/mihomo"
WORK_DIR="/var/lib/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
LOG_FILE="/var/log/mihomo.log"
GENERATE_VLESS_SCRIPT="./generate_vless_listener.sh"

# 函数: 获取最新 mihomo 版本
get_mihomo_version() {
    VERSION=$(curl --retry 2 --max-time 5 -sL https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/version.txt)
    if [[ -z "${VERSION}" ]]; then
        echo -e "${RED}⚠️ 无法获取 mihomo 版本，请检查网络！${NC}"
        exit 1
    fi
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/mihomo-linux-amd64-${VERSION}.gz"
}

# 函数: 检查 mihomo 是否已安装
check_mihomo() {
    [ -f "${INSTALL_DIR}/mihomo" ] && [ -x "${INSTALL_DIR}/mihomo" ]
}

# 函数: 安装依赖
install_dependencies() {
    echo -e "${YELLOW}安装依赖...${NC}"
    if command -v apt-get &> /dev/null; then
        if ! apt-get update -y; then
            echo -e "${RED}⚠️ apt-get update 失败！请检查网络或软件源。${NC}"
            exit 1
        fi
        if ! apt-get install -y curl gzip wget openssl coreutils iproute2 net-tools yq; then
            echo -e "${RED}⚠️ 依赖安装失败！请检查网络或软件源。${NC}"
            exit 1
        fi
    elif command -v yum &> /dev/null; then
        if ! yum update -y; then
            echo -e "${RED}⚠️ yum update 失败！请检查网络或软件源。${NC}"
            exit 1
        fi
        if ! yum install -y curl gzip wget openssl coreutils iproute2 net-tools yq; then
            echo -e "${RED}⚠️ 依赖安装失败！请检查网络或软件源。${NC}"
            exit 1
        fi
    elif command -v dnf &> /dev/null; then
        if ! dnf check-update -y; then
            echo -e "${RED}⚠️ dnf check-update 失败！请检查网络或软件源。${NC}"
            exit 1
        fi
        if ! dnf install -y curl gzip wget openssl coreutils iproute2 net-tools yq; then
            echo -e "${RED}⚠️ 依赖安装失败！请检查网络或软件源。${NC}"
            exit 1
        fi
    else
        echo -e "${RED}⚠️ 不支持的包管理器。请手动安装 curl、gzip、wget、openssl、coreutils、iproute2、net-tools 和 yq。${NC}"
        exit 1
    fi
}

# 函数: 安装 mihomo
install_mihomo() {
    echo -e "${YELLOW}🚀 安装 mihomo...${NC}"
    install_dependencies
    mkdir -p "${CONFIG_DIR}" "${WORK_DIR}"
    chown -R root:root "${CONFIG_DIR}" "${WORK_DIR}"
    chmod 755 "${CONFIG_DIR}" "${WORK_DIR}"
    get_mihomo_version
    echo -e "${YELLOW}下载 mihomo ${VERSION}...${NC}"
    if ! curl --retry 2 --max-time 5 -sL "${DOWNLOAD_URL}" | gunzip -c > "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 下载或解压 mihomo 失败，请检查网络或版本。${NC}"
        exit 1
    fi
    chmod +x "${INSTALL_DIR}/mihomo"
    if ! setcap 'cap_net_bind_service,cap_net_admin=+ep' "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 设置权限失败！${NC}"
        exit 1
    fi
    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=mihomo Daemon, Another Clash Kernel
Documentation=https://wiki.metacubex.one/
After=network.target NetworkManager.service systemd-networkd.service iwd.service nss-lookup.target
Wants=nss-lookup.target

[Service]
Type=simple
User=root
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStartPre=/usr/bin/sleep 1s
ExecStart=${INSTALL_DIR}/mihomo -d ${CONFIG_DIR}
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    if ! systemctl daemon-reload; then
        echo -e "${RED}⚠️ systemctl daemon-reload 失败！${NC}"
        exit 1
    fi
    if ! systemctl enable mihomo; then
        echo -e "${RED}⚠️ systemctl enable mihomo 失败！${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ mihomo 安装完成！请手动生成配置文件或启动服务。${NC}"
}

# 函数: 更新 mihomo
update_mihomo() {
    echo -e "${YELLOW}🚀 更新 mihomo...${NC}"
    systemctl stop mihomo || true
    get_mihomo_version
    echo -e "${YELLOW}下载 mihomo ${VERSION}...${NC}"
    if ! curl --retry 2 --max-time 5 -sL "${DOWNLOAD_URL}" | gunzip -c > "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 下载或解压 mihomo 失败，请检查网络或版本。${NC}"
        exit 1
    fi
    chmod +x "${INSTALL_DIR}/mihomo"
    if ! setcap 'cap_net_bind_service,cap_net_admin=+ep' "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 设置权限失败！${NC}"
        exit 1
    fi
    systemctl daemon-reload
    if [[ -f "${CONFIG_FILE}" ]]; then
        systemctl start mihomo || { echo -e "${RED}⚠️ 启动 mihomo 失败！请检查日志: journalctl -u mihomo${NC}"; exit 1; }
    fi
    echo -e "${GREEN}✅ mihomo 更新完成！${NC}"
}

# 函数: 卸载 mihomo
uninstall_mihomo() {
    echo -e "${YELLOW}🚀
