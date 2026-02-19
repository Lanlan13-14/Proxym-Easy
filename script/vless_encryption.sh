#!/bin/bash
CONF_DIR="/etc/xray/conf.d"
XRAY_BIN="/etc/xray/bin/xray"
mkdir -p "$CONF_DIR"

getnextnumber() {
    for i in {40..50}; do
        if ! ls "$CONF_DIR" 2>/dev/null | grep -q "^$i-inbound-vlessenc_"; then
            echo $i
            return
        fi
    done
    echo "No available number (40-50)"
    exit 1
}

check_port() {
    local port="$1"
    ss -tuln | grep -q ":$port " && return 1 || return 0
}

get_ipv4() { curl -s -4 ip.sb; }
get_ipv6() { curl -s -6 ip.sb; }

generatemlkemparams() {
    local rtt_mode="$1"
    local appearance="$2"
    local kex_type="$3"

    if [[ "$rtt_mode" == "0rtt" ]]; then
        ticket="600s"
    else
        ticket="0s"
    fi

    if [[ "$kex_type" == "x25519" ]]; then
        out=$("$XRAY_BIN" x25519)
        priv=$(echo "$out" | awk -F':' '/PrivateKey/ {gsub(/ /,"",$2);print $2}')
        pwd=$( echo "$out" | awk -F':' '/Password/   {gsub(/ /,"",$2);print $2}')
        decryption="mlkem768x25519plus.${appearance}.${ticket}.${priv}"
        encryption="mlkem768x25519plus.${appearance}.${rtt_mode}.${pwd}"
    else
        out=$("$XRAY_BIN" mlkem768)
        seed=$(  echo "$out" | awk -F':' '/Seed/   {gsub(/ /,"",$2);print $2}')
        client=$(echo "$out" | awk -F':' '/Client/ {gsub(/ /,"",$2);print $2}')
        decryption="mlkem768x25519plus.${appearance}.${ticket}.${seed}"
        encryption="mlkem768x25519plus.${appearance}.${rtt_mode}.${client}"
    fi

    echo "$decryption" "$encryption"
}

select_fingerprint() {
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
        2) echo "firefox" ;;
        3) echo "safari" ;;
        4) echo "ios" ;;
        5) echo "android" ;;
        6) echo "edge" ;;
        7) echo "360" ;;
        8) echo "qq" ;;
        9) echo "random" ;;
        *) echo "chrome" ;;
    esac
}

print_uri() {
    local file="$1"

    port=$(jq -r '.inbounds[0].port' "$file")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$file")
    encryption=$(jq -r '.inbounds[0].encryption' "$file")
    network=$(jq -r '.inbounds[0].streamSettings.network // "tcp"' "$file")
    security=$(jq -r '.inbounds[0].streamSettings.security // "none"' "$file")

    host=""
    path=""
    fingerprint=""
    domain=""

    if [[ "$network" == "ws" ]]; then
        path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // ""' "$file")
        host=$(jq -r '.inbounds[0].streamSettings.wsSettings.headers.Host // ""' "$file")
    fi

    if [[ "$security" == "tls" ]]; then
        fingerprint=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint // ""' "$file")
        cert_file=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile // ""' "$file")
        domain=$(basename "$(dirname "$cert_file")")
    fi

    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)
    [[ -n "$ipv4" ]] && hostip="$ipv4" || hostip="[$ipv6]"

    uri_params="type=${network}&encryption=${encryption}"
    [[ -n "$host" ]] && uri_params="${uri_params}&host=${host}"
    [[ -n "$path" ]] && uri_params="${uri_params}&path=${path}"

    if [[ "$security" == "tls" ]]; then
        uri_params="${uri_params}&security=tls&sni=${domain}&fp=${fingerprint}"
    else
        uri_params="${uri_params}&security=none"
    fi

    # ⭐ 只在打印 URI 时询问节点名，不保存
    read -rp "节点名称（默认 $port）: " nodename
    [[ -z "$nodename" ]] && nodename="$port"

    echo "vless://$uuid@$hostip:$port?${uri_params}#${nodename}"
}

