#!/bin/bash

# 主脚本用于管理 mihomo 服务器，调用 script/vless_encryption.sh 生成 VLESS 配置。
# 功能：
# - 可扩展的 Listener 管理：通过独立脚本生成 VLESS 配置，追加到 inbounds 列表，保留或覆盖 dns 配置。
# - 使用 yq 确保 YAML 语法准确，日志级别设为 error。
# - 自动检查端口占用，推荐可用端口。
# - 动态获取最新 mihomo 版本。
# - 自动安装依赖（不包括 vim）。
# - 使用 systemd 管理 mihomo 服务。
# - 默认运行显示管理面板，支持命令行参数。
# - 支持远程更新脚本（备份+下载+语法检查+回滚）。
# 使用方法：proxym-easy [menu|start|stop|restart|status|log|test|install|update|uninstall|update-scripts]
# 安装命令：curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/main.sh -o /tmp/proxym-easy && chmod +x /tmp/proxym-easy && sudo mv /tmp/proxym-easy /usr/local/bin/proxym-easy && sudo proxym-easy
# 依赖：yq, script/vless_encryption.sh

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 路径定义
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/mihomo"
WORK_DIR="/var/lib/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
LOG_FILE="/var/log/mihomo.log"
VLESS_SCRIPT="${INSTALL_DIR}/script/vless_encryption.sh"
MAIN_URL="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/main.sh"
VLESS_URL="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/script/vless_encryption.sh"

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
    mkdir -p "${CONFIG_DIR}" "${WORK_DIR}" "${INSTALL_DIR}/script"
    chown -R root:root "${CONFIG_DIR}" "${WORK_DIR}" "${INSTALL_DIR}/script"
    chmod 755 "${CONFIG_DIR}" "${WORK_DIR}" "${INSTALL_DIR}/script"
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
    # 下载 vless_encryption.sh
    echo -e "${YELLOW}下载 vless_encryption.sh...${NC}"
    if ! curl -s -o "${VLESS_SCRIPT}" "$VLESS_URL"; then
        echo -e "${RED}⚠️ 下载 vless_encryption.sh 失败！${NC}"
        exit 1
    fi
    chmod +x "${VLESS_SCRIPT}"
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
    echo -e "${GREEN}✅ mihomo 安装完成！请运行 'proxym-easy' 配置或管理服务。${NC}"
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
    echo -e "${YELLOW}🚀 卸载 mihomo...${NC}"
    systemctl stop mihomo || true
    systemctl disable mihomo || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    rm -rf "${INSTALL_DIR}/mihomo" "${CONFIG_DIR}" "${WORK_DIR}" "${LOG_FILE}" "${INSTALL_DIR}/script"
    echo -e "${GREEN}✅ mihomo 卸载完成！${NC}"
}

# 函数: 添加 Listener 到配置文件（仅追加 inbounds，保留 dns 等其他字段）
add_listener_to_config() {
    local config_yaml="$1"
    local overwrite_dns=false
    if [ -f "${CONFIG_FILE}" ] && yq eval '.dns' "${CONFIG_FILE}" > /dev/null 2>&1; then
        echo -e "${YELLOW}检测到现有 DNS 配置，是否覆盖？(y/n，默认 n): ${NC}"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            overwrite_dns=true
        fi
    fi
    if [ ! -f "${CONFIG_FILE}" ] || [ "$overwrite_dns" = true ]; then
        # 如果不存在或选择覆盖，直接使用完整配置
        mkdir -p "${CONFIG_DIR}"
        echo "$config_yaml" > "${CONFIG_FILE}"
        chmod 644 "${CONFIG_FILE}"
        echo -e "${GREEN}✅ 配置文件已创建/覆盖并添加 Listener。路径: ${CONFIG_FILE}${NC}"
    else
        # 提取新配置中的 inbounds 部分
        local listener_yaml
        listener_yaml=$(yq eval '.inbounds[0]' - <<< "$config_yaml")
        # 追加到现有配置的 inbounds 列表
        yq eval ".inbounds += [yamldecode(\"$listener_yaml\")]" -i "${CONFIG_FILE}"
        echo -e "${GREEN}✅ 新 Listener 已追加到现有配置文件，保留现有 DNS 配置。${NC}"
    fi
}

