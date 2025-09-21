#!/bin/bash

# 🚀 主脚本用于管理 mihomo 服务器，调用子脚本生成 VLESS 配置。
# 功能：
# - 提供管理面板，调用 vless_encryption.sh 生成节点配置。
# - 使用 systemd 管理 mihomo 服务。
# - 支持安装、更新、卸载 mihomo，更新主脚本。
# - 所有选项（成功或失败）返回主菜单，[13] 退出显示提示。
# - 卸载子菜单：[1] 卸载脚本，[2] 卸载 mihomo，[3] 卸载全部，[4] 返回主菜单。
# - 移除 30 秒输入超时。
# 使用方法：proxym-easy [menu|start|stop|restart|status|log|test|install|update|uninstall|update-scripts|generate-config|delete]
# 安装命令：curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/main.sh -o /tmp/proxym-easy && chmod +x /tmp/proxym-easy && sudo mv /tmp/proxym-easy /usr/local/bin/proxym-easy && sudo proxym-easy
# 依赖：yq

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
        return 1
    fi
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/mihomo-linux-amd64-${VERSION}.gz"
    return 0
}

# 函数: 检查 mihomo 是否已安装
check_mihomo() {
    [ -f "${INSTALL_DIR}/mihomo" ] && [ -x "${INSTALL_DIR}/mihomo" ]
}

# 函数: 安装依赖
install_dependencies() {
    echo -e "${YELLOW}📦 安装依赖...${NC}"
    if command -v apt-get &> /dev/null; then
        if ! apt-get update -y; then
            echo -e "${RED}⚠️ apt-get update 失败！请检查网络或软件源。${NC}"
            return 1
        fi
        if ! apt-get install -y curl gzip wget openssl coreutils iproute2 net-tools yq; then
            echo -e "${RED}⚠️ 依赖安装失败！请检查网络或软件源。${NC}"
            return 1
        fi
    elif command -v yum &> /dev/null; then
        if ! yum update -y; then
            echo -e "${RED}⚠️ yum update 失败！请检查网络或软件源。${NC}"
            return 1
        fi
        if ! yum install -y curl gzip wget openssl coreutils iproute2 net-tools yq; then
            echo -e "${RED}⚠️ 依赖安装失败！请检查网络或软件源。${NC}"
            return 1
        fi
    elif command -v dnf &> /dev/null; then
        if ! dnf check-update -y; then
            echo -e "${RED}⚠️ dnf check-update 失败！请检查网络或软件源。${NC}"
            return 1
        fi
        if ! dnf install -y curl gzip wget openssl coreutils iproute2 net-tools yq; then
            echo -e "${RED}⚠️ 依赖安装失败！请检查网络或软件源。${NC}"
            return 1
        fi
    else
        echo -e "${RED}⚠️ 不支持的包管理器。请手动安装 curl、gzip、wget、openssl、coreutils、iproute2、net-tools 和 yq。${NC}"
        return 1
    fi
    return 0
}

# 函数: 安装 mihomo
install_mihomo() {
    echo -e "${YELLOW}🚀 安装 mihomo...${NC}"
    if ! install_dependencies; then
        echo -e "${RED}⚠️ 依赖安装失败！${NC}"
        return 1
    fi
    mkdir -p "${CONFIG_DIR}" "${WORK_DIR}"
    chown -R root:root "${CONFIG_DIR}" "${WORK_DIR}"
    chmod 755 "${CONFIG_DIR}" "${WORK_DIR}"
    if ! get_mihomo_version; then
        echo -e "${RED}⚠️ 获取 mihomo 版本失败！${NC}"
        return 1
    fi
    echo -e "${YELLOW}📥 下载 mihomo ${VERSION}...${NC}"
    if ! curl --retry 2 --max-time 5 -sL "${DOWNLOAD_URL}" | gunzip -c > "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 下载或解压 mihomo 失败，请检查网络或版本。${NC}"
        return 1
    fi
    chmod +x "${INSTALL_DIR}/mihomo"
    if ! setcap 'cap_net_bind_service,cap_net_admin=+ep' "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 设置权限失败！${NC}"
        return 1
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
        return 1
    fi
    if ! systemctl enable mihomo; then
        echo -e "${RED}⚠️ systemctl enable mihomo 失败！${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ mihomo 安装完成！运行 'proxym-easy' 配置或管理服务。${NC}"
    return 0
}

