#!/bin/bash

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Color

# 检查系统架构和 root 权限
if [[ "$(uname -m)" != "x86_64" ]]; then
    echo -e "${RED}⚠️ 错误: 此脚本仅支持 AMD64 (x86_64) 架构。${NC}"
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}⚠️ 错误: 请使用 root 权限运行 (sudo)。${NC}"
    exit 1
fi

# 变量定义
VERSION="v1.19.13"
DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${VERSION}/mihomo-linux-amd64-${VERSION}.gz"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/mihomo"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
WORK_DIR="/var/lib/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SCRIPT_PATH="/usr/local/bin/mieru-easy"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/Lanlan13-14/Mieru-Easy/main/mieru.sh"

# 函数: 检查端口是否被占用
check_port() {
    local port="$1"
    if ss -tuln | grep -q ":${port}\b"; then
        return 1
    fi
    return 0
}

# 函数: 检查端口段是否被占用
check_port_range() {
    local start_port="$1"
    local end_port="$2"
    for ((p=start_port; p<=end_port; p++)); do
        if ! check_port "${p}"; then
            return 1
        fi
    done
    return 0
}

# 函数: 推荐可用端口
recommend_port() {
    local recommended_port
    local attempts=0
    while (( attempts < 100 )); do
        recommended_port=$((RANDOM % 20001 + 10000))
        if check_port "${recommended_port}"; then
            echo "${recommended_port}"
            return 0
        fi
        ((attempts++))
    done
    echo -e "${RED}⚠️ 无法找到可用端口，请手动检查！${NC}"
    return 1
}

# 函数: 推荐可用端口段
recommend_port_range() {
    local length="$1"
    local max_start=$((30000 - length + 1))
    local recommended_start
    local attempts=0
    while (( attempts < 100 )); do
        recommended_start=$((RANDOM % (max_start - 10000 + 1) + 10000))
        if check_port_range "${recommended_start}" $((recommended_start + length - 1)); then
            echo "${recommended_start}-$((recommended_start + length - 1))"
            return 0
        fi
        ((attempts++))
    done
    echo -e "${RED}⚠️ 无法找到可用端口段，请手动检查！${NC}"
    return 1
}

# 函数: 安装 mihomo
install_mihomo() {
    echo -e "${YELLOW}🚀 安装 mihomo ${VERSION}...${NC}"

    # 安装依赖
    echo -e "${YELLOW}安装依赖...${NC}"
    if command -v apt-get &> /dev/null; then
        if ! apt-get update -y; then
            echo -e "${RED}⚠️ apt-get update 失败！请检查网络或软件源。${NC}"
            exit 1
        fi
        if ! apt-get install -y wget gzip curl openssl coreutils iproute2 net-tools vim; then
            echo -e "${RED}⚠️ 依赖安装失败！请检查网络或软件源。${NC}"
            exit 1
        fi
    elif command -v yum &> /dev/null; then
        if ! yum update -y; then
            echo -e "${RED}⚠️ yum update 失败！请检查网络或软件源。${NC}"
            exit 1
        fi
        if ! yum install -y wget gzip curl openssl coreutils iproute2 net-tools vim-enhanced; then
            echo -e "${RED}⚠️ 依赖安装失败！请检查网络或软件源。${NC}"
            exit 1
        fi
    elif command -v dnf &> /dev/null; then
        if ! dnf check-update -y; then
            echo -e "${RED}⚠️ dnf check-update 失败！请检查网络或软件源。${NC}"
            exit 1
        fi
        if ! dnf install -y wget gzip curl openssl coreutils iproute2 net-tools vim-enhanced; then
            echo -e "${RED}⚠️ 依赖安装失败！请检查网络或软件源。${NC}"
            exit 1
        fi
    else
        echo -e "${RED}⚠️ 不支持的包管理器。请手动安装 wget、gzip、curl、openssl、coreutils、iproute2、net-tools 和 vim。${NC}"
        exit 1
    fi

    # 创建目录
    if ! mkdir -p "${CONFIG_DIR}" "${WORK_DIR}"; then
        echo -e "${RED}⚠️ 创建目录失败！${NC}"
        exit 1
    fi
    chown -R root:root "${CONFIG_DIR}" "${WORK_DIR}"
    chmod 755 "${CONFIG_DIR}" "${WORK_DIR}"

    # 下载并安装 mihomo
    cd /tmp || exit 1
    if ! wget --retry 2 --max-time 10 -O mihomo.gz "${DOWNLOAD_URL}"; then
        echo -e "${RED}⚠️ 下载失败，请检查网络或版本。${NC}"
        exit 1
    fi
    if ! gzip -d mihomo.gz; then
        echo -e "${RED}⚠️ 解压失败！${NC}"
        exit 1
    fi
    if ! mv mihomo "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 移动文件失败！${NC}"
        exit 1
    fi
    chmod +x "${INSTALL_DIR}/mihomo"
    if ! setcap 'cap_net_bind_service,cap_net_admin=+ep' "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 设置权限失败！${NC}"
        exit 1
    fi

    # 生成默认配置文件（如果不存在）
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        generate_mieru_config
    fi

    # 创建 systemd 服务
    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Mihomo (Clash Meta) Daemon
Documentation=https://wiki.metacubex.one/
After=network.target nss-lookup.target
Wants=nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/mihomo -d ${WORK_DIR} -f ${CONFIG_FILE}
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

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
    if ! systemctl start mihomo; then
        echo -e "${RED}⚠️ 启动 mihomo 失败！请检查日志: journalctl -u mihomo${NC}"
        exit 1
    fi

    if systemctl is-active --quiet mihomo; then
        echo -e "${GREEN}✅ mihomo 安装并启动成功!${NC}"
    else
        echo -e "${RED}⚠️ 安装失败，请检查日志: journalctl -u mihomo${NC}"
        exit 1
    fi
}

