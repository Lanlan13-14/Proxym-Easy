#!/bin/bash

# 🚀 独立脚本用于生成 mihomo 的 VLESS Encryption 配置（仅包含 nameserver 的 DNS 配置）。
# 功能：
# - 生成不启用 TLS 的 VLESS 配置，写入 /etc/mihomo/config.yaml，打印客户端 proxies 单行 YAML。
# - 支持传输层选择：[1] TCP [2] WebSocket [3] gRPC（默认：[3]）。
# - 支持 VLESS Encryption 配置：[1] mlkem768x25519plus [2] 标准 VLESS（无加密，默认：[1]） + [1] 原生外观 [2] 只 XOR 公钥 [3] 全随机数（默认：[3]） + [1] 仅 1-RTT [2] 1-RTT 和 600s 0-RTT（默认：[1]）。
# - 支持单个端口或端口段（示例：100 或 100-200），端口段未输入时随机选择 10 个连续端口。
# - 子菜单：[1] 生成 VLESS Encryption 配置 [2] 打印连接信息 [3] 返回主菜单。
# - 默认：gRPC + mlkem768x25519plus.random.1rtt，无 flow（非 TLS 模式）。
# - 如果配置文件存在，直接询问覆盖或追加。
# 使用方法：/usr/local/bin/script/vless_encryption.sh
# 依赖：yq, ss, curl (for ipinfo), /proc/sys/kernel/random/uuid, mihomo。
# 输出：配置写入 /etc/mihomo/config.yaml，打印 proxies YAML 和 URL 编码版本。

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
DEFAULT_FLOW="" # 非 TLS 模式默认无 flow
DEFAULT_DNS_NAMESERVER="8.8.8.8,1.1.1.1"
DEFAULT_NETWORK="grpc"
DEFAULT_WS_PATH="/"
DEFAULT_GRPC_SERVICE_NAME="GunService"
DEFAULT_ENCRYPTION_TYPE="mlkem768x25519plus"
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
            echo "${start_port}-$((start_port + count - 1))"
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
        echo -e "${RED}⚠️ 端口格式 $input 无效！示例：100 或 100-200${NC}"
        return 1
    fi
    echo "${port_list[*]}" | tr ' ' ','
    return 0
}

# 函数: 验证标准 Base64 字符串
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
        return 0
    fi
    echo -e "${RED}⚠️ Base64 字符串包含非法字符：${input}${NC}"
    return 1
}

