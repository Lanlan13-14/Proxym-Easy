#!/bin/bash

# 独立脚本用于生成 mihomo 的 VLESS encryption 配置（仅包含 nameserver 的 DNS 配置）。
# 功能：
# - 生成 VLESS encryption Listener，支持自定义监听地址、端口、UUID、X25519 私钥、ML-KEM-768 种子、Flow。
# - 支持简化的 DNS 配置（仅 nameserver），参考 https://wiki.metacubex.one/config/dns/。
# - 未输入时随机生成默认值（DNS nameserver 默认：8.8.8.8,1.1.1.1）。
# - 自动检查端口占用并推荐可用端口。
# - 输出完整 YAML 配置（log-level: error, dns, inbounds）到标准输出或指定文件。
# 使用方法：./generate_vless_listener.sh [output_file]
# 依赖：yq, ss, /proc/sys/kernel/random/uuid, mihomo（用于生成密钥）。

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

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
if ! command -v "${MIHOMO_BIN}" &> /dev/null; then
    echo -e "${RED}⚠️ mihomo 未安装，请先安装 mihomo！${NC}"
    exit 1
fi
if ! command -v yq &> /dev/null; then
    echo -e "${RED}⚠️ yq 未安装，请安装 yq！${NC}"
    exit 1
fi
if ! command -v ss &> /dev/null; then
    echo -e "${RED}⚠️ ss 未安装，请安装 iproute2 或 net-tools！${NC}"
    exit 1
fi

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
    X25519_OUTPUT=$("${MIHOMO_BIN}" generate vless-x25519)
    X25519_PRIVATE=$(echo "$X25519_OUTPUT" | grep 'Private Key' | awk '{print $3}')
fi

echo "请输入 ML-KEM-768 种子（默认随机生成，按回车生成新种子）："
read -r MLKEM_SEED
if [ -z "$MLKEM_SEED" ]; then
    MLKEM_OUTPUT=$("${MIHOMO_BIN}" generate vless-mlkem768)
    MLKEM_SEED=$(echo "$MLKEM_OUTPUT" | grep 'Seed' | awk '{print $2}')
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

# 如果指定了输出文件，则写入
if [ -n "$1" ]; then
    echo "$CONFIG_YAML" > "$1"
    echo -e "${GREEN}✅ YAML 配置已保存到 $1${NC}"
else
    echo -e "${YELLOW}提示：可将以上 YAML 配置复制到配置文件，或指定输出文件（例如：$0 output.yaml）${NC}"
fi