# 函数: 更新 mihomo
update_mihomo() {
    echo -e "${YELLOW}🚀 更新 mihomo 到 ${VERSION}...${NC}"
    systemctl stop mihomo || true
    cd /tmp || exit 1
    if ! wget --retry 2 --max-time 10 -O mihomo.gz "${DOWNLOAD_URL}"; then
        echo -e "${RED}⚠️ 下载失败。${NC}"
        exit 1
    fi
    if ! gzip -d mihomo.gz; then
        echo -e "${RED}⚠️ 解压失败！${NC}"
        exit 1
    fi
    if ! mv mihomo "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 移动文件失败！${NC}"
        exit 1
    fi
    chmod +x "${INSTALL_DIR}/mihomo"
    if ! setcap 'cap_net_bind_service,cap_net_admin=+ep' "${INSTALL_DIR}/mihomo"; then
        echo -e "${RED}⚠️ 设置权限失败！${NC}"
        exit 1
    fi
    if ! systemctl start mihomo; then
        echo -e "${RED}⚠️ 启动 mihomo 失败！请检查日志: journalctl -u mihomo${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ mihomo 更新完成!${NC}"
}

# 函数: 卸载 mihomo
uninstall_mihomo() {
    echo -e "${YELLOW}🚀 卸载 mihomo...${NC}"
    systemctl stop mihomo || true
    systemctl disable mihomo || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    rm -rf "${INSTALL_DIR}/mihomo" "${CONFIG_DIR}" "${WORK_DIR}"
    echo -e "${GREEN}✅ mihomo 卸载完成!${NC}"
}

# 函数: 启动 mihomo
start_mihomo() {
    if ! systemctl start mihomo; then
        echo -e "${RED}⚠️ 启动失败! 请检查日志: journalctl -u mihomo${NC}"
        journalctl -u mihomo --no-pager
        exit 1
    fi
    echo -e "${GREEN}✅ mihomo 启动成功!${NC}"
}

# 函数: 重启 mihomo
restart_mihomo() {
    if ! systemctl restart mihomo; then
        echo -e "${RED}⚠️ 重启失败! 请检查日志: journalctl -u mihomo${NC}"
        journalctl -u mihomo --no-pager
        exit 1
    fi
    echo -e "${GREEN}✅ mihomo 重启成功!${NC}"
}

# 函数: 停止 mihomo
stop_mihomo() {
    if ! systemctl stop mihomo; then
        echo -e "${RED}⚠️ 停止失败! 请检查日志: journalctl -u mihomo${NC}"
        journalctl -u mihomo --no-pager
        exit 1
    fi
    echo -e "${GREEN}✅ mihomo 停止成功!${NC}"
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
    echo -e "${YELLOW}🚀 查看 mihomo 日志 (按 Ctrl+C 退出)...${NC}"
    journalctl -u mihomo -f
}