# 函数: 更新 mihomo
update_mihomo() {
    echo -e "${YELLOW}🚀 更新 mihomo...${NC}"
    systemctl stop mihomo || true
    if ! get_mihomo_version; then
        echo -e "${RED}⚠️ 获取 mihomo 版本失败！${NC}"
        return 1
    fi
    echo -e "${YELLOW}📥 下载 mihomo ${VERSION}...${NC}"
    if ! curl --retry 2 --max-time 5 -sL "${DOWNLOAD_URL}" | gunzip -c > "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 下载或解压 mihomo 失败，请检查网络或版本。${NC}"
        return 1
    fi
    chmod +x "${INSTALL_DIR}/mihomo"
    if ! setcap 'cap_net_bind_service,cap_net_admin=+ep' "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 设置权限失败！${NC}"
        return 1
    fi
    systemctl daemon-reload
    if [[ -f "${CONFIG_FILE}" ]]; then
        if ! systemctl start mihomo; then
            echo -e "${RED}⚠️ 启动 mihomo 失败！请检查日志: journalctl -u mihomo${NC}"
            return 1
        fi
    fi
    echo -e "${GREEN}✅ mihomo 更新完成！${NC}"
    return 0
}

# 函数: 卸载 mihomo
uninstall_mihomo() {
    echo -e "${YELLOW}🗑️ 卸载 mihomo...${NC}"
    systemctl stop mihomo || true
    systemctl disable mihomo || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    rm -rf "${INSTALL_DIR}/mihomo" "${CONFIG_DIR}" "${WORK_DIR}" "${LOG_FILE}"
    echo -e "${GREEN}✅ mihomo 卸载完成！${NC}"
    return 0
}

# 函数: 卸载脚本和/或 mihomo
uninstall() {
    echo -e "${YELLOW}🗑️ 卸载选项 🗑️${NC}"
    echo "[1] 卸载脚本（保留 mihomo）"
    echo "[2] 卸载 mihomo（保留主脚本）"
    echo "[3] 卸载全部（mihomo 和主脚本）"
    echo "[4] 返回主菜单"
    echo -n "请选择选项 [1-4]："
    read -r choice
    case $choice in
        1)
            if [ -f "${INSTALL_DIR}/proxym-easy" ]; then
                rm -f "${INSTALL_DIR}/proxym-easy" "${INSTALL_DIR}/script/vless_encryption.sh" 2>/dev/null
                echo -e "${GREEN}✅ proxym-easy 和子脚本已删除！${NC}"
            else
                echo -e "${RED}⚠️ proxym-easy 不存在！${NC}"
            fi
            return 0
            ;;
        2)
            uninstall_mihomo
            return 0
            ;;
        3)
            uninstall_mihomo
            if [ -f "${INSTALL_DIR}/proxym-easy" ]; then
                rm -f "${INSTALL_DIR}/proxym-easy" "${INSTALL_DIR}/script/vless_encryption.sh" 2>/dev/null
                echo -e "${GREEN}✅ proxym-easy 和子脚本已删除！${NC}"
            else
                echo -e "${RED}⚠️ proxym-easy 不存在！${NC}"
            fi
            return 0
            ;;
        4)
            return 0
            ;;
        *)
            echo -e "${RED}⚠️ 无效选项${NC}"
            uninstall
            ;;
    esac
}

