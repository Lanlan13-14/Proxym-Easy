#!/bin/bash
CONF_DIR="/etc/xray/conf.d"
mkdir -p "$CONF_DIR"
XRAY_BIN="/etc/xray/bin/xray"
if [[ ! -x "$XRAY_BIN" ]]; then
    echo "错误：找不到 xray 可执行文件：$XRAY_BIN" >&2
    exit 1
fi

# 获取下一个可用编号（60-70）
get_next_number() {
    for i in {60..70}; do
        if ! ls -1 "$CONF_DIR" 2>/dev/null | grep -q "^${i}-inbound-vless_reality_"; then
            echo "$i"
            return
        fi
    done
    echo "No available number (60-70)" >&2
    exit 1
}

# 检查端口是否被占用（任何地址）
check_port() {
    local port="$1"
    ss -tuln 2>/dev/null | grep -q -E "[: ]${port} " && return 1 || return 0
}

# 获取 IPv4 / IPv6
get_ipv4() { curl -s -4 ip.sb; }
get_ipv6() { curl -s -6 ip.sb; }

# 从 xray x25519 输出安全解析私钥/公钥（兼容不同标签）
parse_x25519_keys() {
    local out="$1"
    privateKey=$(echo "$out" | sed -n 's/^[[:space:]]*PrivateKey:[[:space:]]*//Ip' | head -n1)
    if [[ -z "$privateKey" ]]; then
        privateKey=$(echo "$out" | sed -n 's/^[[:space:]]*Private Key:[[:space:]]*//Ip' | head -n1)
    fi
    publicKey=$(echo "$out" | sed -n 's/^[[:space:]]*Password:[[:space:]]*//Ip' | head -n1)
    if [[ -z "$publicKey" ]]; then
        publicKey=$(echo "$out" | sed -n 's/^[[:space:]]*PublicKey:[[:space:]]*//Ip' | head -n1)
    fi
    if [[ -z "$publicKey" ]]; then
        publicKey=$(echo "$out" | sed -n 's/^[[:space:]]*Hash32:[[:space:]]*//Ip' | head -n1)
    fi
}

# 打印 Reality URI（优先 IPv4）
print_uri() {
    local file="$1"

    port=$(jq -r '.inbounds[] | select(.protocol=="vless") | .port' "$file" | head -n1)
    uuid=$(jq -r '.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id' "$file" | head -n1)
    sni=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.serverNames[0]' "$file" | head -n1)
    publicKey=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.publicKey' "$file" | head -n1)
    shortId=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.shortIds[0]' "$file" | head -n1)

    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)

    echo "选择 uTLS 指纹（默认 chrome）"
    echo "[1] chrome"
    echo "[2] firefox"
    echo "[3] safari"
    echo "[4] ios"
    echo "[5] android"
    echo "[6] edge"
    echo "[7] 360"
    echo "[8] qq"
    echo "[9] random"
    read -rp "选择 [1-9]: " fp_sel

    case "$fp_sel" in
        1|"") fp="chrome" ;;
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

    remark=$port
    read -rp "请输入节点备注（默认 $remark）: " user_remark
    [[ -n "$user_remark" ]] && remark="$user_remark"

    if [[ -n "$ipv4" ]]; then
        host="$ipv4"
    elif [[ -n "$ipv6" ]]; then
        host="[$ipv6]"
    else
        echo "无法获取公网 IP"
        return
    fi

    echo "vless://$uuid@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=$fp&type=tcp&headerType=none&pbk=$publicKey&sid=$shortId#$remark"
}

# 查找一个本地未被占用的端口（范围 10000-11000）
get_free_local_port() {
    for p in {10000..11000}; do
        if ss -tuln 2>/dev/null | grep -q -E "[: ]${p} "; then
            continue
        else
            echo "$p"
            return
        fi
    done
    echo "无法找到空闲本地端口" >&2
    exit 1
}

