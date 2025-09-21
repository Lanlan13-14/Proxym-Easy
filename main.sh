#!/bin/bash

# 🌟 Proxym-Easy 管理面板 🌟
# 功能：
# - 管理 mihomo 服务的启动、停止、重启、状态查看、日志查看、配置测试。
# - 支持生成 VLESS Encryption 配置（调用 vless_encryption.sh）。
# - 支持安装、更新、卸载 mihomo。
# - 支持更新主脚本。
# 使用方法：proxym-easy
# 依赖：curl, jq, yq, ss, tar, systemctl, mihomo。

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 默认值
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SCRIPT_DIR="/usr/local/bin/script"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
MIHOMO_BIN="${INSTALL_DIR}/mihomo"
VLESS_SCRIPT="${SCRIPT_DIR}/vless_encryption.sh"
GITHUB_RAW_URL="https://raw.githubusercontent.com/your-repo/proxym-easy/main"

# 函数: 检查 mihomo 是否安装
check_mihomo() {
    if [[ -f "${MIHOMO_BIN}" ]]; then
        return 0
    fi
    return 1
}

# 函数: 安装 mihomo
install_mihomo() {
    echo -e "${YELLOW}🌟 安装 mihomo...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) MIHOMO_ARCH="amd64" ;;
        aarch64) MIHOMO_ARCH="arm64" ;;
        *) echo -e "${RED}⚠️ 不支持的架构：${ARCH}${NC}"; return 1 ;;
    esac

    LATEST_URL=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | jq -r '.assets[] | select(.name | contains("mihomo-linux-'${MIHOMO_ARCH}'")) | .browser_download_url')
    if [ -z "$LATEST_URL" ]; then
        echo -e "${RED}⚠️ 无法获取 mihomo 下载链接！${NC}"
        return 1
    fi

    curl -L -o /tmp/mihomo.gz "${LATEST_URL}"
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 下载 mihomo 失败！${NC}"
        return 1
    fi

    gunzip -c /tmp/mihomo.gz > "${MIHOMO_BIN}"
    chmod +x "${MIHOMO_BIN}"
    rm -f /tmp/mihomo.gz

    mkdir -p "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"

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
ExecStart=${MIHOMO_BIN} -d ${CONFIG_DIR}
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mihomo
    echo -e "${GREEN}✅ mihomo 安装成功！${NC}"
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
        return 1
    fi
    # 测试配置
    if ! "${MIHOMO_BIN}" -t -d "${CONFIG_DIR}" > /dev/null 2>&1; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 无效，请检查！${NC}"
        return 1
    fi
    if ! systemctl start mihomo; then
        echo -e "${RED}⚠️ 启动失败！请检查日志: journalctl -u mihomo -f${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ mihomo 启动成功！${NC}"
    # 检查端口监听
    sleep 2
    PORT=$(yq eval '.listeners[].port' "${CONFIG_FILE}" | head -n 1)
    if [ -n "$PORT" ] && ! ss -tuln | grep -q ":${PORT}"; then
        echo -e "${YELLOW}⚠️ 警告：端口 ${PORT} 未监听，请检查配置和防火墙！${NC}"
        echo -e "${YELLOW}🔍 调试：查看 mihomo 日志：${NC}"
        journalctl -u mihomo -n 10 --no-pager
    else
        echo -e "${GREEN}✅ 端口 ${PORT} 监听正常！${NC}"
    fi
    return 0
}

# 函数: 停止 mihomo
stop_mihomo() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        return 1
    fi
    if systemctl stop mihomo; then
        echo -e "${GREEN}✅ mihomo 停止成功！${NC}"
        return 0
    else
        echo -e "${RED}⚠️ 停止失败！请检查日志: journalctl -u mihomo${NC}"
        return 1
    fi
}

# 函数: 重启 mihomo
restart_mihomo() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        return 1
    fi
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 不存在，请先生成配置！${NC}"
        return 1
    fi
    if ! "${MIHOMO_BIN}" -t -d "${CONFIG_DIR}" > /dev/null 2>&1; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 无效，请检查！${NC}"
        return 1
    fi
    if ! systemctl restart mihomo; then
        echo -e "${RED}⚠️ 重启失败！请检查日志: journalctl -u mihomo -f${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ mihomo 重启成功！${NC}"
    # 检查端口监听
    sleep 2
    PORT=$(yq eval '.listeners[].port' "${CONFIG_FILE}" | head -n 1)
    if [ -n "$PORT" ] && ! ss -tuln | grep -q ":${PORT}"; then
        echo -e "${YELLOW}⚠️ 警告：端口 ${PORT} 未监听，请检查配置和防火墙！${NC}"
        echo -e "${YELLOW}🔍 调试：查看 mihomo 日志：${NC}"
        journalctl -u mihomo -n 10 --no-pager
    else
        echo -e "${GREEN}✅ 端口 ${PORT} 监听正常！${NC}"
    fi
    return 0
}

