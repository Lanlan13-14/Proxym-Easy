#!/bin/bash

XRAY_BIN="/etc/xray/bin/xray"
CONF_DIR="/etc/xray/conf.d"

mkdir -p "$CONF_DIR"

# ===== 依赖检查 =====
command -v jq >/dev/null || { echo "请安装 jq"; exit 1; }
command -v openssl >/dev/null || { echo "请安装 openssl"; exit 1; }

# ===== 获取编号 =====
get_next_number() {
    for i in {60..70}; do
        if ! ls "$CONF_DIR" 2>/dev/null | grep -q "^$i-inbound-reality-advanced_"; then
            echo $i
            return
        fi
    done
    echo "❌ 没有可用编号 (60-70)"
    exit 1
}

# ===== 检查端口 =====
check_port() {
    ss -tuln | grep -q ":$1 " && return 1 || return 0
}

# ===== 获取 IP =====
get_ipv4() { curl -s -4 --max-time 3 ip.sb; }
get_ipv6() { curl -s -6 --max-time 3 ip.sb; }

# ===== 兼容所有版本的密钥解析（核心修复） =====
gen_keys() {
    keys=$($XRAY_BIN x25519)

    # 兼容两种格式：
    # 1. Private key / Public key
    # 2. PrivateKey / Password

    privateKey=$(echo "$keys" | grep -iE 'PrivateKey|Private key' | head -n1 | awk '{print $2}')
    publicKey=$(echo "$keys" | grep -iE 'Public key|Password' | head -n1 | awk '{print $2}')

    if [[ -z "$privateKey" || -z "$publicKey" ]]; then
        echo "❌ Reality 密钥解析失败"
        echo "$keys"
        exit 1
    fi
}

# ===== 打印 URI =====
print_uri() {
    local file="$1"

    port=$(jq -r '.inbounds[1].port' "$file")
    uuid=$(jq -r '.inbounds[1].settings.clients[0].id' "$file")
    sni=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0]' "$file")
    shortId=$(jq -r '.inbounds[1].streamSettings.realitySettings.shortIds[0]' "$file")

    # ⚠ 公钥直接从生成时变量拿（保证匹配）
    pbk="$PUBLIC_KEY"

    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)

    echo "选择指纹（默认 chrome）"
    echo "[1] chrome [2] firefox [3] safari [4] ios [5] android [6] edge [7] 360 [8] qq [9] random"
    read -rp "选择: " fp_sel

    case "$fp_sel" in
        2) fp="firefox" ;;
        3) fp="safari" ;;
        4) fp="ios" ;;
        5) fp="android" ;;
        6) fp="edge" ;;
        7) fp="360" ;;
        8) fp="qq" ;;
        9) fp="random" ;;
        *) fp="chrome" ;;
    esac

    if [[ -n "$ipv4" ]]; then
        host="$ipv4"
    elif [[ -n "$ipv6" ]]; then
        host="[$ipv6]"
    else
        echo "❌ 无法获取 IP"
        return
    fi

    echo
    echo "======== Reality URI ========"
    echo "vless://$uuid@$host:$port?encryption=none&security=reality&sni=$sni&fp=$fp&type=tcp&pbk=$pbk&sid=$shortId"
    echo "============================"
}

# ===== 添加 =====
add_inbound() {

    # 主端口
    while true; do
        read -rp "Reality端口（默认443）: " port
        [[ -z "$port" ]] && port=443

        if check_port "$port"; then
            break
        else
            echo "❌ 端口被占用"
        fi
    done

    # 内部端口
    while true; do
        read -rp "内部转发端口（默认4431）: " inner_port
        [[ -z "$inner_port" ]] && inner_port=4431

        if check_port "$inner_port"; then
            break
        else
            echo "❌ 端口被占用"
        fi
    done

    read -rp "伪装域名（默认 speed.cloudflare.com）: " dest
    [[ -z "$dest" ]] && dest="speed.cloudflare.com"

    uuid=$($XRAY_BIN uuid)

    gen_keys
    PRIVATE_KEY="$privateKey"
    PUBLIC_KEY="$publicKey"

    shortId=$(openssl rand -hex 8)

    number=$(get_next_number)
    file="$CONF_DIR/$number-inbound-reality-advanced_$port.json"

    cat > "$file" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "tag": "dokodemo-in",
      "port": $inner_port,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "$dest",
        "port": 443,
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["tls"],
        "routeOnly": true
      }
    },
    {
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$uuid" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "127.0.0.1:$inner_port",
          "serverNames": ["$dest"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$shortId"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http","tls","quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": ["dokodemo-in"],
        "domain": ["$dest"],
        "outboundTag": "direct"
      },
      {
        "inboundTag": ["dokodemo-in"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

    echo
    echo "✅ 创建成功: $file"
    echo "UUID:       $uuid"
    echo "PrivateKey: $PRIVATE_KEY"
    echo "PublicKey:  $PUBLIC_KEY"
    echo "ShortId:    $shortId"

    print_uri "$file"
}

# ===== 主菜单 =====
while true; do
    echo
    echo "==== Reality高级防偷跑管理 ===="
    echo "[1] 添加"
    echo "[2] 退出"

    read -rp "选择: " opt

    case $opt in
        1) add_inbound ;;
        2) exit 0 ;;
        *) echo "无效输入" ;;
    esac
done