# 添加 Reality 入站（同时生成本地 dokodemo-door 防止流量偷跑）
add_inbound() {
    read -rp "设置端口（默认 443）: " port
    [[ -z "$port" ]] && port=443

    if ! check_port "$port"; then
        echo "端口 $port 已被占用，请输入其他端口"
        read -rp "请输入新的端口: " port
        if ! check_port "$port"; then
            echo "端口仍被占用，退出" >&2
            return 1
        fi
    fi

    read -rp "伪装网站 dest（默认 updates.cdn-apple.com）: " dest
    [[ -z "$dest" ]] && dest="updates.cdn-apple.com"

    read -rp "SNI（默认 updates.cdn-apple.com）: " sni
    [[ -z "$sni" ]] && sni="updates.cdn-apple.com"

    uuid=$("$XRAY_BIN" uuid)

    # 生成 Reality 私钥、公钥（Password 字段即 publicKey）
    keys=$("$XRAY_BIN" x25519 2>/dev/null)
    parse_x25519_keys "$keys"

    if [[ -z "$privateKey" || -z "$publicKey" ]]; then
        echo "无法从 xray x25519 获取密钥，请检查 xray 可执行文件输出。" >&2
        echo "x25519 输出如下：" >&2
        echo "$keys" >&2
        return 1
    fi

    # 生成 shortId（8 位十六进制）
    shortId=$(openssl rand -hex 8)

    number=$(get_next_number)
    tag="vless-reality-$port-in"
    file="$CONF_DIR/$number-inbound-vless_reality_$port.json"

    # 为 dokodemo-door 找一个本地端口并写入配置，Reality 的 dest 指向本地 dokodemo
    dokodemo_port=$(get_free_local_port)

    cat > "$file" <<EOF2
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "tag": "dokodemo-in",
      "port": $dokodemo_port,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "$dest",
        "port": 443,
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "tls"
        ],
        "routeOnly": true
      }
    },
    {
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "tag": "$tag",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "127.0.0.1:$dokodemo_port",
          "xver": 0,
          "serverNames": ["$sni"],
          "privateKey": "$privateKey",
          "publicKey": "$publicKey",
          "shortIds": ["$shortId"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": [
          "dokodemo-in"
        ],
        "domain": [
          "$dest"
        ],
        "outboundTag": "direct"
      },
      {
        "inboundTag": [
          "dokodemo-in"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF2

    echo "生成成功: $file"
    echo "================ Reality 关键信息 ================"
    echo "UUID:       $uuid"
    echo "PrivateKey: $privateKey"
    echo "PublicKey:  $publicKey"
    echo "ShortId:    $shortId"
    echo "SNI:        $sni"
    echo "Dest:       $dest:443"
    echo "dokodemo 本地端口: $dokodemo_port"
    echo "=================================================="
    print_uri "$file"
}

# 统一文件选择器（stderr/stdout 分离）
select_file_with_exit() {
    mapfile -t files < <(ls -1 "$CONF_DIR"/*-inbound-vless_reality_*.json 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "没有 vless reality 配置文件" >&2
        return 1
    fi

    echo "请选择文件 (输入 0 退出)：" >&2
    for i in "${!files[@]}"; do
        echo "[$((i+1))] ${files[$i]}" >&2
    done

    while true; do
        read -rp "选择 [0-${#files[@]}]: " sel
        if [[ "$sel" =~ ^[0-9]+$ ]]; then
            if [[ "$sel" -eq 0 ]]; then
                return 1
            elif [[ "$sel" -ge 1 && "$sel" -le "${#files[@]}" ]]; then
                printf "%s" "${files[$((sel-1))]}"
                return 0
            fi
        fi
        echo "无效选择，请重新输入" >&2
    done
}

delete_inbound() {
    file=$(select_file_with_exit) || return
    rm -f "$file"
    echo "已删除 $file"
}

reset_uuid() {
    file=$(select_file_with_exit) || return
    newuuid=$("$XRAY_BIN" uuid)
    tmpfile="$file.tmp"
    jq --arg new "$newuuid" '(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) = $new' "$file" > "$tmpfile" && mv "$tmpfile" "$file"
    echo "UUID 已重置"
    print_uri "$file"
}

modify_inbound() {
    file=$(select_file_with_exit) || return
    ${EDITOR:-vim} "$file"
}

print_uris() {
    file=$(select_file_with_exit) || return
    print_uri "$file"
}

while true; do
    echo
    echo "==== VLESS Reality 入站管理 ===="
    echo "[1] 添加入站"
    echo "[2] 删除入站"
    echo "[3] 重置 UUID"
    echo "[4] 修改入站配置"
    echo "[5] 打印 URI"
    echo "[6] 退出"
    read -rp "选择操作 [1-6]: " opt

    case $opt in
        1) add_inbound ;;
        2) delete_inbound ;;
        3) reset_uuid ;;
        4) modify_inbound ;;
        5) print_uris ;;
        6) exit 0 ;;
        *) echo "无效选择" ;;
    esac
done