# 函数: 清理和转换密钥/种子
clean_key() {
    local input="$1"
    # 清理空白字符
    input=$(echo "$input" | tr -d '[:space:]')
    # 替换 _ 为 /，- 为 +
    input=${input//_/\/}
    input=${input//-/+}
    echo "$input"
}

# 函数: URL 编码
url_encode() {
    local input="$1"
    printf '%s' "$input" | jq -sRr @uri
}

# 函数: 生成 VLESS Encryption 配置
generate_vless_config() {
    # 检查是否为交互模式
    if [[ ! -t 0 ]]; then
        echo -e "${RED}⚠️ 非交互模式，无法读取用户输入！请直接运行 'bash /usr/local/bin/script/vless_encryption.sh'${NC}"
        return 1
    fi

    # 检查依赖
    for cmd in "${MIHOMO_BIN}" yq ss curl; do
        if ! command -v "${cmd}" &> /dev/null; then
            echo -e "${RED}⚠️ ${cmd} 未安装，请运行 proxym-easy install！${NC}"
            return 1
        fi
    done

    # 检查 mihomo 版本
    MIHOMO_VERSION=$("${MIHOMO_BIN}" --version 2>&1)
    echo -e "${YELLOW}🔍 调试：mihomo 版本：${MIHOMO_VERSION}${NC}"

    # 检查 mihomo 命令是否支持 generate
    "${MIHOMO_BIN}" generate vless-x25519 >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ ${MIHOMO_BIN} 不支持 'generate vless-x25519' 命令，请检查 mihomo 版本或手动输入密钥！${NC}"
        return 1
    fi
    "${MIHOMO_BIN}" generate vless-mlkem768 >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ ${MIHOMO_BIN} 不支持 'generate vless-mlkem768' 命令，请检查 mihomo 版本或手动输入种子！${NC}"
        return 1
    fi

    # 创建配置目录
    mkdir -p "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"

    # 调试：检查配置文件是否存在
    echo -e "${YELLOW}🔍 调试：检查配置文件 ${CONFIG_FILE} 是否存在...${NC}"
    if [ -f "${CONFIG_FILE}" ]; then
        echo -e "${YELLOW}📄 配置文件 ${CONFIG_FILE} 存在，大小 $(stat -c %s "${CONFIG_FILE}") 字节，权限 $(stat -c %a "${CONFIG_FILE}")${NC}"
        echo -e "${YELLOW}🔍 调试：配置文件前几行：${NC}"
        head -n 5 "${CONFIG_FILE}" | sed 's/^/    /'
    else
        echo -e "${YELLOW}📄 配置文件 ${CONFIG_FILE} 不存在，将创建新文件${NC}"
    fi

    # 处理现有配置文件
    if [ -f "${CONFIG_FILE}" ]; then
        echo -e "${YELLOW}📄 检测到现有配置文件 ${CONFIG_FILE}，是否覆盖整个配置文件？(y/n，默认 n)：${NC}"
        read -r response
        response=${response:-n}
        echo -e "${YELLOW}🔍 调试：用户选择覆盖选项：${response}${NC}"
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}📄 是否追加新的 VLESS 配置到现有 listeners？(y/n，默认 y)：${NC}"
            read -r append_response
            append_response=${append_response:-y}
            echo -e "${YELLOW}🔍 调试：用户选择追加选项：${append_response}${NC}"
        fi
    else
        response="y" # 文件不存在，强制覆盖
        append_response="n"
    fi

    # 收集配置参数
    echo -e "${YELLOW}🌟 生成 VLESS Encryption 配置（不启用 TLS，包含 DNS nameserver）...${NC}"
    echo "请输入 DNS 服务器地址（逗号分隔，示例：8.8.8.8,1.1.1.1，默认：$DEFAULT_DNS_NAMESERVER，按回车使用默认值）："
    read -r DNS_NAMESERVER
    DNS_NAMESERVER=${DNS_NAMESERVER:-$DEFAULT_DNS_NAMESERVER}

    echo "请输入监听地址（默认：$DEFAULT_LISTEN，按回车使用默认值）："
    read -r LISTEN
    LISTEN=${LISTEN:-$DEFAULT_LISTEN}

    echo "请输入 UUID（默认随机生成，按回车使用随机 UUID）："
    read -r UUID
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    if [ -z "$UUID" ]; then
        echo -e "${RED}⚠️ UUID 生成失败，请手动输入！${NC}"
        return 1
    fi

    echo "请选择端口类型：[1] 单个端口（默认） [2] 端口段（示例：100-200）"
    read -r port_type
    if [[ "$port_type" == "2" ]]; then
        echo "请输入端口段（示例：100-200，按回车随机选择 10 个连续端口）："
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
    else
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
    fi

    echo "请选择加密类型：[1] mlkem768x25519plus（默认） [2] 标准 VLESS（无加密）"
    read -r encryption_choice
    case $encryption_choice in
        2) ENCRYPTION_TYPE="none"; DECRYPTION_TYPE="none"; RTT_MODE="" ;;
        1|"") ENCRYPTION_TYPE="mlkem768x25519plus" ;;
        *) 
            echo -e "${RED}⚠️ 无效选项，使用默认 mlkem768x25519plus！${NC}"
            ENCRYPTION_TYPE="mlkem768x25519plus"
            ;;
    esac

    if [[ "$ENCRYPTION_TYPE" == "mlkem768x25519plus" ]]; then
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
            echo "请输入第 $i 个 X25519 私钥（按回车随机生成，长度 44 字符）："
            read -r X25519_PRIVATE
            if [ -z "$X25519_PRIVATE" ]; then
                X25519_OUTPUT=$("${MIHOMO_BIN}" generate vless-x25519 2>&1)
                if [ $? -ne 0 ]; then
                    echo -e "${RED}⚠️ 生成 X25519 私钥失败！命令输出：\n${X25519_OUTPUT}${NC}"
                    echo -e "${YELLOW}请手动输入有效的 Base64 私钥（示例：SMtfjCQHpi66E8pURTnkKO1uuItVkvBgpjw8T3sXs==）！${NC}"
                    read -r X25519_PRIVATE
                    if ! validate_base64 "$X25519_PRIVATE" 44; then
                        echo -e "${RED}⚠️ 输入的 X25519 私钥无效：${X25519_PRIVATE}${NC}"
                        return 1
                    fi
                else
                    X25519_PRIVATE=$(echo "$X25519_OUTPUT" | grep -i 'PrivateKey:' | sed 's/.*PrivateKey: *//' | tr -d '[:space:]')
                    X25519_PRIVATE=$(clean_key "$X25519_PRIVATE")
                    echo -e "${YELLOW}🔍 调试：X25519 原始输出：${X25519_OUTPUT}${NC}"
                    echo -e "${YELLOW}🔍 调试：清理后的 X25519 私钥：${X25519_PRIVATE}${NC}"
                    if ! validate_base64 "$X25519_PRIVATE" 44; then
                        echo -e "${RED}⚠️ 生成的 X25519 私钥无效！${NC}"
                        echo -e "${YELLOW}请手动输入有效的 Base64 私钥（示例：SMtfjCQHpi66E8pURTnkKO1uuItVkvBgpjw8T3sXs==）！${NC}"
                        read -r X25519_PRIVATE
                        if ! validate_base64 "$X25519_PRIVATE" 44; then
                            echo -e "${RED}⚠️ 输入的 X25519 私钥仍无效：${X25519_PRIVATE}${NC}"
                            return 1
                        fi
                    fi
                fi
            fi
            echo -e "${YELLOW}使用的 X25519 私钥：${X25519_PRIVATE}${NC}"
            X25519_PRIVATE_KEYS+="${X25519_PRIVATE:+.$X25519_PRIVATE}"
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
            echo "请输入第 $i 个 ML-KEM-768 种子（按回车随机生成，长度 88 字符）："
            read -r MLKEM_SEED
            if [ -z "$MLKEM_SEED" ]; then
                MLKEM_OUTPUT=$("${MIHOMO_BIN}" generate vless-mlkem768 2>&1)
                if [ $? -ne 0 ]; then
                    echo -e "${RED}⚠️ 生成 ML-KEM-768 种子失败！命令输出：\n${MLKEM_OUTPUT}${NC}"
                    echo -e "${YELLOW}请手动输入有效的 Base64 种子（示例：kFWnpgGcLFb6jNbiepBshH0C2vmeHlYhBcbOKgMnoflSfsxPSvpPVYVtp7yuImes==）！${NC}"
                    read -r MLKEM_SEED
                    if ! validate_base64 "$MLKEM_SEED" 88; then
                        echo -e "${RED}⚠️ 输入的 ML-KEM-768 种子无效：${MLKEM_SEED}${NC}"
                        return 1
                    fi
                else
                    MLKEM_SEED=$(echo "$MLKEM_OUTPUT" | grep -i 'Seed:' | sed 's/.*Seed: *//' | tr -d '[:space:]')
                    MLKEM_SEED=$(clean_key "$MLKEM_SEED")
                    echo -e "${YELLOW}🔍 调试：ML-KEM-768 原始输出：${MLKEM_OUTPUT}${NC}"
                    echo -e "${YELLOW}🔍 调试：清理后的 ML-KEM-768 种子：${MLKEM_SEED}${NC}"
                    if ! validate_base64 "$MLKEM_SEED" 88; then
                        echo -e "${RED}⚠️ 生成的 ML-KEM-768 种子无效！${NC}"
                        echo -e "${YELLOW}请手动输入有效的 Base64 种子（示例：kFWnpgGcLFb6jNbiepBshH0C2vmeHlYhBcbOKgMnoflSfsxPSvpPVYVtp7yuImes==）！${NC}"
                        read -r MLKEM_SEED
                        if ! validate_base64 "$MLKEM_SEED" 88; then
                            echo -e "${RED}⚠️ 输入的 ML-KEM-768 种子仍无效：${MLKEM_SEED}${NC}"
                            return 1
                        fi
                    fi
                fi
            fi
            echo -e "${YELLOW}使用的 ML-KEM-768 种子：${MLKEM_SEED}${NC}"
            MLKEM_SEEDS+="${MLKEM_SEED:+.$MLKEM_SEED}"
        done
    fi

    # 设置 decryption 字段
    if [[ "$ENCRYPTION_TYPE" == "none" ]]; then
        DECRYPTION="none"
    else
        DECRYPTION="mlkem768x25519plus.${DECRYPTION_TYPE}.${RTT_MODE}${X25519_PRIVATE_KEYS}${MLKEM_SEEDS}"
        if ! [[ "$DECRYPTION" =~ ^mlkem768x25519plus\.(native|xorpub|random)\.(1rtt|600s)(\.[A-Za-z0-9+/=]+)+$ ]]; then
            echo -e "${RED}⚠️ 生成的 DECRYPTION 字符串格式无效：${DECRYPTION}${NC}"
            return 1
        fi
    fi

    echo "请输入 Flow（默认无 flow，建议非 TLS 模式留空，按回车使用默认值）："
    read -r FLOW
    FLOW=${FLOW:-$DEFAULT_FLOW}
    if [ -n "$FLOW" ]; then
        echo -e "${YELLOW}⚠️ 注意：非 TLS 模式下 Flow（如 xtls-rprx-vision）可能不可用，建议留空！${NC}"
    fi

    # 生成 listeners 配置
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

    # 保存配置
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "$CONFIG_YAML" > "${CONFIG_FILE}"
        if [ $? -ne 0 ]; then
            echo -e "${RED}⚠️ 写入 ${CONFIG_FILE} 失败，请检查权限！${NC}"
            return 1
        fi
        chmod 644 "${CONFIG_FILE}"
        echo -e "${GREEN}✅ 配置已覆盖并保存到 ${CONFIG_FILE}${NC}"
    elif [[ "$append_response" =~ ^[Yy]$ ]]; then
        if yq eval '.listeners' "${CONFIG_FILE}" > /dev/null 2>&1; then
            yq eval ".listeners += [$(yq eval -o=j -I=0 - <<< "$LISTENERS")]" -i "${CONFIG_FILE}" 2>/dev/null
            if [ $? -ne 0 ]; then
                echo -e "${RED}⚠️ 追加 Listener 到 ${CONFIG_FILE} 失败，请检查 yq 或配置文件格式！${NC}"
                echo -e "${YELLOW}🔍 调试：配置文件可能无效，前几行：${NC}"
                head -n 5 "${CONFIG_FILE}" | sed 's/^/    /'
                return 1
            fi
            chmod 644 "${CONFIG_FILE}"
            echo -e "${GREEN}✅ 新 Listener 已追加到 ${CONFIG_FILE}，保留现有配置${NC}"
        else
            echo -e "${YELLOW}📄 配置文件中无 listeners 字段，将添加新的 listeners 配置！${NC}"
            yq eval ".listeners = [$(yq eval -o=j -I=0 - <<< "$LISTENERS")]" -i "${CONFIG_FILE}" 2>/dev/null
            if [ $? -ne 0 ]; then
                echo -e "${RED}⚠️ 添加 listeners 到 ${CONFIG_FILE} 失败，请检查 yq 或配置文件格式！${NC}"
                echo -e "${YELLOW}🔍 调试：配置文件可能无效，前几行：${NC}"
                head -n 5 "${CONFIG_FILE}" | sed 's/^/    /'
                return 1
            fi
            chmod 644 "${CONFIG_FILE}"
            echo -e "${GREEN}✅ 新 listeners 字段已添加到 ${CONFIG_FILE}${NC}"
        fi
    else
        echo -e "${YELLOW}🚫 用户取消追加，保留现有配置文件！${NC}"
        return 1
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
    echo "NETWORK=\"$NETWORK\"" >> /tmp/vless_config_params
    if [[ "$NETWORK" == "ws" ]]; then
        echo "WS_PATH=\"$WS_PATH\"" >> /tmp/vless_config_params
    elif [[ "$NETWORK" == "grpc" ]]; then
        echo "GRPC_SERVICE_NAME=\"$GRPC_SERVICE_NAME\"" >> /tmp/vless_config_params
    fi

    # 输出结果
    echo -e "${GREEN}✅ VLESS Encryption 配置已生成：${NC}"
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
    echo -e "\n${GREEN}📄 生成的 YAML 配置已保存到：${CONFIG_FILE}${NC}"
    echo -e "${CONFIG_YAML}"
    if [[ "$ENCRYPTION_TYPE" == "mlkem768x25519plus" ]]; then
        echo -e "${YELLOW}⚠️ 注意：请确保客户端软件（如 mihomo）支持 mlkem768x25519plus 加密方案！${NC}"
    fi
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
        # 输出 URL 编码版本
        if [[ "$DECRYPTION" != "none" ]]; then
            ENCODED_DECRYPTION=$(url_encode "$DECRYPTION")
            VLESS_URL="vless://${UUID}@${SERVER_IP}:${port}?type=${NETWORK}&encryption=${ENCODED_DECRYPTION}&serviceName=${GRPC_SERVICE_NAME}#${NAME}-${port}"
            echo -e "${YELLOW}🔗 VLESS URL（URL 编码，供不支持复杂 encryption 的客户端）：${NC}"
            echo "$VLESS_URL"
        fi
    done
    if [[ "$DECRYPTION" == "mlkem768x25519plus"* ]]; then
        echo -e "${YELLOW}⚠️ 请确保客户端软件支持 mlkem768x25519plus 加密，并验证 encryption 字段是否与服务器端一致！${NC}"
    fi
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