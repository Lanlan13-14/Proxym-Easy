#!/bin/bash

# 🚀 修复后的 VLESS Encryption 配置生成脚本
# 功能：
# - 生成 mihomo 的 VLESS 配置，写入 /etc/mihomo/config.yaml，打印客户端 proxies YAML 和 VLESS URL。
# - 支持传输层：[1] TCP [2] WebSocket [3] gRPC（默认：[3]）。
# - 支持加密类型：[1] mlkem768x25519plus [2] 标准 VLESS（默认：[2]）。
# - 支持 decryption 类型：[1] native [2] xorpub [3] random（默认：[3]）。
# - 支持 RTT 模式：[1] 1-RTT [2] 0-RTT（600s）（默认：[1]）。
# - 使用 mihomo generate 的 Password 和 Client，自动修复 Base64 填充。
# - 支持单个端口（默认 10840）或端口段。
# - 子菜单：[1] 生成配置 [2] 打印连接信息 [3] 返回主菜单。
# 依赖：yq, ss, curl, jq, mihomo。

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
DEFAULT_PORT="10840"
DEFAULT_DNS_NAMESERVER="8.8.8.8,1.1.1.1"
DEFAULT_NETWORK="grpc"
DEFAULT_WS_PATH="/"
DEFAULT_GRPC_SERVICE_NAME="GunService"
DEFAULT_ENCRYPTION_TYPE="none"
DEFAULT_DECRYPTION_TYPE="random"
DEFAULT_RTT_MODE="1rtt"

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
        port=$((RANDOM % 10001 + 10000))
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
        start_port=$((RANDOM % (20000 - count + 1) + 10000))
        local valid=true
        local ports=()
        for ((i=0; i<count; i++)); do
            local port=$((start_port + i))
            if ! check_port "$port"; then
                valid=false
                break
            fi
            ports+=("${port}")
        done
        if $valid; then
            echo "${start_port}-$((start_port + count - 1))"
            return 0
        fi
        ((attempts++))
    done
    echo -e "${RED}⚠️ 无法找到 $count 个连续可用端口，请手动指定！${NC}"
    return 1
}

