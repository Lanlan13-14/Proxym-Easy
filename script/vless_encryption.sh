#!/bin/bash
CONF_DIR="/etc/xray/conf.d"
XRAY_BIN="/etc/xray/bin/xray"
mkdir -p "$CONF_DIR"

# VLESS Encryption defaults.
# 默认生成标准分享链接格式：encryption=mlkem768x25519plus.<appearance>.0rtt.<client-param>
# padding 默认不显式写入，交给核心使用内置默认值。
DEFAULT_APPEARANCE="xorpub"
DEFAULT_TICKET="600s"
CORE_DEFAULT_PADDING="100-111-1111.75-0-111.50-0-3333"

# ========== 依赖检测与跨发行版自动安装 ==========
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo apt;
    elif command -v dnf >/dev/null 2>&1; then echo dnf;
    elif command -v yum >/dev/null 2>&1; then echo yum;
    elif command -v pacman >/dev/null 2>&1; then echo pacman;
    elif command -v apk >/dev/null 2>&1; then echo apk;
    elif command -v zypper >/dev/null 2>&1; then echo zypper;
    else echo unknown; fi
}

pkg_for_cmd() {
    local mgr="$1" cmd="$2"
    case "$cmd" in
        ss) case "$mgr" in apt) echo iproute2 ;; yum|dnf|pacman|apk|zypper) echo iproute2 ;; *) echo iproute2 ;; esac ;;
        vim) case "$mgr" in apk) echo vim ;; *) echo vim ;; esac ;;
        *) echo "$cmd" ;;
    esac
}

install_packages() {
    local mgr="$1"; shift
    case "$mgr" in
        apt) apt-get update -y >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 ;;
        yum) yum install -y "$@" >/dev/null 2>&1 ;;
        dnf) dnf install -y "$@" >/dev/null 2>&1 ;;
        pacman) pacman -Sy --noconfirm "$@" >/dev/null 2>&1 ;;
        apk) apk add --no-cache "$@" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive install -y "$@" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

ensure_deps() {
    local mgr cmd pkg to_install=""
    mgr=$(detect_pkg_manager)
    [[ "$mgr" == unknown ]] && { echo "无法检测包管理器，请手动安装依赖: $*" >&2; return 1; }
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            pkg=$(pkg_for_cmd "$mgr" "$cmd")
            case " $to_install " in *" $pkg "*) ;; *) to_install="$to_install $pkg" ;; esac
        fi
    done
    if [[ -n "$to_install" ]]; then
        echo "检测到缺少依赖，正在安装:$to_install"
        install_packages "$mgr" $to_install || { echo "依赖安装失败，请手动安装:$to_install" >&2; return 1; }
    fi
}

ensure_deps jq curl openssl vim ss || exit 1

getnextnumber() {
    for i in {40..50}; do
        if ! ls "$CONF_DIR" 2>/dev/null | grep -q "^$i-inbound-vlessenc_"; then
            echo "$i"
            return
        fi
    done
    echo "No available number (40-50)"
    exit 1
}

check_port() {
    local listen_addr="$1"
    local port="$2"
    if [[ -z "$port" ]]; then
        port="$listen_addr"
        listen_addr=""
    fi
    if [[ -n "$listen_addr" && "$listen_addr" != "0.0.0.0" && "$listen_addr" != "::" ]]; then
        ss -tuln 2>/dev/null | awk -v ip="$listen_addr" -v p=":$port" '$0 ~ p"[[:space:]]" && $0 ~ ip {found=1} END{exit found?0:1}' && return 1 || return 0
    fi
    ss -tuln 2>/dev/null | grep -q ":$port " && return 1 || return 0
}

random_port() {
    echo $(( (RANDOM * 2 + RANDOM) % 50000 + 10000 ))
}

rand_int() {
    local min="$1" max="$2" span
    if (( max < min )); then
        echo "$min"
        return
    fi
    span=$((max - min + 1))
    echo $(( min + (RANDOM * 32768 + RANDOM) % span ))
}