# 函数: 生成或更新配置（调用外部脚本）
generate_config() {
    if ! command -v yq &> /dev/null; then
        echo -e "${RED}⚠️ yq 未安装，请运行 proxym-easy install！${NC}"
        exit 1
    fi
    if [ ! -f "${VLESS_SCRIPT}" ]; then
        echo -e "${RED}⚠️ VLESS 生成脚本 ${VLESS_SCRIPT} 不存在！请运行 proxym-easy install！${NC}"
        exit 1
    fi
    if ! chmod +x "${VLESS_SCRIPT}"; then
        echo -e "${RED}⚠️ 无法为 ${VLESS_SCRIPT} 设置执行权限！${NC}"
        exit 1
    fi
    local config=$("${VLESS_SCRIPT}")
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 生成 VLESS 配置失败！${NC}"
        exit 1
    fi
    add_listener_to_config "$config"
}

# 函数: 编辑配置（使用 vim）
edit_config() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo -e "${RED}⚠️ 未找到配置文件，正在生成新配置...${NC}"
        generate_config
        return
    fi
    if ! command -v vim &> /dev/null; then
        echo -e "${RED}⚠️ vim 未安装，请手动安装 vim！${NC}"
        exit 1
    fi
    vim "${CONFIG_FILE}"
    echo -e "${GREEN}✅ 配置文件编辑完成。请测试配置有效性。${NC}"
}

# 函数: 启动 mihomo
start_mihomo() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 不存在，请先生成配置！${NC}"
        exit 1
    fi
    if ! systemctl start mihomo; then
        echo -e "${RED}⚠️ 启动失败！请检查日志: journalctl -u mihomo${NC}"
        journalctl -u mihomo --no-pager
        exit 1
    fi
    echo -e "${GREEN}✅ mihomo 启动成功！${NC}"
}

# 函数: 重启 mihomo
restart_mihomo() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 不存在，请先生成配置！${NC}"
        exit 1
    fi
    if ! systemctl restart mihomo; then
        echo -e "${RED}⚠️ 重启失败！请检查日志: journalctl -u mihomo${NC}"
        journalctl -u mihomo --no-pager
        exit 1
    fi
    echo -e "${GREEN}✅ mihomo 重启成功！${NC}"
}

# 函数: 停止 mihomo
stop_mihomo() {
    if ! systemctl stop mihomo; then
        echo -e "${RED}⚠️ 停止失败！请检查日志: journalctl -u mihomo${NC}"
        journalctl -u mihomo --no-pager
        exit 1
    fi
    echo -e "${GREEN}✅ mihomo 停止成功！${NC}"
}

# 函数: 查看 mihomo 状态
status_mihomo() {
    if systemctl is-active --quiet mihomo; then
        echo -e "${GREEN}✅ mihomo 运行中:${NC}"
        systemctl status mihomo --no-pager
    else
        echo -e "${RED}⚠️ mihomo 未运行${NC}"
    fi
}

# 函数: 查看 mihomo 日志
logs_mihomo() {
    echo -e "${YELLOW}🚀 查看 mihomo 日志（按 Ctrl+C 退出）...${NC}"
    journalctl -u mihomo -f
}

# 函数: 测试配置
test_config() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        exit 1
    fi
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 不存在，请先生成配置！${NC}"
        exit 1
    fi
    if "${INSTALL_DIR}/mihomo" -t -d "${CONFIG_DIR}"; then
        echo -e "${GREEN}✅ 配置文件测试通过！${NC}"
    else
        echo -e "${RED}⚠️ 配置文件测试失败，请检查 ${CONFIG_FILE}！${NC}"
        exit 1
    fi
}

# 函数: 添加新 VLESS Listener
add_new_listener() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        exit 1
    fi
    generate_config
}