# 函数: 解析端口段
parse_ports() {
    local input="$1"
    local port_list=()
    if [[ "$input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start=${BASH_REMATCH[1]}
        local end=${BASH_REMATCH[2]}
        if (( start > end )); then
            echo -e "${RED}⚠️ 端口范围 $input 无效，起始端口必须小于等于结束端口！${NC}"
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
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        if check_port "$input"; then
            port_list+=("$input")
        else
            echo -e "${RED}⚠️ 端口 $input 已被占用！${NC}"
            return 1
        fi
    else
        echo -e "${RED}⚠️ 端口格式 $input 无效！示例：10840 或 100-200${NC}"
        return 1
    fi
    echo "${port_list[*]}" | tr ' ' ','
    return 0
}

# 函数: 验证 Base64 字符串
validate_base64() {
    local input="$1"
    local expected_length="$2"
    if [ -z "$input" ]; then
        echo -e "${RED}⚠️ Base64 字符串为空！${NC}"
        return 1
    fi
    if [[ "$input" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        local length=${#input}
        if [ -n "$expected_length" ] && [ "$length" -ne "$expected_length" ]; then
            echo -e "${RED}⚠️ Base64 字符串长度 $length 不符合预期（应为 $expected_length）：${input}${NC}"
            return 1
        fi
        if ! echo "$input" | base64 -d >/dev/null 2>&1; then
            echo -e "${RED}⚠️ Base64 字符串无法解码：${input}${NC}"
            return 1
        fi
        return 0
    fi
    echo -e "${RED}⚠️ Base64 字符串包含非法字符：${input}${NC}"
    return 1
}

# 函数: 清理和转换密钥/种子
clean_key() {
    local input="$1"
    input=$(echo "$input" | tr -d '[:space:]')
    input=${input//_/\/}
    input=${input//-/+}
    local length=${#input}
    local mod=$((length % 4))
    if [ $mod -ne 0 ]; then
        local padding=$((4 - mod))
        input="${input}$(printf '=%.0s' $(seq 1 $padding))"
    fi
    echo "$input"
}

# 函数: URL 编码
url_encode() {
    local input="$1"
    printf '%s' "$input" | jq -sRr @uri
}

# 函数: 生成 VLESS 配置
generate_vless_config() {
    if [[ ! -t 0 ]]; then
        echo -e "${RED}⚠️ 非交互模式，请直接运行 'bash $0'${NC}"
        return 1
    fi

    for cmd in "${MIHOMO_BIN}" yq ss curl jq; do
        if ! command -v "${cmd}" &> /dev/null; then
            echo -e "${RED}⚠️ ${cmd} 未安装，请安装！${NC}"
            return 1
        fi
    done

    MIHOMO_VERSION=$("${MIHOMO_BIN}" --version 2>&1)
    echo -e "${YELLOW}🔍 调试：mihomo 版本：${MIHOMO_VERSION}${NC}"

    "${MIHOMO_BIN}" generate vless-x25519 >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ ${MIHOMO_BIN} 不支持 'generate vless-x25519'！${NC}"
        return 1
    fi
    "${MIHOMO_BIN}" generate vless-mlkem768 >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ ${MIHOMO_BIN} 不支持 'generate vless-mlkem768'！${NC}"
        return 1
    fi

    mkdir -p "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"

    if [ -f "${CONFIG_FILE}" ]; then
        echo -e "${YELLOW}📄 配置文件 ${CONFIG_FILE} 存在，是否覆盖？(y/n，默认 n)：${NC}"
        read -r response
        response=${response:-n}
        echo -e "${YELLOW}🔍 调试：覆盖选项：${response}${NC}"
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}📄 是否追加新的 VLESS 配置？(y/n，默认 y)：${NC}"
            read -r append_response
            append_response=${append_response:-y}
            echo -e "${YELLOW}🔍 调试：追加选项：${append_response}${NC}"
        fi
    else
        response="y"
        append_response="n"
    fi

    echo -e "${YELLOW}🌟 生成 VLESS 配置...${NC}"
    echo "请输入 DNS 服务器地址（默认：$DEFAULT_DNS_NAMESERVER）："
    read -r DNS_NAMESERVER
    DNS_NAMESERVER=${DNS_NAMESERVER:-$DEFAULT_DNS_NAMESERVER}

    echo "请输入监听地址（默认：$DEFAULT_LISTEN）："
    read -r LISTEN
    LISTEN=${LISTEN:-$DEFAULT_LISTEN}

    echo "请输入 UUID（默认随机生成）："
    read -r UUID
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    if [ -z "$UUID" ]; then
        echo -e "${RED}⚠️ UUID 生成失败，请手动输入！${NC}"
        return 1
    fi

    echo "请选择端口类型：[1] 单个端口（默认） [2] 端口段"
    read -r port_type
    if [[ "$port_type" == "2" ]]; then
        echo "请输入端口段（示例：100-200，默认随机 10 个端口）："
        read -r PORTS
        if [ -z "$PORTS" ]; then
            PORTS=$(recommend_port_range)
            if [ $? -ne 0 ]; then
                return 1
            fi
        fi
        PORTS=$(parse_ports "$PORTS")
        if [ $? -ne 0 ]; then
            return 1
        fi
    else
        echo "请输入端口（默认：$DEFAULT_PORT）："
        read -r PORT
        PORT=${PORT:-$DEFAULT_PORT}
        if ! check_port "$PORT"; then
            echo -e "${RED}⚠️ 端口 $PORT 已被占用！${NC}"
            return 1
        fi
        PORTS="$PORT"
    fi

    echo "请选择加密类型：[1] mlkem768x25519plus [2] 标准 VLESS（默认：[2]）"
    read -r encryption_choice
    case $encryption_choice in
        1) ENCRYPTION_TYPE="mlkem768x25519plus" ;;
        2|"") ENCRYPTION_TYPE="none" ;;
        *) 
            echo -e "${RED}⚠️ 无效选项，使用默认标准 VLESS！${NC}"
            ENCRYPTION_TYPE="none"
            ;;
    esac

    if [[ "$ENCRYPTION_TYPE" == "mlkem768x25519plus" ]]; then
        echo "请选择 decryption 类型：[1] native [2] xorpub [3] random（默认：[3]）"
        read -r decryption_type
        case $decryption_type in
            1) DECRYPTION_TYPE="native" ;;
            2) DECRYPTION_TYPE="xorpub" ;;
            3|"") DECRYPTION_TYPE="random" ;;
            *) 
                echo -e "${RED}⚠️ 无效选项，使用默认 random！${NC}"
                DECRYPTION_TYPE="random"
                ;;
        esac

        echo "请选择 RTT 模式：[1] 1-RTT（默认） [2] 0-RTT（600s）"
        read -r rtt_mode
        case $rtt_mode in
            1|"") RTT_MODE="1rtt" ;;
            2) RTT_MODE="600s" ;;
            *) 
                echo -e "${RED}⚠️ 无效选项，使用默认 1-RTT！${NC}"
                RTT_MODE="1rtt"
                ;;
        esac

        echo "请输入 X25519 Password 数量（默认 1）："
        read -r x25519_count
        x25519_count=${x25519_count:-1}
        if ! [[ "$x25519_count" =~ ^[0-9]+$ ]] || [ "$x25519_count" -lt 1 ]; then
            echo -e "${RED}⚠️ 数量必须为正整数，使用默认 1！${NC}"
            x25519_count=1
        fi

        X25519_PASSWORDS=""
        for ((i=1; i<=x25519_count; i++)); do
            echo "请输入第 $i 个 X25519 Password（默认随机生成，长度 44）："
            read -r X25519_PASSWORD
            if [ -z "$X25519_PASSWORD" ]; then
                X25519_OUTPUT=$("${MIHOMO_BIN}" generate vless-x25519 2>&1)
                if [ $? -ne 0 ]; then
                    echo -e "${RED}⚠️ 生成 X25519 Password 失败！输出：\n${X25519_OUTPUT}${NC}"
                    return 1
                fi
                X25519_PASSWORD=$(echo "$X25519_OUTPUT" | grep -i 'Password:' | sed 's/.*Password: *//' | tr -d '[:space:]')
                X25519_PASSWORD=$(clean_key "$X25519_PASSWORD")
                echo -e "${YELLOW}🔍 调试：X25519 输出：${X25519_OUTPUT}${NC}"
                echo -e "${YELLOW}🔍 调试：清理后的 X25519 Password：${X25519_PASSWORD}${NC}"
                if ! validate_base64 "$X25519_PASSWORD" 44; then
                    echo -e "${RED}⚠️ 生成的 X25519 Password 无效！${NC}"
                    return 1
                fi
            fi
            echo -e "${YELLOW}使用的 X25519 Password：${X25519_PASSWORD}${NC}"
            X25519_PASSWORDS+="${X25519_PASSWORD:+.$X25519_PASSWORD}"
        done

        echo "请输入 ML-KEM-768 Client 数量（默认 1）："
        read -r mlkem_count
        mlkem_count=${mlkem_count:-1}
        if ! [[ "$mlkem_count" =~ ^[0-9]+$ ]] || [ "$mlkem_count" -lt 1 ]; then
            echo -e "${RED}⚠️ 数量必须为正整数，使用默认 1！${NC}"
            mlkem_count=1
        fi

        MLKEM_CLIENTS=""
        for ((i=1; i<=mlkem_count; i++)); do
            echo "请输入第 $i 个 ML-KEM-768 Client（默认随机生成，长度 684）："
            read -r MLKEM_CLIENT
            if [ -z "$MLKEM_CLIENT" ]; then
                MLKEM_OUTPUT=$("${MIHOMO_BIN}" generate vless-mlkem768 2>&1)
                if [ $? -ne 0 ]; then
                    echo -e "${RED}⚠️ 生成 ML-KEM-768 Client 失败！输出：\n${MLKEM_OUTPUT}${NC}"
                    return 1
                fi
                MLKEM_CLIENT=$(echo "$MLKEM_OUTPUT" | grep -i 'Client:' | sed 's/.*Client: *//' | tr -d '[:space:]')
                MLKEM_CLIENT=$(clean_key "$MLKEM_CLIENT")
                echo -e "${YELLOW}🔍 调试：ML-KEM-768 输出：${MLKEM_OUTPUT}${NC}"
                echo -e "${YELLOW}🔍 调试：清理后的 ML-KEM-768 Client：${MLKEM_CLIENT}${NC}"
                if ! validate_base64 "$MLKEM_CLIENT" 684; then
                    echo -e "${RED}⚠️ 生成的 ML-KEM-768 Client 无效！${NC}"
                    return 1
                fi
            fi
            echo -e "${YELLOW}使用的 ML-KEM-768 Client：${MLKEM_CLIENT}${NC}"
            MLKEM_CLIENTS+="${MLKEM_CLIENT:+.$MLKEM_CLIENT}"
        done
    fi

    DECRYPTION="$ENCRYPTION_TYPE"
    if [[ "$ENCRYPTION_TYPE" == "mlkem768x25519plus" ]]; then
        DECRYPTION="mlkem768x25519plus.${DECRYPTION_TYPE}.${RTT_MODE}${X25519_PASSWORDS}${MLKEM_CLIENTS}"
        if ! [[ "$DECRYPTION" =~ ^mlkem768x25519plus\.(native|xorpub|random)\.(1rtt|600s)(\.[A-Za-z0-9+/=]+)+$ ]]; then
            echo -e "${RED}⚠️ DECRYPTION 格式无效：${DECRYPTION}${NC}"
            return 1
        fi
    fi

    echo "请输入 Flow（默认空，建议非 TLS 留空）："
    read -r FLOW
    if [ -n "$FLOW" ]; then
        echo -e "${YELLOW}⚠️ 非 TLS 模式下 Flow 可能不可用！${NC}"
    fi

    echo "请选择传输层：[1] TCP [2] WebSocket [3] gRPC（默认：[3]）"
    read -r network_choice
    case $network_choice in
        1) NETWORK="tcp" ;;
        2)
            NETWORK="ws"
            echo "请输入 WebSocket 路径（默认：$DEFAULT_WS_PATH）："
            read -r WS_PATH
            WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
            ;;
        3|"") 
            NETWORK="grpc"
            echo "请输入 gRPC 服务名称（默认：$DEFAULT_GRPC_SERVICE_NAME）："
            read -r GRPC_SERVICE_NAME
            GRPC_SERVICE_NAME=${GRPC_SERVICE_NAME:-$DEFAULT_GRPC_SERVICE_NAME}
            ;;
        *)
            echo -e "${RED}⚠️ 无效选项，使用默认 gRPC！${NC}"
            NETWORK="grpc"
            GRPC_SERVICE_NAME="$DEFAULT_GRPC_SERVICE_NAME"
            ;;
    esac

    LISTENERS=$(cat <<EOF
  - name: vless-in-$(date +%s)
    type: vless
    listen: $LISTEN
    port: $PORTS
    decryption: $DECRYPTION
    tls: false
    network: $NETWORK
EOF
)
    if [[ "$NETWORK" == "ws" ]]; then
        LISTENERS+=$'\n    ws-path: '"$WS_PATH"
    elif [[ "$NETWORK" == "grpc" ]]; then
        LISTENERS+=$'\n    grpc-service-name: '"$GRPC_SERVICE_NAME"
    fi
    if [ -n "$FLOW" ]; then
        LISTENERS+=$'\n    users:\n      - username: user1\n        uuid: '"$UUID"$'\n        flow: '"$FLOW"
    else
        LISTENERS+=$'\n    users:\n      - username: user1\n        uuid: '"$UUID"
    fi

    CONFIG_YAML=$(cat <<EOF
log-level: error

dns:
  nameserver:
$(echo "$DNS_NAMESERVER" | tr ',' '\n' | sed 's/^/    - /')

listeners:
$LISTENERS
EOF
)

    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "$CONFIG_YAML" > "${CONFIG_FILE}"
        if [ $? -ne 0 ]; then
            echo -e "${RED}⚠️ 写入 ${CONFIG_FILE} 失败！${NC}"
            return 1
        fi
        chmod 644 "${CONFIG_FILE}"
        echo -e "${GREEN}✅ 配置已覆盖：${CONFIG_FILE}${NC}"
    elif [[ "$append_response" =~ ^[Yy]$ ]]; then
        if yq eval '.listeners' "${CONFIG_FILE}" > /dev/null 2>&1; then
            yq eval ".listeners += [$(yq eval -o=j -I=0 - <<< "$LISTENERS")]" -i "${CONFIG_FILE}" 2>/dev/null
            if [ $? -ne 0 ]; then
                echo -e "${RED}⚠️ 追加 Listener 失败！${NC}"
                return 1
            fi
            chmod 644 "${CONFIG_FILE}"
            echo -e "${GREEN}✅ 新 Listener 已追加到 ${CONFIG_FILE}${NC}"
        else
            yq eval ".listeners = [$(yq eval -o=j -I=0 - <<< "$LISTENERS")]" -i "${CONFIG_FILE}" 2>/dev/null
            if [ $? -ne 0 ]; then
                echo -e "${RED}⚠️ 添加 listeners 失败！${NC}"
                return 1
            fi
            chmod 644 "${CONFIG_FILE}"
            echo -e "${GREEN}✅ 新 listeners 字段已添加：${CONFIG_FILE}${NC}"
        fi
    else
        echo -e "${YELLOW}🚫 用户取消，保留现有配置文件！${NC}"
        return 1
    fi

    echo -e "${YELLOW}🌐 获取服务器 IP 和国家...${NC}"
    IP_INFO=$(curl -s --max-time 5 ipinfo.io/json)
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 获取 IP 失败，使用默认值！${NC}"
        SERVER_IP="127.0.0.1"
        COUNTRY="Unknown"
    else
        SERVER_IP=$(echo "$IP_INFO" | jq -r '.ip')
        COUNTRY=$(echo "$IP_INFO" | jq -r '.country')
        if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "null" ]; then
            SERVER_IP="127.0.0.1"
            COUNTRY="Unknown"
        fi
    fi
    NAME="${COUNTRY}-Vless"

    echo "DNS_NAMESERVER=\"$DNS_NAMESERVER\"" > /tmp/vless_config_params
    echo "UUID=\"$UUID\"" >> /tmp/vless_config_params
    echo "DECRYPTION=\"$DECRYPTION\"" >> /tmp/vless_config_params
    echo "LISTEN=\"$LISTEN\"" >> /tmp/vless_config_params
    echo "PORTS=\"$PORTS\"" >> /tmp/vless_config_params
    echo "FLOW=\"$FLOW\"" >> /tmp/vless_config_params
    echo "SERVER_IP=\"$SERVER_IP\"" >> /tmp/vless_config_params
    echo "NAME=\"$NAME\"" >> /tmp/vless_config_params
    echo "NETWORK=\"$NETWORK\"" >> /tmp/vless_config_params
    if [[ "$NETWORK" == "ws" ]]; then
        echo "WS_PATH=\"$WS_PATH\"" >> /tmp/vless_config_params
    elif [[ "$NETWORK" == "grpc" ]]; then
        echo "GRPC_SERVICE_NAME=\"$GRPC_SERVICE_NAME\"" >> /tmp/vless_config_params
    fi

    echo -e "${GREEN}✅ VLESS 配置生成：${NC}"
    echo "DNS 服务器: $DNS_NAMESERVER"
    echo "UUID: $UUID"
    echo "Decryption: $DECRYPTION"
    echo "监听地址: $LISTEN"
    echo "端口: $PORTS"
    echo "Flow: $FLOW"
    echo "传输层: $NETWORK"
    if [[ "$NETWORK" == "ws" ]]; then
        echo "WebSocket 路径: $WS_PATH"
    elif [[ "$NETWORK" == "grpc" ]]; then
        echo "gRPC 服务名称: $GRPC_SERVICE_NAME"
    fi
    echo "TLS: disabled"
    echo -e "\n${GREEN}📄 配置已保存到：${CONFIG_FILE}${NC}"
    echo -e "${CONFIG_YAML}"
    if [[ "$ENCRYPTION_TYPE" == "mlkem768x25519plus" ]]; then
        echo -e "${YELLOW}⚠️ 确保客户端支持 mlkem768x25519plus！${NC}"
    fi
    return 0
}