# 函数: 下载协议脚本
download_protocol_script() {
    local protocol="$1"
    if [ "$protocol" != "vless" ]; then
        echo -e "${RED}⚠️ 当前仅支持 VLESS Encryption 协议！${NC}"
        return 1
    fi
    mkdir -p "${INSTALL_DIR}/script"
    echo -e "${YELLOW}📥 下载 vless_encryption.sh...${NC}"
    if ! curl -s --max-time 5 -o "${VLESS_SCRIPT}" "$VLESS_URL"; then
        echo -e "${RED}⚠️ 下载 vless_encryption.sh 失败！请检查网络。${NC}"
        return 1
    fi
    chmod +x "${VLESS_SCRIPT}" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 设置 vless_encryption.sh 权限失败！${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ vless_encryption.sh 下载完成！${NC}"
    return 0
}

# 函数: 生成节点配置
generate_node_config() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        return 1
    fi
    echo -e "${YELLOW}🌟 选择协议 🌟${NC}"
    echo "[1] VLESS Encryption"
    echo "[2] 返回主菜单"
    echo -n "请选择协议 [1-2]："
    read -r protocol_choice
    case $protocol_choice in
        1)
            if [ -f "${VLESS_SCRIPT}" ]; then
                echo -e "${YELLOW}📄 VLESS 脚本已存在，是否重新下载？(y/n，默认 n): ${NC}"
                read -r redownload
                redownload=${redownload:-n}
                if [[ "$redownload" =~ ^[Yy]$ ]]; then
                    rm -f "${VLESS_SCRIPT}" 2>/dev/null
                    echo -e "${YELLOW}📥 重新下载 VLESS 脚本...${NC}"
                else
                    echo -e "${GREEN}✅ 使用现有 VLESS 脚本。${NC}"
                fi
            else
                echo -e "${YELLOW}📥 下载 VLESS 脚本...${NC}"
            fi
            if [ ! -f "${VLESS_SCRIPT}" ]; then
                if ! download_protocol_script "vless"; then
                    echo -e "${RED}⚠️ 下载协议脚本失败！${NC}"
                    return 1
                fi
            fi
            if ! command -v yq &> /dev/null; then
                echo -e "${RED}⚠️ yq 未安装，请运行 proxym-easy install！${NC}"
                return 1
            fi
            if ! chmod +x "${VLESS_SCRIPT}" 2>/dev/null; then
                echo -e "${RED}⚠️ 无法为 ${VLESS_SCRIPT} 设置执行权限！${NC}"
                return 1
            fi
            echo -e "${YELLOW}🚀 执行 VLESS 配置生成脚本...${NC}"
            "${VLESS_SCRIPT}" 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}⚠️ VLESS 子脚本执行失败！请检查输出或日志。${NC}"
                return 1
            fi
            echo -e "${YELLOW}🔄 配置生成完成，返回主菜单...${NC}"
            sleep 2
            return 0
            ;;
        2)
            return 0
            ;;
        *)
            echo -e "${RED}⚠️ 无效选项${NC}"
            generate_node_config
            ;;
    esac
}

# 函数: 编辑配置（使用 vim）
edit_config() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo -e "${RED}⚠️ 未找到配置文件 ${CONFIG_FILE}，请先生成配置！${NC}"
        generate_node_config
        return 1
    fi
    if ! command -v vim &> /dev/null; then
        echo -e "${RED}⚠️ vim 未安装，请手动安装 vim！${NC}"
        return 1
    fi
    vim "${CONFIG_FILE}"
    echo -e "${GREEN}✅ 配置文件 ${CONFIG_FILE} 编辑完成。请测试配置有效性。${NC}"
    return 0
}

# 函数: 启动 mihomo
start_mihomo() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        return 1
    fi
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 不存在，请先生成配置！${NC}"
        generate_node_config
        return 1
    fi
    if ! systemctl start mihomo; then
        echo -e "${RED}⚠️ 启动失败！请检查日志: journalctl -u mihomo${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ mihomo 启动成功！${NC}"
    return 0
}

# 函数: 重启 mihomo
restart_mihomo() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        return 1
    fi
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 不存在，请先生成配置！${NC}"
        generate_node_config
        return 1
    fi
    if ! systemctl restart mihomo; then
        echo -e "${RED}⚠️ 重启失败！请检查日志: journalctl -u mihomo${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ mihomo 重启成功！${NC}"
    return 0
}