# 函数: 获取服务器公共 IP 地址
get_server_ips() {
    ipv4=$(curl --retry 2 --max-time 5 -4 -s ifconfig.me || echo "")
    ipv6=$(curl --retry 2 --max-time 5 -6 -s ifconfig.me || echo "")
    if [[ -z "${ipv4}" && -z "${ipv6}" ]]; then
        echo -e "${YELLOW}⚠️ 无法获取服务器 IP 地址，将仅显示配置内容！${NC}"
    fi
}

# 函数: 查看 Mieru 客户端连接信息
show_connection_info() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}⚠️ 配置文件不存在，请先生成 Mieru 配置！${NC}"
        return
    fi

    # 获取服务器 IP
    get_server_ips

    # 提取所有 mieru-in-* inbound
    mieru_inbounds=$(awk '/- name: mieru-in-/{print $3}' "${CONFIG_FILE}")
    if [[ -z "${mieru_inbounds}" ]]; then
        echo -e "${RED}⚠️ 未找到 Mieru inbound 配置！${NC}"
        return
    fi

    echo -e "${YELLOW}🚀 Mieru 客户端连接信息:${NC}"
    for inbound_name in ${mieru_inbounds}; do
        # 提取参数 for this inbound
        block_start=$(awk "/- name: ${inbound_name}/{print NR}" "${CONFIG_FILE}" | head -n1)
        block_end=$(awk 'NR > '"${block_start}"' && /^- name:/{print NR-1; exit} END{print NR}' "${CONFIG_FILE}")
        block=$(sed -n "${block_start},${block_end}p" "${CONFIG_FILE}")

        username=$(echo "${block}" | grep "name:" | awk '{print $2}' | head -n1)
        password=$(echo "${block}" | grep "pass:" | awk '{print $2}' | head -n1)
        multiplexing=$(echo "${block}" | grep "multiplexing:" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
        port=$(echo "${block}" | grep "port:" | awk '{print $2}')
        port_range=$(echo "${block}" | grep "port-range:" | awk '{print $2}')

        # 只包括存在的 port 或 port-range
        port_str="port: ${port}"
        port_range_str=""
        if [[ -n "${port_range}" ]]; then
            port_range_str="port-range: ${port_range}"
        fi

        # 打印 for this inbound
        echo -e "${GREEN}✅ 配置 for ${inbound_name}:${NC}"
        if [[ -n "${ipv4}" ]]; then
            echo -e "${GREEN}IPv4:${NC}"
            cat << EOF
proxies:
  - name: ${inbound_name}
    type: mieru
    server: ${ipv4}
    ${port_str}
    ${port_range_str}
    transport: TCP
    username: ${username}
    password: ${password}
    multiplexing: MULTIPLEXING_${multiplexing}
EOF
        fi
        if [[ -n "${ipv6}" ]]; then
            echo -e "${GREEN}IPv6:${NC}"
            cat << EOF
proxies:
  - name: ${inbound_name}
    type: mieru
    server: ${ipv6}
    ${port_str}
    ${port_range_str}
    transport: TCP
    username: ${username}
    password: ${password}
    multiplexing: MULTIPLEXING_${multiplexing}
EOF
        fi
        if [[ -z "${ipv4}" && -z "${ipv6}" ]]; then
            echo -e "${GREEN}无 IP 地址:${NC}"
            cat << EOF
proxies:
  - name: ${inbound_name}
    type: mieru
    server: <YOUR_SERVER_IP>
    ${port_str}
    ${port_range_str}
    transport: TCP
    username: ${username}
    password: ${password}
    multiplexing: MULTIPLEXING_${multiplexing}
EOF
        fi
    done
}