# 函数: 打印连接信息
print_connection_info() {
    if [ ! -f /tmp/vless_config_params ]; then
        echo -e "${RED}⚠️ 未找到配置参数，请先生成配置！${NC}"
        return 1
    fi
    source /tmp/vless_config_params
    IFS=',' read -r -a port_array <<< "$PORTS"
    echo -e "${GREEN}✅ 客户端 Proxies 配置：${NC}"
    for port in "${port_array[@]}"; do
        PROXIES_YAML="{ name: \"${NAME}-${port}\", type: vless, server: \"${SERVER_IP}\", port: ${port}, udp: true, uuid: \"${UUID}\""
        if [ -n "$FLOW" ]; then
            PROXIES_YAML+=", flow: \"${FLOW}\""
        fi
        PROXIES_YAML+=", packet-encoding: \"xudp\", tls: false, encryption: \"${DECRYPTION}\", network: \"${NETWORK}\""
        if [[ "$NETWORK" == "ws" ]]; then
            PROXIES_YAML+=", ws-opts: { path: \"${WS_PATH}\" }"
        elif [[ "$NETWORK" == "grpc" ]]; then
            PROXIES_YAML+=", grpc-opts: { grpc-service-name: \"${GRPC_SERVICE_NAME}\" }"
        fi
        PROXIES_YAML+=", smux: { enabled: false } }"
        echo "$PROXIES_YAML"
        ENCODED_DECRYPTION=$(url_encode "$DECRYPTION")
        VLESS_URL="vless://${UUID}@${SERVER_IP}:${port}?type=${NETWORK}&encryption=${ENCODED_DECRYPTION}&serviceName=${GRPC_SERVICE_NAME}#${NAME}-${port}"
        echo -e "${YELLOW}🔗 VLESS URL：${NC}"
        echo "$VLESS_URL"
    done
    if [[ "$DECRYPTION" == "mlkem768x25519plus"* ]]; then
        echo -e "${YELLOW}⚠️ 确保客户端支持 mlkem768x25519plus！${NC}"
    fi
    return 0
}

# 子菜单
show_sub_menu() {
    echo -e "${YELLOW}🌟 VLESS Encryption 子菜单 🌟${NC}"
    echo "[1] 生成 VLESS 配置"
    echo "[2] 打印连接信息"
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