# 函数: 停止 mihomo
stop_mihomo() {
    if ! systemctl stop mihomo; then
        echo -e "${RED}⚠️ 停止失败！请检查日志: journalctl -u mihomo${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ mihomo 停止成功！${NC}"
    return 0
}

# 函数: 查看 mihomo 状态
status_mihomo() {
    if systemctl is-active --quiet mihomo; then
        echo -e "${GREEN}✅ mihomo 运行中:${NC}"
        systemctl status mihomo --no-pager
    else
        echo -e "${RED}⚠️ mihomo 未运行${NC}"
    fi
    return 0
}

# 函数: 查看 mihomo 日志
logs_mihomo() {
    echo -e "${YELLOW}📜 查看 mihomo 日志（按 Ctrl+C 退出）...${NC}"
    journalctl -u mihomo -f
    return 0
}

# 函数: 测试配置
test_config() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        return 1
    fi
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 不存在，请先生成配置！${NC}"
        return 1
    fi
    if "${INSTALL_DIR}/mihomo" -t -d "${CONFIG_DIR}" 2>/dev/null; then
        echo -e "${GREEN}✅ 配置文件测试通过！${NC}"
    else
        echo -e "${RED}⚠️ 配置文件测试失败，请检查 ${CONFIG_FILE}！${NC}"
        return 1
    fi
    return 0
}

# 函数: 更新主脚本
update_scripts() {
    echo -e "${YELLOW}🚀 更新主脚本（proxym-easy）...${NC}"
    if [ -f "${INSTALL_DIR}/proxym-easy" ]; then
        cp "${INSTALL_DIR}/proxym-easy" "${INSTALL_DIR}/proxym-easy.bak" 2>/dev/null
        if ! curl -s --max-time 5 -o "${INSTALL_DIR}/proxym-easy.tmp" "$MAIN_URL"; then
            echo -e "${RED}⚠️ 下载 proxym-easy 失败！${NC}"
            rm -f "${INSTALL_DIR}/proxym-easy.tmp" 2>/dev/null
            mv "${INSTALL_DIR}/proxym-easy.bak" "${INSTALL_DIR}/proxym-easy" 2>/dev/null
            return 1
        fi
        if bash -n "${INSTALL_DIR}/proxym-easy.tmp" 2>/dev/null; then
            mv "${INSTALL_DIR}/proxym-easy.tmp" "${INSTALL_DIR}/proxym-easy" 2>/dev/null
            chmod +x "${INSTALL_DIR}/proxym-easy" 2>/dev/null
            rm -f "${INSTALL_DIR}/proxym-easy.bak" 2>/dev/null
            echo -e "${GREEN}✅ proxym-easy 更新成功！${NC}"
        else
            echo -e "${RED}⚠️ proxym-easy 语法检查失败，回滚备份。${NC}"
            rm -f "${INSTALL_DIR}/proxym-easy.tmp" 2>/dev/null
            mv "${INSTALL_DIR}/proxym-easy.bak" "${INSTALL_DIR}/proxym-easy" 2>/dev/null
            return 1
        fi
    else
        echo -e "${RED}⚠️ proxym-easy 不存在，无法更新！${NC}"
        return 1
    fi
    return 0
}