generate_stealth_padding() {
    local direction="$1" pads first_min first_max first_extra cap parts i
    local delay_prob delay_min delay_max delay_extra pad_prob pad_min pad_max pad_extra

    if [[ "$direction" == "server" ]]; then
        pads=$(rand_int 2 5)
        first_min=$(rand_int 96 640)
        first_extra=$(rand_int 320 2304)
        cap=$(rand_int 2048 6144)
    else
        pads=$(rand_int 2 5)
        first_min=$(rand_int 80 512)
        first_extra=$(rand_int 256 2048)
        cap=$(rand_int 1536 5120)
    fi

    first_max=$((first_min + first_extra))
    parts="100-${first_min}-${first_max}"

    for ((i=2; i<=pads; i++)); do
        delay_prob=$(rand_int 35 90)
        delay_min=$(rand_int 0 90)
        delay_extra=$(rand_int 30 280)
        delay_max=$((delay_min + delay_extra))

        pad_prob=$(rand_int 25 85)
        if (( $(rand_int 0 99) < 70 )); then
            pad_min=0
        else
            pad_min=$(rand_int 16 384)
        fi
        pad_extra=$(rand_int 256 "$cap")
        pad_max=$((pad_min + pad_extra))

        parts="${parts}.${delay_prob}-${delay_min}-${delay_max}.${pad_prob}-${pad_min}-${pad_max}"
    done

    echo "$parts"
}

valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    p=$((10#$p))
    (( p >= 1 && p <= 65535 ))
}

ask_port() {
    local listen="$1" p
    while :; do
        read -rp "监听端口（1-65535，留空随机）: " p
        if [[ -z "$p" ]]; then
            while :; do
                p=$(random_port)
                check_port "$listen" "$p" && break
            done
            echo "$p"
            return
        fi
        if ! valid_port "$p"; then
            echo "端口无效，请输入 1-65535" >&2
            continue
        fi
        p=$((10#$p))
        if ! check_port "$listen" "$p"; then
            echo "端口 $p 已被占用，请换一个" >&2
            continue
        fi
        echo "$p"
        return
    done
}

get_ipv4() { curl -s -4 --max-time 4 ip.sb; }
get_ipv6() { curl -s -6 --max-time 4 ip.sb; }

valid_ipv4_addr() {
    local ip="$1" o1 o2 o3 o4
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    o1=${BASH_REMATCH[1]}; o2=${BASH_REMATCH[2]}; o3=${BASH_REMATCH[3]}; o4=${BASH_REMATCH[4]}
    (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 ))
}

valid_ipv6_addr() {
    local ip="$1"
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]
}

# URL 编码函数：按 Xray VLESS 分享链接标准使用 encodeURIComponent 规则
url_encode() {
    if command -v python3 >/dev/null 2>&1; then
        URI_VALUE="$1" python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ.get("URI_VALUE", ""), safe="-_.!~*()" + chr(39)), end="")'
    elif command -v jq >/dev/null 2>&1; then
        jq -nr --arg v "$1" '$v|@uri'
    else
        printf '%s' "$1"
    fi
}

uri_kv() {
    printf '%s=%s' "$1" "$(url_encode "$2")"
}

normalize_uri_host() {
    local h="$1"
    if [[ "$h" == *:* && "$h" != \[*\] ]]; then
        echo "[$h]"
    else
        echo "$h"
    fi
}

validate_ticket() {
    local v="$1" min max
    if [[ "$v" =~ ^([0-9]+)s$ ]]; then
        return 0
    fi
    if [[ "$v" =~ ^([0-9]+)-([0-9]+)s$ ]]; then
        min="${BASH_REMATCH[1]}"
        max="${BASH_REMATCH[2]}"
        (( min <= max )) && return 0
    fi
    return 1
}

validate_padding_chain() {
    local chain="$1" block prob min max i
    [[ -z "$chain" ]] && return 0

    local IFS='.'
    read -r -a blocks <<< "$chain"
    (( ${#blocks[@]} % 2 == 1 )) || return 1

    for i in "${!blocks[@]}"; do
        block="${blocks[$i]}"
        [[ "$block" =~ ^([0-9]+)-([0-9]+)-([0-9]+)$ ]] || return 1
        prob="${BASH_REMATCH[1]}"
        min="${BASH_REMATCH[2]}"
        max="${BASH_REMATCH[3]}"
        (( prob >= 0 && prob <= 100 )) || return 1
        (( min <= max )) || return 1
        if (( i == 0 )); then
            (( prob == 100 && min > 0 )) || return 1
        fi
    done
    return 0
}

ask_ticket() {
    local rtt_mode="$1" v
    if [[ "$rtt_mode" == "1rtt" ]]; then
        echo "0s"
        return
    fi
    while :; do
        read -rp "会话恢复票据有效时间（默认 $DEFAULT_TICKET，支持 600s 或 100-500s）: " v
        v=${v:-$DEFAULT_TICKET}
        if validate_ticket "$v"; then
            echo "$v"
            return
        fi
        echo "格式无效。示例：600s 或 100-500s" >&2
    done
}

ask_padding_custom() {
    local prompt="$1" default_value="$2" value
    while :; do
        read -rp "$prompt" value
        value=${value:-$default_value}
        if validate_padding_chain "$value"; then
            echo "$value"
            return
        fi
        echo "padding 格式无效。要求 padding.delay.padding[.delay.padding...]，第一个 padding 必须 100%-min>0-max，例如：$CORE_DEFAULT_PADDING" >&2
    done
}

select_profile() {
    local p
    echo "选择配置档位：" >&2
    echo "[1] 标准格式" >&2
    echo "[2] 高伪装" >&2
    echo "[3] 完全自定义" >&2
    read -rp "选择 [1-3]（默认 1）: " p
    case "$p" in
        2) echo "stealth" ;;
        3) echo "custom" ;;
        *) echo "standard" ;;
    esac
}

