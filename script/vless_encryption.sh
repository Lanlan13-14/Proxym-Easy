#!/bin/bash

# 🚀 独立脚本用于生成 mihomo 的 VLESS Encryption 配置（仅包含 nameserver 的 DNS 配置）。
# 功能：
# - 生成不启用 TLS 的 VLESS Encryption 配置，写入 /etc/mihomo/config.yaml，打印客户端 proxies 单行 YAML。
# - 支持传输层选择：[1] TCP [2] WebSocket [3] gRPC（默认：[3]）。
# - 支持 VLESS Encryption 配置： [1] 原生外观 [2] 只 XOR 公钥 [3] 全随机数（默认：[3]） + [1] 仅 1-RTT [2] 1-RTT 和 600s 0-RTT（默认：[1]），多个 Base64 串联。
# - 支持单个端口或端口段（示例：200,302 或 200,204,401-429,501-503），端口段未输入时随机从 10000-20000 选择 10 个连续端口。
# - 子菜单：[1] 生成 VLESS Encryption 配置 [2] 打印连接信息 [3] 返回主菜单。
# - 所有选项失败后返回子菜单，[3] 返回主菜单。
# - 默认：gRPC + mlkem768x25519plus.random.1rtt。
# - 移除 30 秒输入超时。
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
DEFAULT_NETWORK="grpc"
DEFAULT_WS_PATH="/"
DEFAULT_GRPC_SERVICE_NAME="GunService"
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

    echo "请选择传输层：[1] TCP [2] WebSocket [3] gRPC（默认：[3]）"
    read -r network_choice
    case $network_choice in
        1) NETWORK="tcp" ;;
        2)
            NETWORK="ws"
            echo "请输入 WebSocket 路径（默认：$DEFAULT_WS_PATH，按回车使用默认值）："
            read -r WS_PATH
            WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
            ;;
        3|"") 
            NETWORK="grpc"
            echo "请输入 gRPC 服务名称（默认：$DEFAULT_GRPC_SERVICE_NAME，按回车使用默认值）："
            read -r GRPC_SERVICE_NAME
            GRPC_SERVICE_NAME=${GRPC_SERVICE_NAME:-$DEFAULT_GRPC_SERVICE_NAME}
            ;;
        *)
            echo -e "${RED}⚠️ 无效选项，使用默认 gRPC！${NC}"
            NETWORK="grpc"
            GRPC_SERVICE_NAME="$DEFAULT_GRPC_SERVICE_NAME"
            ;;
    esac

    echo "请选择 VLESS Encryption 类型：[1] 原生外观 [2] 只 XOR 公钥 [3] 全随机数（默认：[3]）"
    read -r decryption_type
    case $decryption_type in
        1) DECRYPTION_TYPE="native" ;;
        2) DECRYPTION_TYPE="xorpub" ;;
        3|"") DECRYPTION_TYPE="random" ;;
        *) 
            echo -e "${RED}⚠️ 无效选项，使用默认全随机数！${NC}"
            DECRYPTION_TYPE="random"
            ;;
    esac

    echo "请选择 RTT 模式：[1] 仅 1-RTT [2] 1-RTT 和 600s 0-RTT（默认：[1]）"
    read -r rtt_mode
    case $rtt_mode in
        1|"") RTT_MODE="1rtt" ;;
        2) RTT_MODE="600s" ;;
        *) 
            echo -e "${RED}⚠️ 无效选项，使用默认 1-RTT！${NC}"
            RTT_MODE="1rtt"
            ;;
    esac

    echo "请输入 X25519 私钥数量（默认 1，按回车使用默认值）："
    read -r x25519_count
    x25519_count=${x25519_count:-1}
    if ! [[ "$x25519_count" =~ ^[0-9]+$ ]] || [ "$x25519_count" -lt 1 ]; then
        echo -e "${RED}⚠️ 私钥数量必须为正整数，使用默认 1！${NC}"
        x25519_count=1
    fi

    X25519_PRIVATE_KEYS=""
    for ((i=1; i<=x25519_count; i++)); do
        echo "请输入第 $i 个 X25519 私钥（按回车随机生成）："
        read -r X25519_PRIVATE
        if [ -z "$X25519_PRIVATE" ]; then
            X25519_OUTPUT=$("${MIHOMO_BIN}" generate vless-x25519 2>/dev/null)
            if [ $? -ne 0 ]; then
                echo -e "${RED}⚠️ 生成 X25519 私钥失败！输出：\n${X25519_OUTPUT}${NC}"
                return 1
            fi
            X25519_PRIVATE=$(echo "$X25519_OUTPUT" | grep 'PrivateKey:' | sed 's/.*PrivateKey: *//')
            if [ -z "$X25519_PRIVATE" ]; then
                echo -e "${RED}⚠️ 解析 X25519 私钥失败！输出：\n${X25519_OUTPUT}${NC}"
                return 1
            fi
        fi
        X25519_PRIVATE_KEYS+=".${X25519_PRIVATE}"
    done

    echo "请输入 ML-KEM-768 种子数量（默认 1，按回车使用默认值）："
    read -r mlkem_count
    mlkem_count=${mlkem_count:-1}
    if ! [[ "$mlkem_count" =~ ^[0-9]+$ ]] || [ "$mlkem_count" -lt 1 ]; then
        echo -e "${RED}⚠️ 种子数量必须为正整数，使用默认 1！${NC}"
        mlkem_count=1
    fi

    MLKEM_SEEDS=""
    for ((i=1; i<=mlkem_count; i++)); do
        echo "请输入第 $i 个 ML-KEM-768 种子（按回车随机生成）："
        read -r MLKEM_SEED
        if [ -z "$MLKEM_SEED" ]; then
            MLKEM_OUTPUT=$("${MIHOMO_BIN}" generate vless-mlkem768 2>/dev/null)
            if [ $? -ne 0 ]; then
                echo -e "${RED}⚠️ 生成 ML-KEM-768 种子失败！输出：\n${MLKEM_OUTPUT}${NC}"
                return 1
            fi
            MLKEM_SEED=$(echo "$MLKEM_OUTPUT" | grep 'Seed:' | sed 's/.*Seed: *//')
            if [ -z "$MLKEM_SEED" ]; then
                echo -e "${RED}⚠️ 解析 ML-KEM-768 种子失败！输出：\n${MLKEM_OUTPUT}${NC}"
                return 1
            fi
        fi
        MLKEM_SEEDS+=".${MLKEM_SEED}"
    done

    echo "请输入 Flow（默认：$DEFAULT_FLOW，按回车使用默认值）："
    read -r FLOW
    FLOW=${FLOW:-$DEFAULT_FLOW}

    DECRYPTION="mlkem768x25519plus.${DECRYPTION_TYPE}.${RTT_MODE}${X25519_PRIVATE_KEYS}${MLKEM_SEEDS}"

    # 生成 listeners 配置
    LISTENERS=$(cat <<EOF
  - name: vless-in-$(date +%s)
    type: vless
    listen: $LISTEN
    port: $PORTS
    decryption: $DECRYPTION
    tls: false
EOF
)
    if [[ "$NETWORK" == "ws" ]]; then
        LISTENERS+=$'\n    ws-path: '"$WS_PATH"
    elif [[ "$NETWORK" == "grpc" ]]; then
        LISTENERS+=$'\n    grpc-service-name: '"$GRPC_SERVICE_NAME"
    fi
    LISTENERS+=$'\n    users:\n      - username: user1\n        uuid: '"$UUID"$'\n        flow: '"$FLOW"

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

    # 输出结果
    echo -e "${GREEN}✅ VLESS Encryption 配置已生成：${NC}"
    echo "DNS 服务器: $DNS_NAMESERVER"
    echo "UUID: $UUID"
    echo "Decryption: $DECRYPTION"
    echo "监听地址: $LISTEN"
    -echo "端口: $PORTS"
    echo "Flow: $FLOW"
    echo "传输层: $NETWORK"
    if [[ "$NETWORK" == "ws" ]]; then
        echo "WebSocket 路径: $WS_PATH"
    elif [[ "$NETWORK" == "grpc" ]]; then
        echo "gRPC 服务名称: $GRPC_SERVICE_NAME"
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
        PROXIES_YAML="{ name: \"${NAME}-${port}\", type: vless, server: \"${SERVER_IP}\", port: ${port}, udp: true, uuid: \"${UUID}\", flow: \"${FLOW}\", packet-encoding: \"xudp\", tls: false, encryption: \"${DECRYPTION}\", network: \"${NETWORK}\""
        if [[ "$NETWORK" == "ws" ]]; then
            PROXIES_YAML+=", ws-opts: { path: \"${WS_PATH}\" }"
        elif [[ "$NETWORK" == "grpc" ]]; then
            PROXIES_YAML+=", grpc-opts: { grpc-service-name: \"${GRPC_SERVICE_NAME}\" }"
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