# 函数: 查看状态
view_status() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        return 1
    fi
    if systemctl is-active mihomo >/dev/null; then
        echo -e "${GREEN}✅ mihomo 运行中:${NC}"
        systemctl status mihomo --no-pager -l
        # 检查端口监听
        PORT=$(yq eval '.listeners[].port' "${CONFIG_FILE}" | head -n 1)
        if [ -n "$PORT" ] && ! ss -tuln | grep -q ":${PORT}"; then
            echo -e "${YELLOW}⚠️ 警告：端口 ${PORT} 未监听，请检查配置和防火墙！${NC}"
            echo -e "${YELLOW}🔍 调试：查看 mihomo 日志：${NC}"
            journalctl -u mihomo -n 10 --no-pager
        else
            echo -e "${GREEN}✅ 端口 ${PORT} 监听正常！${NC}"
        fi
    else
        echo -e "${RED}⚠️ mihomo 未运行${NC}"
    fi
    return 0
}

# 函数: 查看日志
view_logs() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        return 1
    fi
    echo -e "${YELLOW}📜 查看 mihomo 日志（按 Ctrl+C 退出）：${NC}"
    journalctl -u mihomo -f
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
    echo -e "${YELLOW}🔍 测试配置文件 ${CONFIG_FILE}...${NC}"
    if "${MIHOMO_BIN}" -t -d "${CONFIG_DIR}" 2>&1; then
        echo -e "${GREEN}✅ 配置文件有效！${NC}"
    else
        echo -e "${RED}⚠️ 配置文件无效，请检查！${NC}"
        return 1
    fi
    return 0
}

# 函数: 生成节点配置
generate_node_config() {
    if [[ ! -f "${VLESS_SCRIPT}" ]]; then
        echo -e "${RED}⚠️ VLESS 脚本 ${VLESS_SCRIPT} 不存在，请检查安装！${NC}"
        return 1
    fi
    bash "${VLESS_SCRIPT}"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 生成节点配置成功！${NC}"
    else
        echo -e "${RED}⚠️ 生成节点配置失败！${NC}"
    fi
    return 0
}

# 函数: 编辑配置文件
edit_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 不存在，请先生成配置！${NC}"
        return 1
    fi
    vim "${CONFIG_FILE}"
    echo -e "${GREEN}✅ 配置文件编辑完成！${NC}"
    return 0
}

# 函数: 更新 mihomo
update_mihomo() {
    if ! check_mihomo; then
        echo -e "${RED}⚠️ mihomo 未安装，请运行 proxym-easy install！${NC}"
        return 1
    fi
    echo -e "${YELLOW}🌟 更新 mihomo...${NC}"
    stop_mihomo
    install_mihomo
    if [ $? -eq 0 ]; then
        start_mihomo
        echo -e "${GREEN}✅ mihomo 更新成功！${NC}"
    else
        echo -e "${RED}⚠️ mihomo 更新失败！${NC}"
    fi
    return 0
}

# 函数: 卸载选项
uninstall_options() {
    echo -e "${YELLOW}🌟 卸载选项 🌟${NC}"
    echo "[1] 仅卸载脚本"
    echo "[2] 仅卸载 mihomo"
    echo "[3] 卸载全部（脚本和 mihomo）"
    echo "[4] 返回主菜单"
    echo -n "请选择选项 [1-4]："
    read -r choice
    case $choice in
        1)
            rm -rf "${SCRIPT_DIR}" /usr/local/bin/proxym-easy
            echo -e "${GREEN}✅ 脚本已卸载！${NC}"
            exit 0
            ;;
        2)
            stop_mihomo
            rm -f "${MIHOMO_BIN}" "${SERVICE_FILE}"
            systemctl daemon-reload
            rm -rf "${CONFIG_DIR}"
            echo -e "${GREEN}✅ mihomo 已卸载！${NC}"
            ;;
        3)
            stop_mihomo
            rm -f "${MIHOMO_BIN}" "${SERVICE_FILE}" /usr/local/bin/proxym-easy
            rm -rf "${SCRIPT_DIR}" "${CONFIG_DIR}"
            systemctl daemon-reload
            echo -e "${GREEN}✅ 全部已卸载！${NC}"
            exit 0
            ;;
        4)
            echo -e "${YELLOW}🔙 返回主菜单...${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}⚠️ 无效选项${NC}"
            uninstall_options
            ;;
    esac
}

# 函数: 更新主脚本
update_main_script() {
    echo -e "${YELLOW}🌟 更新主脚本（proxym-easy）...${NC}"
    curl -s -o /tmp/proxym-easy "${GITHUB_RAW_URL}/proxym-easy"
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 下载主脚本失败！${NC}"
        return 1
    fi
    mv /tmp/proxym-easy /usr/local/bin/proxym-easy
    chmod +x /usr/local/bin/proxym-easy
    echo -e "${GREEN}✅ 主脚本更新成功！${NC}"
    return 0
}

# 主菜单
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
            view_status
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        5)
            view_logs
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        6)
            test_config
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        7)
            generate_node_config
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        8)
            edit_config
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
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        11)
            uninstall_options
            echo -e "${YELLOW}🔄 返回主菜单...${NC}"
            sleep 2
            show_menu
            ;;
        12)
            update_main_script
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 更新成功！${NC}"
            else
                echo -e "${RED}⚠️ 更新失败！${NC}"
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
show_menu