# 函数: 生成 Mieru 服务端配置（交互式自定义，支持多个）
generate_mieru_config() {
    echo -e "${YELLOW}🚀 生成 Mieru 服务端配置文件...${NC}"

    # 如果文件不存在，创建基本结构
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        cat > "${CONFIG_FILE}" << EOF
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

listeners:
proxies:
  - name: direct
    type: direct

proxy-groups:
  - name: default
    type: select
    proxies:
      - direct

rules:
  - MATCH,default
EOF
    fi

    # 查找当前 mieru-in 数量
    current_count=$(grep -c "name: mieru-in-" "${CONFIG_FILE}" || echo 0)
    inbound_num=$((current_count + 1))

    while true; do
        inbound_name="mieru-in-${inbound_num}"

        # listen: 支持自定义，默认 ::
        read -r -p "输入监听地址 (默认 ::): " listen
        listen="${listen:-::}"
        echo -e "${YELLOW}监听地址: ${listen}${NC}"

        # username: 支持自动生成或手动输入
        read -r -p "输入 username (回车自动生成): " username
        if [[ -z "${username}" ]]; then
            username="user_$(head -c 8 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | cut -c1-8)"
            echo -e "${YELLOW}自动生成 username: ${username}${NC}"
        fi

        # password: 支持自动生成或手动输入
        read -r -p "输入 password (回车自动生成): " password
        if [[ -z "${password}" ]]; then
            password=$(openssl rand -base64 12)
            echo -e "${YELLOW}自动生成 password: ${password}${NC}"
        fi

        # multiplexing: 选择，默认 low
        echo "选择 multiplexing 级别 (默认 [2] low):"
        echo "[1] off (关闭多路复用)"
        echo "[2] low"
        echo "[3] middle"
        echo "[4] high"
        read -r -p "输入选择 [1-4]: " mux_choice
        case "${mux_choice}" in
            1) multiplexing="off" ;;
            3) multiplexing="middle" ;;
            4) multiplexing="high" ;;
            *) multiplexing="low" ;;
        esac
        echo -e "${YELLOW}选择的 multiplexing: ${multiplexing}${NC}"

        # port 或 port-range: 选择使用哪一个，支持手动输入或自动生成
        read -r -p "是否使用 port-range [y/n，默认 n 只用 port]: " use_range
        if [[ "${use_range}" == "y" || "${use_range}" == "Y" ]]; then
            while true; do
                read -r -p "输入 port-range (格式: start-end，回车自动生成 10000-30000 内范围): " port_range
                if [[ -z "${port_range}" ]]; then
                    start_port=$((RANDOM % 20001 + 10000))
                    end_port=$((start_port + 9))  # 随机 10 个端口范围
                    port_range="${start_port}-${end_port}"
                    length=10
                else
                    # 检查 port-range 格式
                    if [[ "${port_range}" =~ ^[0-9]+-[0-9]+$ ]]; then
                        start_port=$(echo "${port_range}" | cut -d'-' -f1)
                        end_port=$(echo "${port_range}" | cut -d'-' -f2)
                        length=$((end_port - start_port + 1))
                        if (( start_port >= 1 && end_port <= 65535 && start_port < end_port )); then
                            : # 格式有效，继续检查
                        else
                            echo -e "${RED}⚠️ 无效的端口段（范围 1-65535，起始端口需小于结束端口）！${NC}"
                            continue
                        fi
                    else
                        echo -e "${RED}⚠️ 无效的 port-range 格式，需为 start-end（如 2090-2099）！${NC}"
                        continue
                    fi
                fi
                # 检查端口段是否被占用
                if check_port_range "${start_port}" "${end_port}"; then
                    echo -e "${YELLOW}端口段可用: ${port_range}${NC}"
                    break
                else
                    echo -e "${RED}⚠️ 端口段 ${port_range} 不可用，请重新输入！${NC}"
                    recommended_range=$(recommend_port_range "${length}")
                    if [[ -n "${recommended_range}" ]]; then
                        echo -e "${YELLOW}推荐可用端口段: ${recommended_range}${NC}"
                    fi
                fi
            done
            port_config="port: ${start_port}"
            port_range_config="    port-range: ${port_range}"
        else
            while true; do
                read -r -p "输入 port (回车自动生成 10000-30000 内端口): " port
                if [[ -z "${port}" ]]; then
                    port=$((RANDOM % 20001 + 10000))
                elif ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                    echo -e "${RED}⚠️ 无效的端口号（范围 1-65535）！${NC}"
                    continue
                fi
                # 检查端口是否被占用
                if check_port "${port}"; then
                    echo -e "${YELLOW}端口可用: ${port}${NC}"
                    break
                else
                    echo -e "${RED}⚠️ 端口 ${port} 不可用，请重新输入！${NC}"
                    recommended_port=$(recommend_port)
                    if [[ -n "${recommended_port}" ]]; then
                        echo -e "${YELLOW}推荐可用端口: ${recommended_port}${NC}"
                    fi
                fi
            done
            port_config="port: ${port}"
            port_range_config=""
        fi

        # 追加到 listeners 部分，使用 awk 确保 YAML 格式
        new_inbound=$(cat << EOF
  - name: ${inbound_name}
    type: mieru
    ${port_config}
${port_range_config}
    listen: ${listen}
    users:
      - name: ${username}
        pass: ${password}
    multiplexing: ${multiplexing}
EOF
)
        if ! awk -v new_inbound="${new_inbound}" '/^listeners:/{print; print new_inbound; next}1' "${CONFIG_FILE}" > /tmp/config.yaml; then
            echo -e "${RED}⚠️ 写入配置文件失败！${NC}"
            exit 1
        fi
        if ! mv /tmp/config.yaml "${CONFIG_FILE}"; then
            echo -e "${RED}⚠️ 移动配置文件失败！${NC}"
            exit 1
        fi

        echo -e "${GREEN}✅ 添加了 ${inbound_name}${NC}"
        echo -e "${YELLOW}自定义值: listen=${listen}, username=${username}, password=${password}, multiplexing=${multiplexing}${NC}"
        if [[ -n "${port}" && -z "${port_range}" ]]; then
            echo -e "${YELLOW}port=${port}${NC}"
        else
            echo -e "${YELLOW}port-range=${port_range}${NC}"
        fi

        # 询问是否添加更多
        read -r -p "是否添加另一个 Mieru inbound [y/n，默认 n]: " add_more
        if [[ "${add_more}" != "y" && "${add_more}" != "Y" ]]; then
            break
        fi
        inbound_num=$((inbound_num + 1))
    done

    chown root:root "${CONFIG_FILE}"
    chmod 644 "${CONFIG_FILE}"
    echo -e "${GREEN}✅ 配置文件生成/更新完成: ${CONFIG_FILE}${NC}"

    # 重启服务以应用新配置
    if systemctl is-active --quiet mihomo; then
        restart_mihomo
    fi
}