select_kex_type() {
    local def="$1" sel
    echo "选择认证参数类型：" >&2
    echo "[1] X25519" >&2
    echo "[2] MLKEM768" >&2
    if [[ "$def" == "x25519" ]]; then
        read -rp "选择 [1-2]（默认 1）: " sel
        [[ "$sel" == "2" ]] && echo "mlkem768" || echo "x25519"
    else
        read -rp "选择 [1-2]（默认 2）: " sel
        [[ "$sel" == "1" ]] && echo "x25519" || echo "mlkem768"
    fi
}

select_appearance() {
    local def="$1" sel
    echo "选择外观模式：" >&2
    echo "[1] native" >&2
    echo "[2] xorpub" >&2
    echo "[3] random" >&2
    read -rp "选择 [1-3]（默认 ${def}）: " sel
    case "$sel" in
        1) echo "native" ;;
        3) echo "random" ;;
        *) echo "$def" ;;
    esac
}

select_rtt_mode() {
    local sel
    echo "RTT 模式：" >&2
    echo "[1] 1-RTT" >&2
    echo "[2] 0-RTT" >&2
    read -rp "选择 [1-2]（默认 2）: " sel
    [[ "$sel" == "1" ]] && echo "1rtt" || echo "0rtt"
}

select_padding_pair() {
    local def_mode="$1" sel server_custom client_custom
    echo "选择 padding：" >&2
    echo "[1] 默认 padding" >&2
    echo "[2] 高伪装 padding" >&2
    echo "[3] 自定义 padding" >&2
    if [[ "$def_mode" == "high" ]]; then
        read -rp "选择 [1-3]（默认 2）: " sel
        [[ -z "$sel" ]] && sel="2"
    else
        read -rp "选择 [1-3]（默认 1）: " sel
        [[ -z "$sel" ]] && sel="1"
    fi

    case "$sel" in
        2)
            server_padding=$(generate_stealth_padding server)
            client_padding=$(generate_stealth_padding client)
            echo "已生成随机高伪装 padding" >&2
            ;;
        3)
            echo "说明：padding/delay 都是 probability-min-max；块数必须为奇数，形如 padding.delay.padding[.delay.padding...]。" >&2
            server_custom=$(ask_padding_custom "服务端→客户端 padding（留空=核心默认）: " "")
            client_custom=$(ask_padding_custom "客户端→服务端 padding（留空=同服务端；若服务端也空则核心默认）: " "$server_custom")
            server_padding="$server_custom"
            client_padding="$client_custom"
            ;;
        *)
            server_padding=""
            client_padding=""
            ;;
    esac
}

select_network() {
    local sel
    echo "选择传输协议：" >&2
    echo "[1] tcp（默认；本脚本不支持 XHTTP）" >&2
    echo "[2] ws" >&2
    read -rp "选择 [1-2]（默认 tcp）: " sel
    [[ "$sel" == "2" ]] && echo "ws" || echo "tcp"
}

