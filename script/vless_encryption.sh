#!/bin/bash

# 独立脚本用于生成 mihomo 的 VLESS encryption 配置（仅包含 nameserver 的 DNS 配置）。
# 功能：生成不启用 TLS 的 VLESS 配置，写入 /etc/mihomo/config.yaml，打印客户端 proxies 单行 YAML。
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
DEFAULT_PORT=10817
DEFAULT_LISTEN="0.0.0.0"
DEFAULT_FLOW="xtls-rprx-vision"
DEFAULT_DNS_NAMESERVER="8.8.8.8,1.1.1.1"

# 函数: 检查端口是否被占用
check_port() {
    local port="$1"
    if ss -tuln | grep -q ":${port}\b"; then
        return 1
    fi
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

# 检查依赖
for cmd in "${MIHOMO_BIN}" yq ss curl; do
    if ! command -v "${cmd}" &> /dev/null; then
        echo -e "${RED}⚠️ ${cmd} 未安装，请运行 proxym-easy install！${NC}"
        exit 1
    fi
done

# 创建配置目录
mkdir -p "${CONFIG_DIR}"
chmod 755 "${CONFIG_DIR}"

# 收集配置参数
echo -e "${YELLOW}生成 VLESS Encryption 配置（不启用 TLS，包含 DNS nameserver）...${NC}"
echo "请输入 DNS 服务器地址（逗号分隔，示例：8.8.8.8,1.1.1.1，默认：$DEFAULT_DNS_NAMESERVER，按回车使用默认值）："
read -t 30 -r DNS_NAMESERVER || { echo -e "${RED}⚠️ 输入超时，使用默认 DNS！${NC}"; DNS_NAMESERVER="$DEFAULT_DNS_NAMESERVER"; }
DNS_NAMESERVER=${DNS_NAMESERVER:-$DEFAULT_DNS_NAMESERVER}

echo "请输入监听地址（默认：$DEFAULT_LISTEN，按回车使用默认值）："
read -t 30 -r LISTEN || { echo -e "${RED}⚠️ 输入超时，使用默认监听地址！${NC}"; LISTEN="$DEFAULT_LISTEN"; }
LISTEN=${LISTEN:-$DEFAULT_LISTEN}

echo "请输入端口（默认推荐可用端口，按回车自动选择）："
read -t 30 -r PORT || { echo -e "${YELLOW}自动选择端口...${NC}"; PORT=$(recommend_port); }
if [ -z "$PORT" ]; then
    PORT=$(recommend_port)
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 无法推荐可用端口，请手动指定！${NC}"
        exit 1
    fi
fi
if ! check_port "$PORT"; then
    echo -e "${RED}⚠️ 端口 $PORT 已被占用，请选择其他端口！${NC}"
    exit 1
fi

echo "请输入 UUID（默认随机生成，按回车使用随机 UUID）："
read -t 30 -r UUID || { echo -e "${YELLOW}生成随机 UUID...${NC}"; UUID=$(cat /proc/sys/kernel/random/uuid); }
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

echo "请输入 X25519 私钥（默认随机生成，按回车生成新密钥）："
read -t 30 -r X25519_PRIVATE || { echo -e "${YELLOW}生成随机 X25519 私钥...${NC}"; }
if [ -z "$X25519_PRIVATE" ]; then
    X25519_OUTPUT=$("${MIHOMO_BIN}" generate vless-x25519 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 生成 X25519 私钥失败！输出：\n${X25519_OUTPUT}${NC}"
        exit 1
    fi
    echo -e "${YELLOW}调试：X25519 输出：\n${X25519_OUTPUT}${NC}"
    X25519_PRIVATE=$(echo "$X25519_OUTPUT" | grep 'PrivateKey:' | sed 's/.*PrivateKey: *//')
    if [ -z "$X25519_PRIVATE" ]; then
        echo -e "${RED}⚠️ 解析 X25519 私钥失败！输出：\n${X25519_OUTPUT}${NC}"
        exit 1
    fi
fi

echo "请输入 ML-KEM-768 种子（默认随机生成，按回车生成新种子）："
read -t 30 -r MLKEM_SEED || { echo -e "${YELLOW}生成随机 ML-KEM-768 种子...${NC}"; }
if [ -z "$MLKEM_SEED" ]; then
    MLKEM_OUTPUT=$("${MIHOMO_BIN}" generate vless-mlkem768 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 生成 ML-KEM-768 种子失败！输出：\n${MLKEM_OUTPUT}${NC}"
        exit 1
    fi
    echo -e "${YELLOW}调试：ML-KEM-768 输出：\n${MLKEM_OUTPUT}${NC}"
    MLKEM_SEED=$(echo "$MLKEM_OUTPUT" | grep 'Seed:' | sed 's/.*Seed: *//')
    if [ -z "$MLKEM_SEED" ]; then
        echo -e "${RED}⚠️ 解析 ML-KEM-768 种子失败！输出：\n${MLKEM_OUTPUT}${NC}"
        exit 1
    fi
fi

echo "请输入 Flow（默认：$DEFAULT_FLOW，按回车使用默认值）："
read -t 30 -r FLOW || { echo -e "${YELLOW}使用默认 Flow...${NC}"; FLOW="$DEFAULT_FLOW"; }
FLOW=${FLOW:-$DEFAULT_FLOW}

DECRYPTION="mlkem768x25519plus.native/xorpub/random.1rtt/600s.${X25519_PRIVATE}.${MLKEM_SEED}"

# 生成完整 YAML 配置
CONFIG_YAML=$(cat <<EOF
log-level: error

dns:
  nameserver:
$(echo "$DNS_NAMESERVER" | tr ',' '\n' | sed 's/^/    - /')

inbounds:
  - name: vless-in-$(date +%s)
    type: vless
    listen: $LISTEN
    port: $PORT
    decryption: $DECRYPTION
    tls: false
    users:
      - username: user1
        uuid: $UUID
        flow: $FLOW
EOF
)

# 检查现有配置文件
if [ -f "${CONFIG_FILE}" ] && yq eval '.dns' "${CONFIG_FILE}" > /dev/null 2>&1; then
    echo -e "${YELLOW}检测到现有配置文件 ${CONFIG_FILE}，是否覆盖 DNS 配置？(y/n，默认 n): ${NC}"
    read -t 30 -r response || { echo -e "${YELLOW}输入超时，默认不覆盖 DNS 配置！${NC}"; response="n"; }
    if [[ "$response" =~ ^[Yy]$ ]]; then
        # 覆盖整个配置文件
        echo "$CONFIG_YAML" > "${CONFIG_FILE}"
        chmod 644 "${CONFIG_FILE}"
        echo -e "${GREEN}✅ 配置已覆盖并保存到 ${CONFIG_FILE}${NC}"
    else
        # 追加 inbounds
        listener_yaml=$(yq eval '.inbounds[0]' - <<< "$CONFIG_YAML" 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo -e "${RED}⚠️ 解析 inbounds 失败！请检查 YAML 格式。${NC}"
            exit 1
        fi
        yq eval ".inbounds += [yamldecode(\"$listener_yaml\")]" -i "${CONFIG_FILE}" 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${RED}⚠️ 追加 Listener 到 ${CONFIG_FILE} 失败！${NC}"
            exit 1
        fi
        echo -e "${GREEN}✅ 新 Listener 已追加到 ${CONFIG_FILE}，保留现有 DNS 配置${NC}"
    fi
else
    # 初次创建配置文件
    echo "$CONFIG_YAML" > "${CONFIG_FILE}"
    chmod 644 "${CONFIG_FILE}"
    echo -e "${GREEN}✅ 新配置文件已创建并保存到 ${CONFIG_FILE}${NC}"
fi

# 输出结果
echo -e "${GREEN}✅ VLESS Encryption 配置已生成：${NC}"
echo "DNS 服务器: $DNS_NAMESERVER"
echo "UUID: $UUID"
echo "Decryption: $DECRYPTION"
echo "监听地址: $LISTEN:$PORT"
echo "Flow: $FLOW"
echo "TLS: disabled"
echo -e "\n生成的 YAML 配置已保存到：${CONFIG_FILE}"
echo -e "${CONFIG_YAML}"

# 打印连接信息（客户端 proxies 单行 YAML）
echo -e "\n${YELLOW}获取服务器 IP 和国家...${NC}"
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

PROXIES_YAML="{ name: \"${NAME}\", type: vless, server: \"${SERVER_IP}\", port: ${PORT}, udp: true, uuid: \"${UUID}\", flow: \"${FLOW}\", packet-encoding: \"xudp\", tls: false, encryption: \"none\", network: \"tcp\", smux: { enabled: false } }"

echo -e "${GREEN}✅ 客户端 Proxies 配置（单行 YAML）：${NC}"
echo "$PROXIES_YAML"