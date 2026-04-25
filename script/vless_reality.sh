#!/bin/bash
CONF_DIR="/etc/xray/conf.d"
mkdir -p "$CONF_DIR"

# 固定 xray 可执行文件路径
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

# 在指定范围内随机寻找未被占用的端口（尝试若干次后顺序扫描）
find_random_free_port_in_range() {
    local low="$1"
    local high="$2"
    local attempts=50
    local p
    for _ in $(seq 1 $attempts); do
        p=$((RANDOM%(high-low+1)+low))
        if check_port "$p"; then
            echo "$p"
            return 0
        fi
    done
    for p in $(seq "$low" "$high"); do
        if check_port "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# 获取 IPv4 / IPv6
get_ipv4() { curl -s -4 ip.sb; }
get_ipv6() { curl -s -6 ip.sb; }

# 解析 x25519 输出，兼容 PrivateKey/Private Key 和 Password/PublicKey/Hash32 标签
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

# 生成至少 5 个 shortIds（4 个随机 + 固定）
generate_shortids_array() {
    local sids=()
    for i in {1..4}; do
        sids+=("$(openssl rand -hex 8)")
    done
    sids+=("0123456789abcdef")
    # 返回数组（通过全局变量）
    SHORTIDS_ARRAY=("${sids[@]}")
    # 生成 JSON 数组字符串
    local out=""
    for sid in "${sids[@]}"; do
        if [[ -z "$out" ]]; then
            out="\"$sid\""
        else
            out="$out, \"$sid\""
        fi
    done
    SHORTIDS_JSON="$out"
}

# 打印 Reality URI（使用 dokodemo 外部端口作为客户端连接端口）
print_uri() {
    local file="$1"

    # 获取 dokodemo 外部监听端口（客户端连接端口）
    dokodemo_port=$(jq -r '.inbounds[] | select(.protocol=="dokodemo-door") | .port' "$file" | head -n1)
    # 兼容旧配置：如果没有 dokodemo，退回到 vless 的外部端口（不常见）
    if [[ -z "$dokodemo_port" || "$dokodemo_port" == "null" ]]; then
        dokodemo_port=$(jq -r '.inbounds[] | select(.protocol=="vless") | .port' "$file" | head -n1)
    fi

    # 获取 uuid, sni, publicKey, shortIds 列表
    uuid=$(jq -r '.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id' "$file" | head -n1)
    sni=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.serverNames[0]' "$file" | head -n1)
    publicKey=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.publicKey' "$file" | head -n1)
    mapfile -t shortids_from_file < <(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.shortIds[]' "$file" 2>/dev/null)

    if [[ ${#shortids_from_file[@]} -eq 0 ]]; then
        echo "配置中未找到 shortIds" >&2
        return
    fi

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

    remark="$dokodemo_port"
    read -rp "请输入节点备注（默认 $remark）: " user_remark
    [[ -n "$user_remark" ]] && remark="$user_remark"

    # 选择 shortId 使用方式：单个随机 or 全部
    echo "shortId 使用方式："
    echo "[1] 随机使用一个 shortId（URI 中只包含一个）"
    echo "[2] 使用全部 shortIds（URI 中以逗号分隔）"
    read -rp "选择 [1-2]（默认 1）: " sid_mode
    if [[ "$sid_mode" != "2" ]]; then
        # 随机选一个
        idx=$((RANDOM % ${#shortids_from_file[@]}))
        sid_for_uri="${shortids_from_file[$idx]}"
    else
        # 全部，用逗号连接
        sid_for_uri=$(IFS=, ; echo "${shortids_from_file[*]}")
    fi

    if [[ -n "$ipv4" ]]; then
        host="$ipv4"
    elif [[ -n "$ipv6" ]]; then
        host="[$ipv6]"
    else
        echo "无法获取公网 IP"
        return
    fi

    # 注意：URI 中 shortId 用 sid= 或 sid=... 这里使用 sid= 并以逗号分隔多个 shortId（用户要求）
    echo "vless://$uuid@$host:$dokodemo_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=$fp&type=tcp&headerType=none&pbk=$publicKey&sid=$sid_for_uri#$remark"
}

# 生成配置（Reality 端口随机从 10000-60000 选一个未被占用；dokodemo 默认监听 443）
add_inbound() {
    # dokodemo 外部监听端口（默认 443）
    read -rp "外部 dokodemo 监听端口（默认 443）: " dokodemo_listen
    [[ -z "$dokodemo_listen" ]] && dokodemo_listen=443

    if ! check_port "$dokodemo_listen"; then
        echo "端口 $dokodemo_listen 已被占用，请输入其他端口"
        read -rp "请输入新的 dokodemo 监听端口: " dokodemo_listen
        if ! check_port "$dokodemo_listen"; then
            echo "端口仍被占用，退出" >&2
            return 1
        fi
    fi

    # 自动随机选择内部 reality 监听端口（范围 10000-60000）
    echo "正在从 10000-60000 随机选择一个未被占用的内部 reality 端口..."
    reality_port=$(find_random_free_port_in_range 10000 60000)
    if [[ -z "$reality_port" ]]; then
        echo "未能在 10000-60000 范围内找到可用端口，退出" >&2
        return 1
    fi
    echo "选定内部 reality 端口: $reality_port"

    # 伪装网站 dest（用于 dokodemo 的目标域名），默认 speed.cloudflare.com
    read -rp "伪装网站 dest（用于路由，默认 speed.cloudflare.com）: " dest
    [[ -z "$dest" ]] && dest="speed.cloudflare.com"

    # SNI（serverNames），默认与 dest 相同
    read -rp "SNI（默认与 dest 相同）: " sni
    [[ -z "$sni" ]] && sni="$dest"

    # 客户端连接端口（默认与 dokodemo_listen 相同）
    read -rp "客户端连接端口（默认与 dokodemo 监听端口相同）: " client_port
    [[ -z "$client_port" ]] && client_port="$dokodemo_listen"

    if ! check_port "$client_port"; then
        echo "警告: 客户端连接端口 $client_port 可能被占用。"
    fi

    # 生成 uuid
    uuid=$("$XRAY_BIN" uuid)

    # 生成 x25519 密钥对
    keys=$("$XRAY_BIN" x25519 2>/dev/null)
    parse_x25519_keys "$keys"

    if [[ -z "$privateKey" || -z "$publicKey" ]]; then
        echo "无法从 xray x25519 获取密钥，请检查 xray 可执行文件输出。" >&2
        echo "x25519 输出如下：" >&2
        echo "$keys" >&2
        return 1
    fi

    # 生成至少 5 个 shortIds（并保存数组与 JSON）
    generate_shortids_array
    # SHORTIDS_ARRAY 和 SHORTIDS_JSON 已被设置

    number=$(get_next_number)
    file="$CONF_DIR/$number-inbound-vless_reality_${client_port}.json"
    tag="vless-reality-${client_port}-in"

    # 生成配置（不写 log/outbounds，保留主配置）
    cat > "$file" <<EOF
{
  "inbounds": [
    {
      "tag": "dokodemo-in",
      "port": $dokodemo_listen,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": $reality_port,
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
      "listen": "127.0.0.1",
      "port": $reality_port,
      "protocol": "vless",
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
          "dest": "$dest:443",
          "serverNames": [
            "$sni"
          ],
          "privateKey": "$privateKey",
          "publicKey": "$publicKey",
          "shortIds": [
            $SHORTIDS_JSON
          ]
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
EOF

    echo "生成成功: $file"
    echo "================ Reality 关键信息 ================"
    echo "UUID:       $uuid"
    echo "PrivateKey: $privateKey"
    echo "PublicKey:  $publicKey"
    echo "ShortIds:   ${SHORTIDS_ARRAY[*]}"
    echo "SNI:        $sni"
    echo "Dest:       $dest:443"
    echo "dokodemo listen: $dokodemo_listen -> points to 127.0.0.1:$reality_port"
    echo "客户端连接端口: $client_port"
    echo "文件: $file"
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

# 主菜单
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