generatemlkemparams() {
    local rtt_mode="$1"
    local appearance="$2"
    local kex_type="$3"
    local ticket="$4"
    local server_pad="$5"
    local client_pad="$6"
    local out priv pwd seed client decryption encryption server_mid client_mid

    server_mid="$ticket"
    client_mid="$rtt_mode"
    [[ -n "$server_pad" ]] && server_mid="${server_mid}.${server_pad}"
    [[ -n "$client_pad" ]] && client_mid="${client_mid}.${client_pad}"

    if [[ "$kex_type" == "x25519" ]]; then
        out=$("$XRAY_BIN" x25519)
        priv=$(echo "$out" | awk -F':' '/PrivateKey/ {gsub(/ /,"",$2);print $2}')
        pwd=$( echo "$out" | awk -F':' '/Password/   {gsub(/ /,"",$2);print $2}')
        decryption="mlkem768x25519plus.${appearance}.${server_mid}.${priv}"
        encryption="mlkem768x25519plus.${appearance}.${client_mid}.${pwd}"
    else
        out=$("$XRAY_BIN" mlkem768)
        seed=$(  echo "$out" | awk -F':' '/Seed/   {gsub(/ /,"",$2);print $2}')
        client=$(echo "$out" | awk -F':' '/Client/ {gsub(/ /,"",$2);print $2}')
        decryption="mlkem768x25519plus.${appearance}.${server_mid}.${seed}"
        encryption="mlkem768x25519plus.${appearance}.${client_mid}.${client}"
    fi

    echo "$decryption" "$encryption"
}

