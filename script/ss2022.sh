#!/bin/bash
CONF_DIR="/etc/xray/conf.d"
mkdir -p "$CONF_DIR"

get_next_number() {
    for i in {80..90}; do
        if ! ls "$CONF_DIR" | grep -q "^$i-inbound-ss2022_"; then
            echo $i
            return
        fi
    done
    echo "No available number (80-90)"
    exit 1
}

generate_key() {
    local method="$1"
    if [[ "$method" == "2022-blake3-aes-128-gcm" ]]; then
        openssl rand -base64 16
    else
        openssl rand -base64 32
    fi
}

get_ip() {
    local version="$1"
    if [[ "$version" == "4" ]]; then
        curl -s -4 ip.sb
    else
        curl -s -6 ip.sb
    fi
}

print_uri() {
    local file="$1"
    port=$(jq -r '.inbounds[0].port' "$file")
    method=$(jq -r '.inbounds[0].settings.method' "$file")
    password=$(jq -r '.inbounds[0].settings.password' "$file")

    ipv4=$(get_ip 4)
    ipv6=$(get_ip 6)

    remark=$port
    read -rp "请输入节点备注（默认 $remark）: " user_remark
    [[ -n "$user_remark" ]] && remark="$user_remark"

    if [[ -n "$ipv4" ]]; then
        echo "ss://$method:$password@$ipv4:$port#$remark"
    elif [[ -n "$ipv6" ]]; then
        echo "ss://$method:$password@[$ipv6]:$port#$remark"
    else
        echo "No IP found"
    fi
}

add_inbound() {
    echo "[1] 2022-blake3-aes-128-gcm"
    echo "[2] 2022-blake3-aes-256-gcm"
    echo "[3] 2022-blake3-chacha20-poly1305"
    read -rp "选择加密方式 [1-3]: " choice
    case $choice in
        1) method="2022-blake3-aes-128-gcm" ;;
        2) method="2022-blake3-aes-256-gcm" ;;
        3) method="2022-blake3-chacha20-poly1305" ;;
        *) echo "无效选择"; return ;;
    esac

    read -rp "设置端口（默认随机 10000-60000）: " port
    [[ -z "$port" ]] && port=$((RANDOM%50000+10000))

    read -rp "监听地址 (默认 0.0.0.0): " listen
    [[ -z "$listen" ]] && listen="0.0.0.0"

    number=$(get_next_number)
    key=$(generate_key "$method")
    tag="ss2022-$port-in"
    file="$CONF_DIR/$number-inbound-ss2022_$port.json"

    cat > "$file" <<EOF2
{
  "inbounds": [
    {
      "tag": "$tag",
      "port": $port,
      "listen": "$listen",
      "protocol": "shadowsocks",
      "settings": {
        "method": "$method",
        "password": "$key",
        "network": "tcp,udp"
      }
    }
  ]
}
EOF2

    echo "生成成功: $file"
    print_uri "$file"
}

# ============================
# 统一文件选择器（stderr/stdout 分离）
# ============================
select_file_with_exit() {
    mapfile -t files < <(ls "$CONF_DIR"/*ss2022*.json 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "没有 ss2022 配置文件" >&2
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

reset_password() {
    file=$(select_file_with_exit) || return
    method=$(jq -r '.inbounds[0].settings.method' "$file")
    newkey=$(generate_key "$method")
    jq ".inbounds[0].settings.password=\"$newkey\"" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    echo "密码已重置"
    print_uri "$file"
}

modify_inbound() {
    file=$(select_file_with_exit) || return
    vim "$file"
}

print_uris() {
    file=$(select_file_with_exit) || return
    print_uri "$file"
}

while true; do
    echo
    echo "==== SS2022 入站管理 ===="
    echo "[1] 添加入站"
    echo "[2] 删除入站"
    echo "[3] 重置密码"
    echo "[4] 修改入站配置"
    echo "[5] 打印 URI"
    echo "[6] 退出"
    read -rp "选择操作 [1-6]: " opt

    case $opt in
        1) add_inbound ;;
        2) delete_inbound ;;
        3) reset_password ;;
        4) modify_inbound ;;
        5) print_uris ;;
        6) exit 0 ;;
        *) echo "无效选择" ;;
    esac
done
