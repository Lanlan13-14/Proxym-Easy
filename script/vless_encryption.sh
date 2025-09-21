#!/bin/bash

# 🚀 独立脚本用于生成 mihomo 的 VLESS Encryption 配置（仅包含 nameserver 的 DNS 配置）。
# 功能：
# - 生成不启用 TLS 的 VLESS Encryption 配置，写入 /etc/mihomo/config.yaml，打印客户端 proxies 单行 YAML。
# - 支持传输层选择：[1] TCP，[2] Websocket，[3] gRPC（默认 gRPC）。
# - 支持 VLESS Encryption 配置选择：原生外观/只 XOR 公钥/全随机数（默认 random），1-RTT/600s（默认 600s），支持多密钥串联。
# - 支持单个端口或端口段（格式：200,302 或 200,204,401-429,501-503），端口段未输入时随机从 10000-20000 选择 10 个连续端口。
# - 子菜单：[1] 生成配置，[2] 打印连接信息，[3] 返回主菜单，失败后返回子菜单。
# - 移除 30 秒输入超时，无限等待用户输入。
# 使用方法：/usr/local/bin/script/vless_encryption.sh
# 依赖：yq, ss, curl (for ipinfo), /proc/sys/kernel/random/uuid, mihomo。
# 输出：配置写入 /etc/mihomo/config.yaml，打印 proxies YAML。

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 默认值
MIHOMO_BIN="/usr/local/bin/mihomo"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
DEFAULT_LISTEN="0.0.0.0"
DEFAULT_FLOW="xtls-rprx-vision"
DEFAULT_DNS_NAMESERVER="8.8.8.8,1.1.1.1"
DEFAULT_TRANSPORT="grpc"
DEFAULT_ENCRYPTION="random"
DEFAULT_RTT="600s"

# 函数: 检查端口是否被占用
check_port() {
    local port="$1"
    if ss -tuln | grep -q ":${port}\b"; then
        return 1
    fi
    return 0
}

# 函数: 推荐单个可用端口
recommend_port() {
    local port
    local attempts=0
    while (( attempts < 100 )); do
        port=$((RANDOM % 10001 + 10000)) # 10000-20000
        if check_port "${port}"; then
            echo "${port}"
            return 0
        fi
        ((attempts++))
    done
    echo -e "${RED}⚠️ 无法找到可用端口，请手动检查！${NC}"
    return 1
}

# 函数: 推荐连续端口段
recommend_port_range() {
    local count=10
    local start_port
    local attempts=0
    while (( attempts < 100 )); do
        start_port=$((RANDOM % (20000 - count + 1) + 10000)) # 确保范围够大
        local valid=true
        local ports=()
        for ((i=0; i<count; i++)); do
            local port=$((start_port + i))
            if ! check_port "${port}"; then
                valid=false
                break
            fi
            ports+=("${port}")
        done
        if $valid; then
            echo "${ports[*]}" | tr ' ' ','
            return 0
        fi
        ((attempts++))
    done
    echo -e "${RED}⚠️ 无法找到 $count 个连续可用端口，请手动指定！${NC}"
    return 1
}