# 函数: 删除配置
delete_config() {
    echo -e "${YELLOW}🚀 删除配置文件...${NC}"
    if [[ -f "${CONFIG_FILE}" ]]; then
        if ! rm -f "${CONFIG_FILE}"; then
            echo -e "${RED}⚠️ 删除配置文件失败！${NC}"
            exit 1
        fi
        echo -e "${GREEN}✅ 配置文件 ${CONFIG_FILE} 已删除！${NC}"
        if systemctl is-active --quiet mihomo; then
            restart_mihomo
        fi
    else
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 不存在！${NC}"
    fi
}

# 函数: 修改配置
modify_config() {
    echo -e "${YELLOW}🚀 修改配置文件 ${CONFIG_FILE}...${NC}"
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${RED}⚠️ 配置文件 ${CONFIG_FILE} 不存在，请先生成！${NC}"
        return
    fi

    # 检查并安装 vim
    if ! command -v vim &> /dev/null; then
        echo -e "${YELLOW}安装 vim...${NC}"
        if command -v apt-get &> /dev/null; then
            if ! apt-get update -y; then
                echo -e "${RED}⚠️ apt-get update 失败，请手动安装 vim！${NC}"
                return
            fi
            if ! apt-get install -y vim; then
                echo -e "${RED}⚠️ 无法安装 vim，请手动安装！${NC}"
                return
            fi
        elif command -v yum &> /dev/null; then
            if ! yum install -y vim-enhanced; then
                echo -e "${RED}⚠️ 无法安装 vim-enhanced，请手动安装！${NC}"
                return
            fi
        elif command -v dnf &> /dev/null; then
            if ! dnf install -y vim-enhanced; then
                echo -e "${RED}⚠️ 无法安装 vim-enhanced，请手动安装！${NC}"
                return
            fi
        else
            echo -e "${RED}⚠️ 不支持的包管理器，请手动安装 vim！${NC}"
            return
        fi
    fi

    vim "${CONFIG_FILE}"
    if systemctl is-active --quiet mihomo; then
        restart_mihomo
    fi
}

