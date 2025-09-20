#!/bin/bash

# 独立脚本用于生成 mihomo 的 VLESS encryption 配置（仅包含 nameserver 的 DNS 配置）。
# 功能：生成配置并打印客户端 proxies 单行 YAML（匹配本地 Listener）。
# 使用方法：/usr/local/bin/script/vless_encryption.sh [output_file]
# 依赖：yq, ss, curl (for ipinfo), /proc/sys/kernel/random/uuid, mihomo。

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 默认值
MIHOMO_BIN="/usr/local/bin/mihomo"
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

# 收集配置参数
echo -e "${YELLOW}生成 VLESS encryption 配置（包含 DNS nameserver）...${NC}"
echo "请输入 DNS 服务器地址（逗号分隔，示例：8.8.8.8,1.1.1.1，默认：$DEFAULT_DNS_NAMESERVER，按回车使用默认值）："
read -r DNS_NAMESERVER
DNS_NAMESERVER=${DNS_NAMESERVER:-$DEFAULT_DNS_NAMESERVER}

echo "请输入监听地址（默认：$DEFAULT_LISTEN，按回车使用默认值）："
read -r LISTEN
LISTEN=${LISTEN:-$DEFAULT_LISTEN}

echo "请输入端口（默认推荐可用端口，按回车自动选择）："
read -r PORT
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
read -r UUID
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

echo "请输入 X25519 私钥（默认随机生成，按回车生成新密钥）："
read -r X25519_PRIVATE
if [ -z "$X25519_PRIVATE" ]; then
    X25519_OUTPUT=$("${MIHOMO_BIN}" generate vless-x25519 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 生成 X25519 私钥失败！${NC}"
        exit 1
    fi
    X25519_PRIVATE=$(echo "$X25519_OUTPUT" | grep 'Private Key' | awk '{print $3}')
    if [ -z "$X25519_PRIVATE" ]; then
        echo -e "${RED}⚠️ 解析 X25519 私钥失败！${NC}"
        exit 1
    fi
fi

echo "请输入 ML-KEM-768 种子（默认随机生成，按回车生成新种子）："
read -r MLKEM_SEED
if [ -z "$MLKEM_SEED" ]; then
    MLKEM_OUTPUT=$("${MIHOMO_BIN}" generate vless-mlkem768 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 生成 ML-KEM-768 种子失败！${NC}"
        exit 1
    fi
    MLKEM_SEED=$(echo "$MLKEM_OUTPUT" | grep 'Seed' | awk '{print $2}')
    if [ -z "$MLKEM_SEED" ]; then
        echo -e "${RED}⚠️ 解析 ML-KEM-768 种子失败！${NC}"
        exit 1
    fi
fi

echo "请输入 Flow（默认：$DEFAULT_FLOW，按回车使用默认值）："
read -r FLOW
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
    users:
      - username: user1
        uuid: $UUID
        flow: $FLOW
EOF
)

# 输出结果
echo -e "${GREEN}✅ VLESS 配置已生成：${NC}"
echo "DNS 服务器: $DNS_NAMESERVER"
echo "UUID: $UUID"
echo "Decryption: $DECRYPTION"
echo "监听地址: $LISTEN:$PORT"
echo "Flow: $FLOW"
echo -e "\n生成的 YAML 配置：\n${CONFIG_YAML}"

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

# 如果指定了输出文件，则写入
if [ -n "$1" ]; then
    if ! echo "$CONFIG_YAML" > "$1"; then
        echo -e "${RED}⚠️ 写入文件 $1 失败！${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ YAML 配置已保存到 $1${NC}"
else
    echo -e "${YELLOW}提示：可将以上 YAML 配置复制到配置文件，或指定输出文件（例如：$0 output.yaml）${NC}"
fi