# 函数: 解析端口段并验证
parse_ports() {
    local input="$1"
    local port_list=()
    IFS=',' read -r -a port_segments <<< "$input"
    for segment in "${port_segments[@]}"; do
        if [[ "$segment" =~ ^[0-9]+$ ]]; then
            if check_port "$segment"; then
                port_list+=("$segment")
            else
                echo -e "${RED}⚠️ 端口 $segment 已被占用！${NC}"
                return 1
            fi
        elif [[ "$segment" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            if (( start > end )); then
                echo -e "${RED}⚠️ 端口范围 $segment 无效，起始端口必须小于等于结束端口！${NC}"
                return 1
            fi
            for ((port=start; port<=end; port++)); do
                if check_port "$port"; then
                    port_list+=("$port")
                else
                    echo -e "${RED}⚠️ 端口 $port 已被占用！${NC}"
                    return 1
                fi
            done
        else
            echo -e "${RED}⚠️ 端口格式 $segment 无效！示例：200,302 或 200,204,401-429,501-503${NC}"
            return 1
        fi
    done
    echo "${port_list[*]}" | tr ' ' ','
    return 0
}

# 函数: 生成 VLESS Encryption 配置
generate_vless_config() {
    # 检查依赖
    for cmd in "${MIHOMO_BIN}" yq ss curl; do
        if ! command -v "${cmd}" &> /dev/null; then
            echo -e "${RED}⚠️ ${cmd} 未安装，请运行 proxym-easy install！${NC}"
            return 1
        fi
    done

    # 创建配置目录
    mkdir -p "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"

    # 收集配置参数
    echo -e "${YELLOW}🌟 生成 VLESS Encryption 配置（不启用 TLS，包含 DNS nameserver）...${NC}"
    echo "请输入 DNS 服务器地址（逗号分隔，示例：8.8.8.8,1.1.1.1，默认：$DEFAULT_DNS_NAMESERVER，按回车使用默认值）："
    read -r DNS_NAMESERVER
    DNS_NAMESERVER=${DNS_NAMESERVER:-$DEFAULT_DNS_NAMESERVER}

    echo "请输入监听地址（默认：$DEFAULT_LISTEN，按回车使用默认值）："
    read -r LISTEN
    LISTEN=${LISTEN:-$DEFAULT_LISTEN}

    echo "请选择端口类型：[1] 单个端口 [2] 端口段（示例：200,302 或 200,204,401-429,501-503）"
    read -r port_type
    if [[ "$port_type" == "1" ]]; then
        echo "请输入端口（按回车随机选择可用端口）："
        read -r PORT
        if [ -z "$PORT" ]; then
            PORT=$(recommend_port)
            if [ $? -ne 0 ]; then
                echo -e "${RED}⚠️ 无法推荐可用端口，请手动指定！${NC}"
                return 1
            fi
        fi
        if ! check_port "$PORT"; then
            echo -e "${RED}⚠️ 端口 $PORT 已被占用，请选择其他端口！${NC}"
            return 1
        fi
        PORTS="$PORT"
    else
        echo "请输入端口段（示例：200,302 或 200,204,401-429,501-503，按回车随机选择 10 个连续端口）："
        read -r PORTS
        if [ -z "$PORTS" ]; then
            PORTS=$(recommend_port_range)
            if [ $? -ne 0 ]; then
                echo -e "${RED}⚠️ 无法推荐可用端口段，请手动指定！${NC}"
                return 1
            fi
        fi
        PORTS=$(parse_ports "$PORTS")
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi

    echo "请选择传输层：[1] TCP [2] Websocket [3] gRPC（默认 [1] TCP，按回车使用默认值）："
    read -r transport
    case "$transport" in
        1|"") TRANSPORT="tcp"; WS_PATH=""; GRPC_SERVICE=""; ;;
        2) TRANSPORT="ws"; WS_PATH="/"; GRPC_SERVICE=""; ;;
        3) TRANSPORT="grpc"; WS_PATH=""; GRPC_SERVICE="GunService"; ;;
        *) echo -e "${RED}⚠️ 无效传输层选项，使用默认 gRPC！${NC}"; TRANSPORT="grpc"; WS_PATH=""; GRPC_SERVICE="GunService"; ;;
    esac

    echo "请选择 Encryption 类型：[1] 原生外观 (native) [2] 只 XOR 公钥 (xorpub) [3] 全随机数 (random)（默认 [3] random，按回车使用默认值）："
    read -r encryption
    case "$encryption" in
        1) ENCRYPTION="native"; ;;
        2) ENCRYPTION="xorpub"; ;;
        3|"") ENCRYPTION="random"; ;;
        *) echo -e "${RED}⚠️ 无效 Encryption 类型，使用默认 random！${NC}"; ENCRYPTION="random"; ;;
    esac

    echo "请选择 RTT 模式：[1] 仅 1-RTT (1rtt) [2] 1-RTT 和 600 秒 0-RTT (600s)（默认 [2] 600s，按回车使用默认值）："
    read -r rtt
    case "$rtt" in
        1) RTT="1rtt"; ;;
        2|"") RTT="600s"; ;;
        *) echo -e "${RED}⚠️ 无效 RTT 模式，使用默认 600s！${NC}"; RTT="600s"; ;;
    esac

    echo "请输入 UUID（默认随机生成，按回车使用随机 UUID）："
    read -r UUID
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

    echo "请输入 X25519 私钥（默认随机生成，按回车生成新密钥，多个密钥用逗号分隔）："
    read -r X25519_PRIVATE
    if [ -z "$X25519_PRIVATE" ]; then
        X25519_OUTPUT=$("${MIHOMO_BIN}" generate vless-x25519 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo -e "${RED}⚠️ 生成 X25519 私钥失败！输出：\n${X25519_OUTPUT}${NC}"
            return 1
        fi
        echo -e "${YELLOW}🔍 调试：X25519 输出：\n${X25519_OUTPUT}${NC}"
        X25519_PRIVATE=$(echo "$X25519_OUTPUT" | grep 'PrivateKey:' | sed 's/.*PrivateKey: *//' | tr -d '()')
        if [ -z "$X25519_PRIVATE" ]; then
            echo -e "${RED}⚠️ 解析 X25519 私钥失败！输出：\n${X25519_OUTPUT}${NC}"
            return 1
        fi
    fi

    echo "请输入 ML-KEM-768 种子（默认随机生成，按回车生成新种子，多个种子用逗号分隔）："
    read -r MLKEM_SEED
    if [ -z "$MLKEM_SEED" ]; then
        MLKEM_OUTPUT=$("${MIHOMO_BIN}" generate vless-mlkem768 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo -e "${RED}⚠️ 生成 ML-KEM-768 种子失败！输出：\n${MLKEM_OUTPUT}${NC}"
            return 1
        fi
        echo -e "${YELLOW}🔍 调试：ML-KEM-768 输出：\n${MLKEM_OUTPUT}${NC}"
        MLKEM_SEED=$(echo "$MLKEM_OUTPUT" | grep 'Seed:' | sed 's/.*Seed: *//' | tr -d '()')
        if [ -z "$MLKEM_SEED" ]; then
            echo -e "${RED}⚠️ 解析 ML-KEM-768 种子失败！输出：\n${MLKEM_OUTPUT}${NC}"
            return 1
        fi
    fi

    echo "请输入 Flow（默认：$DEFAULT_FLOW，按回车使用默认值）："
    read -r FLOW
    FLOW=${FLOW:-$DEFAULT_FLOW}

    # 构造 decryption 字符串
    DECRYPTION="mlkem768x25519plus.${ENCRYPTION}.${RTT}"
    IFS=',' read -r -a x25519_keys <<< "$X25519_PRIVATE"
    IFS=',' read -r -a mlkem_seeds <<< "$MLKEM_SEED"
    if [ ${#x25519_keys[@]} -ne ${#mlkem_seeds[@]} ]; then
        echo -e "${RED}⚠️ X25519 私钥和 ML-KEM-768 种子数量不匹配！${NC}"
        return 1
    fi
    for i in "${!x25519_keys[@]}"; do
        DECRYPTION+=".${x25519_keys[i]}.${mlkem_seeds[i]}"
    done

    # 生成 listeners 配置
    LISTENERS=""
    IFS=',' read -r -a port_array <<< "$PORTS"
    for port in "${port_array[@]}"; do
        LISTENER=$(cat <<EOF
  - name: vless-in-$(date +%s)-${port}
    type: vless
    listen: $LISTEN
    port: $port
    decryption: $DECRYPTION
    tls: false
EOF
)
        if [ -n "$WS_PATH" ]; then
            LISTENER+=$'\n    ws-path: "'"$WS_PATH"'"'
        fi
        if [ -n "$GRPC_SERVICE" ]; then
            LISTENER+=$'\n    grpc-service-name: "'"$GRPC_SERVICE"'"'
        fi
        LISTENER+=$'\n    users:\n      - username: user1\n        uuid: '"$UUID"'\n        flow: '"$FLOW"''
        LISTENERS+="$LISTENER"$'\n'
    done

    # 生成完整 YAML 配置
    CONFIG_YAML=$(cat <<EOF
log-level: error

dns:
  nameserver:
$(echo "$DNS_NAMESERVER" | tr ',' '\n' | sed 's/^/    - /')

listeners:
$LISTENERS
EOF
)

    # 检查现有配置文件
    if [ -f "${CONFIG_FILE}" ]; then
        if yq eval '.dns' "${CONFIG_FILE}" > /dev/null 2>&1; then
            echo -e "${YELLOW}📄 检测到现有配置文件 ${CONFIG_FILE}，是否覆盖整个配置文件？(y/n，默认 n): ${NC}"
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                # 覆盖整个配置文件
                echo "$CONFIG_YAML" > "${CONFIG_FILE}"
                chmod 644 "${CONFIG_FILE}"
                echo -e "${GREEN}✅ 配置已覆盖并保存到 ${CONFIG_FILE}${NC}"
            else
                # 检查 listeners 字段是否存在
                if yq eval '.listeners' "${CONFIG_FILE}" > /dev/null 2>&1; then
                    echo -e "${YELLOW}📄 检测到 listeners 字段，是否追加新的 VLESS 配置？(y/n，默认 y): ${NC}"
                    read -r append_response
                    if [[ "$append_response" =~ ^[Yy]$ ]] || [ -z "$append_response" ]; then
                        # 追加 listeners
                        for port in "${port_array[@]}"; do
                            listener_yaml=$(yq eval ".listeners[0] | select(.port == $port)" - <<< "$CONFIG_YAML" 2>/dev/null)
                            if [ $? -ne 0 ]; then
                                echo -e "${RED}⚠️ 解析 listeners 失败！请检查 YAML 格式。${NC}"
                                return 1
                            fi
                            yq eval ".listeners += [yamldecode(\"$listener_yaml\")]" -i "${CONFIG_FILE}" 2>/dev/null
                            if [ $? -ne 0 ]; then
                                echo -e "${RED}⚠️ 追加 Listener 到 ${CONFIG_FILE} 失败！${NC}"
                                return 1
                            fi
                        done
                        echo -e "${GREEN}✅ 新 Listener 已追加到 ${CONFIG_FILE}，保留现有配置${NC}"
                    else
                        echo -e "${YELLOW}🚫 用户取消追加，保留现有配置文件！${NC}"
                        return 1
                    fi
                else
                    # 如果没有 listeners 字段，添加 listeners 字段
                    echo -e "${YELLOW}📄 配置文件中无 listeners 字段，将添加新的 listeners 配置！${NC}"
                    yq eval ".listeners = [yamldecode(\"$(yq eval '.listeners[0]' - <<< "$CONFIG_YAML")\")]" -i "${CONFIG_FILE}" 2>/dev/null
                    if [ $? -ne 0 ]; then
                        echo -e "${RED}⚠️ 添加 listeners 到 ${CONFIG_FILE} 失败！${NC}"
                        return 1
                    fi
                    echo -e "${GREEN}✅ 新 listeners 字段已添加到 ${CONFIG_FILE}${NC}"
                fi
            fi
        else
            # 配置文件存在但无效，覆盖
            echo -e "${YELLOW}📄 配置文件 ${CONFIG_FILE} 存在但无效，将覆盖！${NC}"
            echo "$CONFIG_YAML" > "${CONFIG_FILE}"
            chmod 644 "${CONFIG_FILE}"
            echo -e "${GREEN}✅ 配置已覆盖并保存到 ${CONFIG_FILE}${NC}"
        fi
    else
        # 初次创建配置文件
        echo "$CONFIG_YAML" > "${CONFIG_FILE}"
        chmod 644 "${CONFIG_FILE}"
        echo -e "${GREEN}✅ 新配置文件已创建并保存到 ${CONFIG_FILE}${NC}"
    fi

    # 获取服务器 IP 和国家
    echo -e "\n${YELLOW}🌐 获取服务器 IP 和国家...${NC}"
    IP_INFO=$(curl -s --max-time 5 ipinfo.io/json)
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 获取 IP 信息失败，使用默认值（IP: 127.0.0.1, Country: Unknown）。${NC}"
        SERVER_IP="127.0.0.1"
        COUNTRY="Unknown"
    else
        SERVER_IP=$(echo "$IP_INFO" | grep '"ip"' | cut -d '"' -f 4)
        COUNTRY=$(echo "$IP_INFO" | grep '"country"' | cut -d '"' -f 4)
        if [ -z "$SERVER_IP" ] || [ -z "$COUNTRY" ]; then
            echo -e "${RED}⚠️ 解析 IP 信息失败，使用默认值（IP: 127.0.0.1, Country: Unknown）。${NC}"
            SERVER_IP="127.0.0.1"
            COUNTRY="Unknown"
        fi
    fi
    NAME="${COUNTRY}-Vless"

    # 保存配置参数以便打印连接信息
    echo "DNS_NAMESERVER=\"$DNS_NAMESERVER\"" > /tmp/vless_config_params
    echo "UUID=\"$UUID\"" >> /tmp/vless_config_params
    echo "DECRYPTION=\"$DECRYPTION\"" >> /tmp/vless_config_params
    echo "LISTEN=\"$LISTEN\"" >> /tmp/vless_config_params
    echo "PORTS=\"$PORTS\"" >> /tmp/vless_config_params
    echo "FLOW=\"$FLOW\"" >> /tmp/vless_config_params
    echo "SERVER_IP=\"$SERVER_IP\"" >> /tmp/vless_config_params
    echo "NAME=\"$NAME\"" >> /tmp/vless_config_params
    echo "TRANSPORT=\"$TRANSPORT\"" >> /tmp/vless_config_params
    echo "WS_PATH=\"$WS_PATH\"" >> /tmp/vless_config_params
    echo "GRPC_SERVICE=\"$GRPC_SERVICE\"" >> /tmp/vless_config_params

    # 输出结果
    echo -e "${GREEN}✅ VLESS Encryption 配置已生成：${NC}"
    echo "DNS 服务器: $DNS_NAMESERVER"
    echo "UUID: $UUID"
    echo "Decryption: $DECRYPTION"
    echo "监听地址: $LISTEN"
    echo "端口: $PORTS"
    echo "Flow: $FLOW"
    echo "传输层: $TRANSPORT"
    if [ -n "$WS_PATH" ]; then
        echo "Websocket 路径: $WS_PATH"
    fi
    if [ -n "$GRPC_SERVICE" ]; then
        echo "gRPC 服务名: $GRPC_SERVICE"
    fi
    echo "TLS: disabled"
    echo -e "\n${GREEN}📄 生成的 YAML 配置已保存到：${CONFIG_FILE}${NC}"
    echo -e "${CONFIG_YAML}"
    return 0
}

# 函数: 打印连接信息（仅 VLESS Encryption 节点）
print_connection_info() {
    if [ ! -f /tmp/vless_config_params ]; then
        echo -e "${RED}⚠️ 未找到最近生成的 VLESS 配置参数，请先生成配置！${NC}"
        return 1
    fi
    source /tmp/vless_config_params
    IFS=',' read -r -a port_array <<< "$PORTS"
    echo -e "${GREEN}✅ 客户端 Proxies 配置（单行 YAML）：${NC}"
    for port in "${port_array[@]}"; do
        PROXIES_YAML="{ name: \"${NAME}-${port}\", type: vless, server: \"${SERVER_IP}\", port: ${port}, udp: true, uuid: \"${UUID}\", flow: \"${FLOW}\", packet-encoding: \"xudp\", tls: false, encryption: \"${DECRYPTION}\", network: \"${TRANSPORT}\""
        if [ -n "$WS_PATH" ]; then
            PROXIES_YAML+=", ws-opts: { path: \"${WS_PATH}\" }"
        fi
        if [ -n "$GRPC_SERVICE" ]; then
            PROXIES_YAML+=", grpc-opts: { grpc-service-name: \"${GRPC_SERVICE}\" }"
        fi
        PROXIES_YAML+=", smux: { enabled: false } }"
        echo "$PROXIES_YAML"
    done
    return 0
}

# 子菜单
show_sub_menu() {
    echo -e "${YELLOW}🌟 VLESS Encryption 子菜单 🌟${NC}"
    echo "[1] 生成 VLESS Encryption 配置"
    echo "[2] 打印连接信息（仅 VLESS Encryption 节点）"
    echo "[3] 返回主菜单"
    echo -n "请选择选项 [1-3]："
    read -r choice
    case $choice in
        1)
            generate_vless_config
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 生成成功！${NC}"
            else
                echo -e "${RED}⚠️ 生成失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回子菜单...${NC}"
            sleep 2
            show_sub_menu
            ;;
        2)
            print_connection_info
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 打印成功！${NC}"
            else
                echo -e "${RED}⚠️ 打印失败！${NC}"
            fi
            echo -e "${YELLOW}🔄 返回子菜单...${NC}"
            sleep 2
            show_sub_menu
            ;;
        3)
            echo -e "${YELLOW}🔙 返回主菜单...${NC}"
            sleep 2
            return 0
            ;;
        *)
            echo -e "${RED}⚠️ 无效选项${NC}"
            sleep 1
            show_sub_menu
            ;;
    esac
}

# 主逻辑
show_sub_menu