selectfilewith_exit() {
    mapfile -t files < <(ls "$CONF_DIR"/*-inbound-vlessenc_*.json 2>/dev/null)
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "没有 vless enc 配置文件" >&2
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

add_inbound() {
    while :; do
        port=$((RANDOM % 50000 + 10000))
        check_port "$port" && break
    done

    echo "选择密钥交换算法："
    echo "[1] X25519"
    echo "[2] MLKEM768（默认，高安全）"
    read -rp "选择 [1-2]: " ksel
    [[ "$ksel" == "1" ]] && kex_type="x25519" || kex_type="mlkem768"

    echo "选择外观模式："
    echo "[1] native"
    echo "[2] xorpub"
    echo "[3] random（默认）"
    read -rp "选择 [1-3]: " aesel
    case "$aesel" in
        1) appearance="native" ;;
        2) appearance="xorpub" ;;
        *) appearance="random" ;;
    esac

    echo "RTT 模式："
    echo "[1] 1-RTT"
    echo "[2] 0-RTT（默认，高安全）"
    read -rp "选择 [1-2]: " rsel
    [[ "$rsel" == "1" ]] && rtt_mode="1rtt" || rtt_mode="0rtt"

    echo "选择传输协议："
    echo "[1] tcp"
    echo "[2] ws"
    read -rp "选择 [1-2]（默认 tcp）: " nsel
    [[ "$nsel" == "2" ]] && network="ws" || network="tcp"

    domain=""
    host=""
    path="/"
    fingerprint="chrome"

    if [[ "$network" == "ws" ]]; then
        read -rp "WS 路径（默认 /）： " path_in
        [[ -n "$path_in" ]] && path="$path_in"
        read -rp "WS Host（可空）： " host_in
        [[ -n "$host_in" ]] && host="$host_in"

        echo "是否启用 TLS？"
        echo "[1] 不启用"
        echo "[2] 启用 TLS"
        read -rp "选择 [1-2]（默认 1）: " tsel
        if [[ "$tsel" == "2" ]]; then
            read -rp "域名（用于证书路径和 SNI）: " domain
            fingerprint=$(select_fingerprint)
        fi
    fi

    uuid=$("$XRAY_BIN" uuid)
    read decryption encryption < <(generatemlkemparams "$rtt_mode" "$appearance" "$kex_type")

    number=$(getnextnumber)
    file="$CONF_DIR/$number-inbound-vlessenc_$port.json"
    tag="vless-enc-$port-in"
    listen="0.0.0.0"

    if [[ -n "$domain" ]]; then
        cert_path="/etc/ssl/acme/$domain/fullchain.pem"
        key_path="/etc/ssl/acme/$domain/privkey.key"

        tls_settings=$(cat <<EOF
{
  "certificates":[{"certificateFile":"$cert_path","keyFile":"$key_path"}],
  "fingerprint":"$fingerprint"
}
EOF
)

        if [[ "$network" == "ws" ]]; then
            ws_settings=$(cat <<EOF
{"path":"$path","headers":{"Host":"$host"}}
EOF
)
            stream_settings=$(cat <<EOF
{"network":"ws","security":"tls","tlsSettings":$tls_settings,"wsSettings":$ws_settings}
EOF
)
        else
            stream_settings=$(cat <<EOF
{"network":"tcp","security":"tls","tlsSettings":$tls_settings}
EOF
)
        fi
    else
        if [[ "$network" == "ws" ]]; then
            ws_settings=$(cat <<EOF
{"path":"$path","headers":{"Host":"$host"}}
EOF
)
            stream_settings=$(cat <<EOF
{"network":"ws","security":"none","wsSettings":$ws_settings}
EOF
)
        else
            stream_settings='{"network":"tcp","security":"none"}'
        fi
    fi

    cat > "$file" <<EOF
{
  "inbounds":[
    {
      "tag":"$tag",
      "listen":"$listen",
      "port":$port,
      "protocol":"vless",
      "settings":{"clients":[{"id":"$uuid"}],"decryption":"$decryption"},
      "streamSettings":$stream_settings,
      "encryption":"$encryption",
      "network":"$network",
      "domain":"$domain",
      "rtt":"$rtt_mode"
    }
  ]
}
EOF

    echo "生成成功: $file"
    print_uri "$file"
}

reset_password() {
    file=$(selectfilewith_exit) || return
    uuid=$("$XRAY_BIN" uuid)
    enc=$(jq -r '.inbounds[0].encryption' "$file")
    appearance=$(echo "$enc" | cut -d. -f2)
    rtt_mode=$(echo "$enc" | cut -d. -f3)
    kex_type="mlkem768"

    read decryption encryption < <(generatemlkemparams "$rtt_mode" "$appearance" "$kex_type")

    jq ".inbounds[0].settings.clients[0].id=\"$uuid\" |
        .inbounds[0].settings.decryption=\"$decryption\" |
        .inbounds[0].encryption=\"$encryption\"" "$file" > "$file.tmp" && mv "$file.tmp" "$file"

    echo "密码与UUID已重置"
    print_uri "$file"
}

delete_inbound() {
    file=$(selectfilewith_exit) || return
    rm -f "$file"
    echo "已删除 $file"
}

modify_inbound() {
    file=$(selectfilewith_exit) || return
    ${EDITOR:-vim} "$file"
}

print_uris() {
    file=$(selectfilewith_exit) || return
    print_uri "$file"
}

while true; do
    echo
    echo "==== VLESS ENC 入站管理 ===="
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