# 函数: 更新脚本
update_script() {
    echo -e "${YELLOW}🚀 更新脚本...${NC}"
    # 备份当前脚本
    if [[ -f "${SCRIPT_PATH}" ]]; then
        if ! cp "${SCRIPT_PATH}" /tmp/mieru-easy.bak; then
            echo -e "${RED}⚠️ 备份失败！${NC}"
            exit 1
        fi
        echo -e "${YELLOW}已备份当前脚本到 /tmp/mieru-easy.bak${NC}"
    else
        echo -e "${RED}⚠️ 脚本 ${SCRIPT_PATH} 不存在！${NC}"
        exit 1
    fi

    # 下载新脚本
    if ! curl --retry 2 --max-time 10 -L "${REMOTE_SCRIPT_URL}" -o /tmp/mieru-easy; then
        echo -e "${RED}⚠️ 下载新脚本失败！${NC}"
        exit 1
    fi

    # 语法检查
    if bash -n /tmp/mieru-easy; then
        echo -e "${GREEN}✅ 新脚本语法检查通过${NC}"
        if ! mv /tmp/mieru-easy "${SCRIPT_PATH}"; then
            echo -e "${RED}⚠️ 移动新脚本失败，恢复备份！${NC}"
            mv /tmp/mieru-easy.bak "${SCRIPT_PATH}"
            exit 1
        fi
        chmod +x "${SCRIPT_PATH}"
        rm -f /tmp/mieru-easy.bak
        echo -e "${GREEN}✅ 脚本更新完成！请重新运行: sudo mieru-easy${NC}"
    else
        echo -e "${RED}⚠️ 新脚本语法检查失败，自动回滚！${NC}"
        if ! mv /tmp/mieru-easy.bak "${SCRIPT_PATH}"; then
            echo -e "${RED}⚠️ 恢复备份失败！${NC}"
            exit 1
        fi
        chmod +x "${SCRIPT_PATH}"
        exit 1
    fi
}

# 函数: 删除本脚本
delete_script() {
    echo -e "${YELLOW}🚀 删除本脚本...${NC}"
    if [[ -f "${SCRIPT_PATH}" ]]; then
        if ! rm -f "${SCRIPT_PATH}"; then
            echo -e "${RED}⚠️ 删除脚本失败！${NC}"
            exit 1
        fi
        echo -e "${GREEN}✅ 脚本已删除！${NC}"
    else
        echo -e "${RED}⚠️ 脚本 ${SCRIPT_PATH} 不存在！${NC}"
    fi
}

# 函数: 删除本脚本及 mihomo 和配置文件
delete_all() {
    echo -e "${YELLOW}🚀 删除本脚本、mihomo 及配置文件...${NC}"
    systemctl stop mihomo || true
    systemctl disable mihomo || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    rm -rf "${INSTALL_DIR}/mihomo" "${CONFIG_DIR}" "${WORK_DIR}" "${SCRIPT_PATH}"
    echo -e "${GREEN}✅ 脚本、mihomo 及配置文件已删除！${NC}"
}

# 主菜单
while true; do
    echo -e "${GREEN}=== 🚀 Mieru-Easy 管理菜单 🚀 ===${NC}"
    echo "[1] 安装 mihomo"
    echo "[2] 更新 mihomo"
    echo "[3] 卸载 mihomo"
    echo "[4] 启动 mihomo"
    echo "[5] 重启 mihomo"
    echo "[6] 停止 mihomo"
    echo "[7] 生成 Mieru 服务端配置 (自定义)"
    echo "[8] 查看 Mieru 客户端连接信息"
    echo "[9] 查看 mihomo 状态"
    echo "[10] 查看 mihomo 日志"
    echo "[11] 更新本脚本"
    echo "[12] 删除本脚本"
    echo "[13] 删除本脚本及 mihomo 和配置文件"
    echo "[14] 删除配置"
    echo "[15] 修改配置"
    echo "[16] 退出"
    read -r -p "输入选择 [1-16]: " choice

    case "${choice}" in
        1) install_mihomo ;;
        2) update_mihomo ;;
        3) uninstall_mihomo ;;
        4) start_mihomo ;;
        5) restart_mihomo ;;
        6) stop_mihomo ;;
        7) generate_mieru_config ;;
        8) show_connection_info ;;
        9) status_mihomo ;;
        10) logs_mihomo ;;
        11) update_script ;;
        12) delete_script ;;
        13) delete_all ;;
        14) delete_config ;;
        15) modify_config ;;
        16) echo -e "${GREEN}✅ 退出脚本。${NC}"; exit 0 ;;
        *) echo -e "${RED}⚠️ 无效选择，请重试。${NC}" ;;
    esac
done