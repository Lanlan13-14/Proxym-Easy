#!/bin/bash
# VLESS+Reality 配置管理工具
# 功能: 1.生成配置 2.查看URI 3.重置UUID
CONFIG_DIR="/etc/xray"
URI_FILE="/etc/proxym-easy/uri.json"
mkdir -p "$CONFIG_DIR"
mkdir -p "$(dirname "$URI_FILE")"

# 默认 SNI
DEFAULT_SNI="mensura.cdn-apple.com"

# 获取本机 IPv4（优先）
get_ipv4() {
    ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1
}

# 生成数字编号
get_existing_numbers() {
    local nums=()
    for f in "$CONFIG_DIR"/*.json; do
        [[ -e "$f" ]] || continue
        name=$(basename "$f" .json)
        num=$(echo "$name" | grep -o '^[0-9]\+')
        nums+=("$num")
    done
    echo "${nums[@]}"
}

choose_number() {
    local existing=($(get_existing_numbers))
    while true; do
        read -rp "请输入数字编号（不能与现有重复，默认最大+1）: " NUM_INPUT
        if [[ -z "$NUM_INPUT" ]]; then
            max=0
            for n in "${existing[@]}"; do ((n>max)) && max=$n; done
            NUM=$((max+1))
            break
        fi
        if ! [[ "$NUM_INPUT" =~ ^[0-9]+$ ]]; then
            echo "❌ 必须输入正整数"; continue
        fi
        duplicate=false
        for n in "${existing[@]}"; do [[ "$NUM_INPUT" -eq "$n" ]] && duplicate=true && break; done
        if $duplicate; then echo "❌ 编号已存在"; continue; fi
        NUM=$NUM_INPUT
        break
    done
}

# 生成配置
generate_config() {
    choose_number
    read -rp "请输入监听端口 (默认443): " PORT
    PORT=${PORT:-443}
    read -rp "请输入伪装域名/SNI (默认 $DEFAULT_SNI): " SNI
    SNI=${SNI:-$DEFAULT_SNI}
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PUB_KEY=$(head -c 32 /dev/urandom | xxd -p)
    SHORTID="shortid1"
    OUT_FILE="$CONFIG_DIR/${NUM}-vless-${PORT}.json"

    cat > "$OUT_FILE" <<EOF
{
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "email": "user@example.com"
          }
        ],
        "decryption": "none",
        "fallbacks": []
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": "$PUB_KEY",
          "shortIds": ["$SHORTID"],
          "serverName": "$SNI"
        }
      }
    }
  ]
}
EOF
    echo "✅ 配置生成完成: $OUT_FILE"
    generate_uri "$OUT_FILE" "$NUM"
}

# 生成 URI 并保存
generate_uri() {
    local file="$1"
    local num="$2"
    local ip=$(get_ipv4)
    local json=$(cat "$file")
    local uuid=$(echo "$json" | grep '"id":' | head -n1 | awk -F'"' '{print $4}')
    local pub=$(echo "$json" | grep '"show":' | head -n1 | awk -F'"' '{print $4}')
    local port=$(echo "$json" | grep '"port":' | head -n1 | awk -F'[:,]' '{gsub(/ /,"",$2); print $2}')
    local sni=$(echo "$json" | grep '"serverName":' | head -n1 | awk -F'"' '{print $4}')
    
    # 节点名称 tag: 国家缩写+城市-数字（简单用本机IP替代地区）
    COUNTRY="CN"
    CITY=$(curl -s https://ipapi.co/$ip/city || echo "Unknown")
    NODE_NAME="${COUNTRY}${CITY}-${num}"
    
    # URI 拼接
    URI="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&encryption=none&pbk=${pub}&sni=${sni}#${NODE_NAME}"
    URI_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$URI'''))")
    
    # 保存
    if [[ ! -f "$URI_FILE" ]]; then echo "[]" > "$URI_FILE"; fi
    jq ". += [\"$URI\"]" "$URI_FILE" > "$URI_FILE.tmp" && mv "$URI_FILE.tmp" "$URI_FILE"
    echo "✅ URI 已生成并保存: $URI_FILE"
}

# 查看所有 URI
view_uri() {
    if [[ ! -f "$URI_FILE" ]]; then
        echo "❌ URI 文件不存在"
        return
    fi
    echo "==== 已生成 URI ===="
    cat "$URI_FILE" | jq -r '.[]'
}

# 重置 UUID
reset_uuid() {
    echo "可用配置文件:"
    ls "$CONFIG_DIR"/*.json | nl
    read -rp "选择文件序号重置UUID: " idx
    file=$(ls "$CONFIG_DIR"/*.json | sed -n "${idx}p")
    if [[ -z "$file" ]]; then echo "❌ 文件不存在"; return; fi
    new_uuid=$(cat /proc/sys/kernel/random/uuid)
    sed -i "s/\"id\": \".*\"/\"id\": \"$new_uuid\"/" "$file"
    # 更新 URI
    num=$(basename "$file" | grep -o '^[0-9]\+')
    generate_uri "$file" "$num"
    echo "✅ UUID 已重置: $new_uuid"
}

# 菜单
while true; do
    echo "==== VLESS+Reality 管理 ===="
    echo "1. 生成配置"
    echo "2. 查看 URI"
    echo "3. 重置 UUID"
    echo "0. 退出"
    read -rp "选择操作: " choice
    case $choice in
        1) generate_config ;;
        2) view_uri ;;
        3) reset_uuid ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项" ;;
    esac
done