select_fingerprint() {
    local fp_sel
    echo "选择 uTLS 指纹（默认 chrome）" >&2
    echo "[1] chrome" >&2
    echo "[2] firefox" >&2
    echo "[3] safari" >&2
    echo "[4] ios" >&2
    echo "[5] android" >&2
    echo "[6] edge" >&2
    echo "[7] 360" >&2
    echo "[8] qq" >&2
    echo "[9] random" >&2
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

get_last_block() {
    local s="$1"
    local IFS='.'
    read -r -a parts <<< "$s"
    echo "${parts[$((${#parts[@]}-1))]}"
}

extract_padding_from_vlessenc() {
    local s="$1" res="" i n
    local IFS='.'
    read -r -a parts <<< "$s"
    n=${#parts[@]}
    (( n <= 4 )) && { echo ""; return; }
    for ((i=3; i<n-1; i++)); do
        [[ -n "$res" ]] && res="$res."
        res="$res${parts[$i]}"
    done
    echo "$res"
}

infer_auth_from_encryption() {
    local enc="$1" last
    last=$(get_last_block "$enc")
    if (( ${#last} > 100 )); then
        echo "mlkem768"
    else
        echo ""
    fi
}

print_uri() {
    local file="$1"
    local port uuid encryption network security host path fingerprint domain hostip ipv4 ipv6 uri_params nodename encoded_nodename manual_host cert_file

    port=$(jq -r '.inbounds[0].port' "$file")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id // .inbounds[0].settings.users[0].id // empty' "$file")
    encryption=$(jq -r '.inbounds[0]._proxym.clientEncryption // .inbounds[0].encryption // empty' "$file")
    network=$(jq -r '.inbounds[0].streamSettings.network // .inbounds[0]._proxym.network // "tcp"' "$file")
    security=$(jq -r '.inbounds[0].streamSettings.security // "none"' "$file")

    if [[ -z "$uuid" || -z "$encryption" ]]; then
        echo "配置中缺少 UUID 或客户端 encryption，无法打印 URI" >&2
        return 1
    fi

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
    if valid_ipv4_addr "$ipv4"; then
        hostip="$ipv4"
    elif valid_ipv6_addr "$ipv6"; then
        hostip="[$ipv6]"
    else
        hostip="server-address"
    fi
    read -rp "分享链接服务器地址（默认 $hostip）: " manual_host
    [[ -n "$manual_host" ]] && hostip=$(normalize_uri_host "$manual_host")

    if [[ "$security" == "tls" ]]; then
        uri_params="$(uri_kv encryption "$encryption")&$(uri_kv security tls)&$(uri_kv sni "$domain")&$(uri_kv type "$network")"
        [[ -n "$fingerprint" ]] && uri_params="${uri_params}&$(uri_kv fp "$fingerprint")"
    else
        uri_params="$(uri_kv encryption "$encryption")&$(uri_kv security none)&$(uri_kv type "$network")"
    fi

    [[ -n "$host" ]] && uri_params="${uri_params}&$(uri_kv host "$host")"
    [[ -n "$path" ]] && uri_params="${uri_params}&$(uri_kv path "$path")"

    read -rp "节点名称（默认 $port）: " nodename
    [[ -z "$nodename" ]] && nodename="$port"
    encoded_nodename=$(url_encode "$nodename")

    echo "vless://$uuid@$hostip:$port?${uri_params}#${encoded_nodename}"
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
    local listen profile def_kex def_padding_mode kex_type appearance rtt_mode ticket network domain host path randpath fingerprint
    local port uuid decryption encryption number file tag cert_path key_path tls_settings ws_settings stream_settings client_obj

    read -rp "监听地址（默认 0.0.0.0）: " listen
    listen=${listen:-0.0.0.0}
    port=$(ask_port "$listen")

    profile=$(select_profile)
    case "$profile" in
        standard)
            def_kex="mlkem768"
            def_padding_mode="default"
            ;;
        custom)
            def_kex="mlkem768"
            def_padding_mode="default"
            ;;
        *)
            def_kex="x25519"
            def_padding_mode="high"
            ;;
    esac

    kex_type=$(select_kex_type "$def_kex")
    appearance=$(select_appearance "$DEFAULT_APPEARANCE")
    rtt_mode=$(select_rtt_mode)
    ticket=$(ask_ticket "$rtt_mode")
    select_padding_pair "$def_padding_mode"
    network=$(select_network)

    domain=""
    host=""
    randpath=$(openssl rand -hex 8 2>/dev/null)
    path="/$randpath"
    fingerprint="chrome"

    if [[ "$network" == "ws" ]]; then
        read -rp "WS 路径（默认随机 $path）： " path_in
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
    read decryption encryption < <(generatemlkemparams "$rtt_mode" "$appearance" "$kex_type" "$ticket" "$server_padding" "$client_padding")

    number=$(getnextnumber)
    file="$CONF_DIR/$number-inbound-vlessenc_$port.json"
    tag="vless-enc-$port-in"

    if [[ -n "$domain" ]]; then
        cert_path="/etc/ssl/acme/$domain/fullchain.pem"
        key_path="/etc/ssl/acme/$domain/privkey.key"
        tls_settings=$(jq -cn --arg cert "$cert_path" --arg key "$key_path" --arg fp "$fingerprint" '{certificates:[{certificateFile:$cert,keyFile:$key}], fingerprint:$fp}')
        if [[ "$network" == "ws" ]]; then
            ws_settings=$(jq -cn --arg path "$path" --arg host "$host" '{path:$path} + (if $host != "" then {headers:{Host:$host}} else {} end)')
            stream_settings=$(jq -cn --argjson tls "$tls_settings" --argjson ws "$ws_settings" '{network:"ws",security:"tls",tlsSettings:$tls,wsSettings:$ws}')
        else
            stream_settings=$(jq -cn --argjson tls "$tls_settings" '{network:"tcp",security:"tls",tlsSettings:$tls}')
        fi
    else
        if [[ "$network" == "ws" ]]; then
            ws_settings=$(jq -cn --arg path "$path" --arg host "$host" '{path:$path} + (if $host != "" then {headers:{Host:$host}} else {} end)')
            stream_settings=$(jq -cn --argjson ws "$ws_settings" '{network:"ws",security:"none",wsSettings:$ws}')
        else
            stream_settings='{"network":"tcp","security":"none"}'
        fi
    fi

    client_obj=$(jq -cn --arg id "$uuid" '{id:$id}')

    jq -n \
        --arg tag "$tag" \
        --arg listen "$listen" \
        --argjson port "$port" \
        --argjson client "$client_obj" \
        --arg decryption "$decryption" \
        --argjson stream "$stream_settings" \
        --arg encryption "$encryption" \
        --arg network "$network" \
        --arg domain "$domain" \
        --arg rtt "$rtt_mode" \
        --arg ticket "$ticket" \
        --arg appearance "$appearance" \
        --arg auth "$kex_type" \
        --arg serverPadding "$server_padding" \
        --arg clientPadding "$client_padding" \
        '{
          inbounds: [
            {
              tag: $tag,
              listen: $listen,
              port: $port,
              protocol: "vless",
              settings: {clients: [$client], decryption: $decryption},
              streamSettings: $stream,
              encryption: $encryption,
              network: $network,
              domain: $domain,
              rtt: $rtt,
              _proxym: {
                clientEncryption: $encryption,
                appearance: $appearance,
                ticket: $ticket,
                rtt: $rtt,
                auth: $auth,
                serverPadding: $serverPadding,
                clientPadding: $clientPadding,
                network: $network,
                domain: $domain
              }
            }
          ]
        }' > "$file"

    echo "生成成功: $file"
    echo "服务端 decryption: $decryption"
    echo "客户端 encryption: $encryption"
    print_uri "$file"
}

reset_password() {
    local file uuid dec enc appearance rtt_mode ticket server_pad client_pad kex_type inferred decryption encryption
    file=$(selectfilewith_exit) || return
    uuid=$("$XRAY_BIN" uuid)

    dec=$(jq -r '.inbounds[0].settings.decryption // empty' "$file")
    enc=$(jq -r '.inbounds[0]._proxym.clientEncryption // .inbounds[0].encryption // empty' "$file")

    appearance=$(jq -r '.inbounds[0]._proxym.appearance // empty' "$file")
    [[ -z "$appearance" ]] && appearance=$(echo "$dec" | cut -d. -f2)
    [[ "$appearance" != "native" && "$appearance" != "xorpub" && "$appearance" != "random" ]] && appearance="$DEFAULT_APPEARANCE"

    rtt_mode=$(jq -r '.inbounds[0]._proxym.rtt // empty' "$file")
    [[ -z "$rtt_mode" ]] && rtt_mode=$(echo "$enc" | cut -d. -f3)
    [[ "$rtt_mode" != "0rtt" && "$rtt_mode" != "1rtt" ]] && rtt_mode="0rtt"

    ticket=$(jq -r '.inbounds[0]._proxym.ticket // empty' "$file")
    [[ -z "$ticket" ]] && ticket=$(echo "$dec" | cut -d. -f3)
    validate_ticket "$ticket" || ticket="$DEFAULT_TICKET"
    [[ "$rtt_mode" == "1rtt" ]] && ticket="0s"

    server_pad=$(jq -r '.inbounds[0]._proxym.serverPadding // empty' "$file")
    client_pad=$(jq -r '.inbounds[0]._proxym.clientPadding // empty' "$file")
    [[ -z "$server_pad" && -n "$dec" ]] && server_pad=$(extract_padding_from_vlessenc "$dec")
    [[ -z "$client_pad" && -n "$enc" ]] && client_pad=$(extract_padding_from_vlessenc "$enc")
    validate_padding_chain "$server_pad" || server_pad=""
    validate_padding_chain "$client_pad" || client_pad=""

    kex_type=$(jq -r '.inbounds[0]._proxym.auth // empty' "$file")
    if [[ -z "$kex_type" || "$kex_type" == "null" ]]; then
        inferred=$(infer_auth_from_encryption "$enc")
        if [[ -n "$inferred" ]]; then
            kex_type="$inferred"
        else
            echo "旧配置无法可靠判断认证参数类型，请选择："
            kex_type=$(select_kex_type "mlkem768")
        fi
    fi

    read decryption encryption < <(generatemlkemparams "$rtt_mode" "$appearance" "$kex_type" "$ticket" "$server_pad" "$client_pad")

    jq \
        --arg uuid "$uuid" \
        --arg decryption "$decryption" \
        --arg encryption "$encryption" \
        --arg appearance "$appearance" \
        --arg ticket "$ticket" \
        --arg rtt "$rtt_mode" \
        --arg auth "$kex_type" \
        --arg serverPadding "$server_pad" \
        --arg clientPadding "$client_pad" \
        '(.inbounds[0].settings.clients[0].id // .inbounds[0].settings.users[0].id) = $uuid |
         .inbounds[0].settings.decryption = $decryption |
         .inbounds[0].encryption = $encryption |
         .inbounds[0]._proxym.clientEncryption = $encryption |
         .inbounds[0]._proxym.appearance = $appearance |
         .inbounds[0]._proxym.ticket = $ticket |
         .inbounds[0]._proxym.rtt = $rtt |
         .inbounds[0]._proxym.auth = $auth |
         .inbounds[0]._proxym.serverPadding = $serverPadding |
         .inbounds[0]._proxym.clientPadding = $clientPadding' \
         "$file" > "$file.tmp" && mv "$file.tmp" "$file"

    echo "UUID 与 VLESS Encryption 密钥已重置，已保留 appearance/ticket/padding 设置"
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
    echo "[3] 重置 UUID/密钥"
    echo "[4] 修改入站配置"
    echo "[5] 打印 URI"
    echo "[0] 退出"
    if ! read -rp "选择操作 [0-5]: " opt; then
        echo
        exit 0
    fi

    case $opt in
        1) add_inbound ;;
        2) delete_inbound ;;
        3) reset_password ;;
        4) modify_inbound ;;
        5) print_uris ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
done
