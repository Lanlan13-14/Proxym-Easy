#!/bin/bash

CONF_DIR="/etc/xray/conf.d"
mkdir -p "$CONF_DIR"

# =========================
# 获取编号 100-110
# =========================
get_next_number() {
    for i in {100..110}; do
        if ! ls "$CONF_DIR" | grep -q "^$i-inbound-socks_"; then
            echo $i
            return
        fi
    done
    echo "No available number (100-110)"
    exit 1
}

# =========================
# 获取IP
# =========================
get_ip() {
    local version="$1"
    if [[ "$version" == "4" ]]; then
        curl -s -4 ip.sb
    else
        curl -s -6 ip.sb
    fi
}

# =========================
# 打印 URI
# =========================
print_uri() {
    local file="$1"

    port=$(jq -r '.inbounds[0].port' "$file")
    auth=$(jq -r '.inbounds[0].settings.auth' "$file")
    user=$(jq -r '.inbounds[0].settings.accounts[0].user // empty' "$file")
    pass=$(jq -r '.inbounds[0].settings.accounts[0].pass // empty' "$file")

    ipv4=$(get_ip 4)
    ipv6=$(get_ip 6)

    remark=$port
    read -rp "请输入节点备注（默认 $remark）: " user_remark
    [[ -n "$user_remark" ]] && remark="$user_remark"

    if [[ "$auth" == "password" && -n "$user" ]]; then
        auth_part="$user:$pass@"
    else
        auth_part=""
    fi

    if [[ -n "$ipv4" ]]; then
        echo "socks5://$auth_part$ipv4:$port#$remark"
    elif [[ -n "$ipv6" ]]; then
        echo "socks://$auth_part[$ipv6]:$port#$remark"
    else
        echo "No IP found"
    fi
}

# =========================
# 随机用户名/密码生成
# =========================
gen_user() {
    tr -dc a-z0-9 </dev/urandom | head -c 8
}

gen_pass() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

# =========================
# 添加入站
# =========================
add_inbound() {

    read -rp "设置端口（默认随机 10000-60000）: " port
    [[ -z "$port" ]] && port=$((RANDOM%50000+10000))

    read -rp "监听地址 (默认 0.0.0.0): " listen
    [[ -z "$listen" ]] && listen="0.0.0.0"

    echo "[1] 无认证 (noauth)"
    echo "[2] 用户名密码 (password)"
    read -rp "选择认证方式 [1-2]: " auth_choice

    case $auth_choice in
        1)
            auth="noauth"
            accounts_json=""
            ;;
        2)
            auth="password"

            read -rp "用户名（留空自动生成）: " user
            [[ -z "$user" ]] && user=$(gen_user) && echo "已生成用户名: $user"

            read -rp "密码（留空自动生成）: " pass
            [[ -z "$pass" ]] && pass=$(gen_pass) && echo "已生成密码: $pass"

            accounts_json=$(cat <<EOF
"accounts": [
  {
    "user": "$user",
    "pass": "$pass"
  }
],
EOF
)
            ;;
        *)
            echo "无效选择"
            return
            ;;
    esac

    read -rp "是否开启 UDP (y/n，默认 n): " udp_input
    [[ "$udp_input" == "y" ]] && udp=true || udp=false

    number=$(get_next_number)
    tag="socks-$port-in"
    file="$CONF_DIR/$number-inbound-socks_$port.json"

    cat > "$file" <<EOF
{
  "inbounds": [
    {
      "tag": "$tag",
      "port": $port,
      "listen": "$listen",
      "protocol": "socks",
      "settings": {
        "auth": "$auth",
        $accounts_json
        "udp": $udp
      }
    }
  ]
}
EOF

    echo "生成成功: $file"
    print_uri "$file"
}

# =========================
# 文件选择器
# =========================
select_file_with_exit() {
    mapfile -t files < <(ls "$CONF_DIR"/*socks*.json 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "没有 socks 配置文件" >&2
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

# =========================
# 删除
# =========================
delete_inbound() {
    file=$(select_file_with_exit) || return
    rm -f "$file"
    echo "已删除 $file"
}

# =========================
# 修改
# =========================
modify_inbound() {
    file=$(select_file_with_exit) || return
    vim "$file"
}

# =========================
# 打印URI
# =========================
print_uris() {
    file=$(select_file_with_exit) || return
    print_uri "$file"
}

# =========================
# 主菜单
# =========================
while true; do
    echo
    echo "==== Socks5 入站管理 ===="
    echo "[1] 添加入站"
    echo "[2] 删除入站"
    echo "[3] 修改入站配置"
    echo "[4] 打印 URI"
    echo "[0] 退出"
    read -rp "选择操作 [0-4]: " opt

    case $opt in
        1) add_inbound ;;
        2) delete_inbound ;;
        3) modify_inbound ;;
        4) print_uris ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
done