# 函数: 管理面板
show_menu() {
    echo -e "${YELLOW}🌟 Proxym-Easy 管理面板 🌟${NC}"
    echo "[1] 启动 mihomo"
    echo "[2] 停止 mihomo"
    echo "[3] 重启 mihomo"
    echo "[4] 查看状态"
    echo "[5] 查看日志"
    echo "[6] 测试配置"
    echo "[7] 生成节点配置"
    echo "[8] 编辑配置文件（使用 vim）"
    echo "[9] 安装 mihomo"
    echo "[10] 更新 mihomo"
    echo "[11] 卸载选项（脚本/mihomo/全部）"
    echo "[12] 更新主脚本（proxym-easy）"
    echo "[13] 退出"
    echo -n "请选择选项 [1-13]："
    read -r choice
    case $choice in
        1)
            start_mihomo
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 启动成功！${NC}"
            else
                echo -e "${RED}⚠️ 启动失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        2)
            stop_mihomo
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 停止成功！${NC}"
            else
                echo -e "${RED}⚠️ 停止失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        3)
            restart_mihomo
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 重启成功！${NC}"
            else
                echo -e "${RED}⚠️ 重启失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        4)
            status_mihomo
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        5)
            logs_mihomo
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        6)
            test_config
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 测试成功！${NC}"
            else
                echo -e "${RED}⚠️ 测试失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        7)
            generate_node_config
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 生成节点配置成功！${NC}"
            else
                echo -e "${RED}⚠️ 生成节点配置失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        8)
            edit_config
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 编辑成功！${NC}"
            else
                echo -e "${RED}⚠️ 编辑失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        9)
            install_mihomo
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 安装成功！${NC}"
            else
                echo -e "${RED}⚠️ 安装失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        10)
            update_mihomo
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 更新 mihomo 成功！${NC}"
            else
                echo -e "${RED}⚠️ 更新 mihomo 失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        11)
            uninstall
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 卸载操作成功！${NC}"
            else
                echo -e "${RED}⚠️ 卸载操作失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        12)
            update_scripts
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 更新脚本成功！${NC}"
            else
                echo -e "${RED}⚠️ 更新脚本失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        13)
            echo -e "${GREEN}✅ 已退出，下次使用请输入 proxym-easy${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}⚠️ 无效选项${NC}"
            sleep 1
            show_menu
            ;;
    esac
}

# 主逻辑
case "$1" in
    start)
        start_mihomo
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 启动成功！${NC}"
        else
            echo -e "${RED}⚠️ 启动失败！${NC}"
        fi
        exit 0
        ;;
    stop)
        stop_mihomo
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 停止成功！${NC}"
        else
            echo -e "${RED}⚠️ 停止失败！${NC}"
        fi
        exit 0
        ;;
    restart)
        restart_mihomo
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 重启成功！${NC}"
        else
            echo -e "${RED}⚠️ 重启失败！${NC}"
        fi
        exit 0
        ;;
    status)
        status_mihomo
        exit 0
        ;;
    log)
        logs_mihomo
        exit 0
        ;;
    test)
        test_config
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 测试成功！${NC}"
        else
            echo -e "${RED}⚠️ 测试失败！${NC}"
        fi
        exit 0
        ;;
    install)
        install_mihomo
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 安装成功！${NC}"
        else
            echo -e "${RED}⚠️ 安装失败！${NC}"
        fi
        exit 0
        ;;
    update)
        update_mihomo
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 更新 mihomo 成功！${NC}"
        else
            echo -e "${RED}⚠️ 更新 mihomo 失败！${NC}"
        fi
        exit 0
        ;;
    uninstall)
        uninstall
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 卸载操作成功！${NC}"
        else
            echo -e "${RED}⚠️ 卸载操作失败！${NC}"
        fi
        exit 0
        ;;
    update-scripts)
        update_scripts
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 更新脚本成功！${NC}"
        else
            echo -e "${RED}⚠️ 更新脚本失败！${NC}"
        fi
        exit 0
        ;;
    generate-config)
        generate_node_config
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 生成节点配置成功！${NC}"
        else
            echo -e "${RED}⚠️ 生成节点配置失败！${NC}"
        fi
        exit 0
        ;;
    delete)
        uninstall
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 卸载操作成功！${NC}"
        else
            echo -e "${RED}⚠️ 卸载操作失败！${NC}"
        fi
        exit 0
        ;;
    menu)
        show_menu
        ;;
    *)
        if ! check_mihomo; then
            echo -e "${YELLOW}🚀 mihomo 未安装，正在安装...${NC}"
            install_mihomo
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 安装成功！${NC}"
            else
                echo -e "${RED}⚠️ 安装失败！${NC}"
            fi
        fi
        show_menu
        ;;
esac