# 函数: 更新脚本（远程下载+备份+语法检查+回滚）
update_scripts() {
    echo -e "${YELLOW}🚀 更新脚本（proxym-easy 和 vless_encryption.sh）...${NC}"
    mkdir -p "${INSTALL_DIR}/script"
    # 更新 proxym-easy
    cp "${INSTALL_DIR}/proxym-easy" "${INSTALL_DIR}/proxym-easy.bak"
    if ! curl -s -o "${INSTALL_DIR}/proxym-easy.tmp" "$MAIN_URL"; then
        echo -e "${RED}⚠️ 下载 proxym-easy 失败！${NC}"
        rm -f "${INSTALL_DIR}/proxym-easy.tmp"
        mv "${INSTALL_DIR}/proxym-easy.bak" "${INSTALL_DIR}/proxym-easy"
        return 1
    fi
    if bash -n "${INSTALL_DIR}/proxym-easy.tmp"; then
        mv "${INSTALL_DIR}/proxym-easy.tmp" "${INSTALL_DIR}/proxym-easy"
        chmod +x "${INSTALL_DIR}/proxym-easy"
        rm -f "${INSTALL_DIR}/proxym-easy.bak"
        echo -e "${GREEN}✅ proxym-easy 更新成功！${NC}"
    else
        echo -e "${RED}⚠️ proxym-easy 语法检查失败，回滚备份。${NC}"
        rm -f "${INSTALL_DIR}/proxym-easy.tmp"
        mv "${INSTALL_DIR}/proxym-easy.bak" "${INSTALL_DIR}/proxym-easy"
        return 1
    fi
    # 更新 vless_encryption.sh
    cp "${VLESS_SCRIPT}" "${VLESS_SCRIPT}.bak" 2>/dev/null || true
    if ! curl -s -o "${VLESS_SCRIPT}.tmp" "$VLESS_URL"; then
        echo -e "${RED}⚠️ 下载 vless_encryption.sh 失败！${NC}"
        rm -f "${VLESS_SCRIPT}.tmp"
        mv "${VLESS_SCRIPT}.bak" "${VLESS_SCRIPT}" 2>/dev/null || true
        return 1
    fi
    if bash -n "${VLESS_SCRIPT}.tmp"; then
        mv "${VLESS_SCRIPT}.tmp" "${VLESS_SCRIPT}"
        chmod +x "${VLESS_SCRIPT}"
        rm -f "${VLESS_SCRIPT}.bak"
        echo -e "${GREEN}✅ vless_encryption.sh 更新成功！${NC}"
    else
        echo -e "${RED}⚠️ vless_encryption.sh 语法检查失败，回滚备份。${NC}"
        rm -f "${VLESS_SCRIPT}.tmp"
        mv "${VLESS_SCRIPT}.bak" "${VLESS_SCRIPT}" 2>/dev/null || true
        return 1
    fi
}

# 函数: 管理面板
show_menu() {
    echo -e "${YELLOW}=== Proxym-Easy 管理面板 ===${NC}"
    echo "1. 启动 mihomo"
    echo "2. 停止 mihomo"
    echo "3. 重启 mihomo"
    echo "4. 查看状态"
    echo "5. 查看日志"
    echo "6. 测试配置"
    echo "7. 添加新 VLESS Listener"
    echo "8. 编辑配置文件（使用 vim）"
    echo "9. 安装 mihomo"
    echo "10. 更新 mihomo"
    echo "11. 卸载 mihomo"
    echo "12. 更新脚本（proxym-easy 和 vless_encryption.sh）"
    echo "13. 退出"
    echo -n "请选择选项 [1-13]："
    read -r choice
    case $choice in
        1) start_mihomo ;;
        2) stop_mihomo ;;
        3) restart_mihomo ;;
        4) status_mihomo ;;
        5) logs_mihomo ;;
        6) test_config ;;
        7) add_new_listener ;;
        8) edit_config ;;
        9) install_mihomo ;;
        10) update_mihomo ;;
        11) uninstall_mihomo ;;
        12) update_scripts ;;
        13) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1; show_menu ;;
    esac
}

# 主逻辑
case "$1" in
    start)
        if ! check_mihomo; then
            echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
            exit 1
        fi
        if [ ! -f "${CONFIG_FILE}" ]; then
            generate_config
        fi
        start_mihomo
        ;;
    stop)
        stop_mihomo
        ;;
    restart)
        restart_mihomo
        ;;
    status)
        status_mihomo
        ;;
    log)
        logs_mihomo
        ;;
    test)
        test_config
        ;;
    install)
        install_mihomo
        ;;
    update)
        update_mihomo
        ;;
    uninstall)
        uninstall_mihomo
        ;;
    update-scripts)
        update_scripts
        ;;
    menu)
        show_menu
        ;;
    *)
        if ! check_mihomo; then
            echo -e "${YELLOW}mihomo 未安装，正在安装...${NC}"
            install_mihomo
            generate_config
            start_mihomo
        fi
        show_menu
        ;;
esac