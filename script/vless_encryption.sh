#!/bin/bash
# vless_encryption.sh - 节点生成与管理脚本（被 proxym-easy source）
# 放置: script/vless_encryption.sh (仓库路径)
# 说明:
# - 保留原有默认逻辑与字段命名
# - add_vless 支持：添加完一种类型节点后继续添加另一种；若发现与现有节点冲突，询问用户是覆盖、附加还是跳过
# - regenerate_full_config 在生成前交互式询问两个 DNS（直接回车使用默认 1.1.1.1 / 8.8.8.8）
# - 生成的 tag 格式为: 国旗 + 空格 + 国家缩写 + 空格 + 城市（例如: 🇭🇰 HKG Hong Kong），并在 URI 中进行 URL 编码
# - 保持与主脚本兼容的函数名与行为

set -euo pipefail
export LC_ALL=C.UTF-8

# 颜色与符号
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
INFO="${BLUE}ℹ️${NC}"; WARN="${YELLOW}⚠️${NC}"

log() { echo -e "${INFO} $1${NC}"; }
warn() { echo -e "${WARN} $1${NC}"; }
error() { echo -e "${RED}✖ $1${NC}"; exit 1; }

# 路径（与主脚本一致）
VLESS_JSON="/etc/proxym/vless.json"
GLOBAL_JSON="/etc/proxym/global.json"
CONFIG="/usr/local/etc/xray/config.json"

# 完整国旗映射（ISO 3166-1 alpha-2 -> emoji）
declare -A FLAGS=(
    [AD]="🇦🇩" [AE]="🇦🇪" [AF]="🇦🇫" [AG]="🇦🇬" [AI]="🇦🇮"
    [AL]="🇦🇱" [AM]="🇦🇲" [AO]="🇦🇴" [AQ]="🇦🇶" [AR]="🇦🇷"
    [AS]="🇦🇸" [AT]="🇦🇹" [AU]="🇦🇺" [AW]="🇦🇼" [AX]="🇦🇽"
    [AZ]="🇦🇿" [BA]="🇧🇦" [BB]="🇧🇧" [BD]="🇧🇩" [BE]="🇧🇪"
    [BF]="🇧🇫" [BG]="🇧🇬" [BH]="🇧🇭" [BI]="🇧🇮" [BJ]="🇧🇯"
    [BL]="🇧🇱" [BM]="🇧🇲" [BN]="🇧🇳" [BO]="🇧🇴" [BQ]="🇧🇶"
    [BR]="🇧🇷" [BS]="🇧🇸" [BT]="🇧🇹" [BV]="🇧🇻" [BW]="🇧🇼"
    [BY]="🇧🇾" [BZ]="🇧🇿" [CA]="🇨🇦" [CC]="🇨🇨" [CD]="🇨🇩"
    [CF]="🇨🇫" [CG]="🇨🇬" [CH]="🇨🇭" [CI]="🇨🇮" [CK]="🇨🇰"
    [CL]="🇨🇱" [CM]="🇨🇲" [CN]="🇨🇳" [CO]="🇨🇴" [CR]="🇨🇷"
    [CU]="🇨🇺" [CV]="🇨🇻" [CW]="🇨🇼" [CX]="🇨🇽" [CY]="🇨🇾"
    [CZ]="🇨🇿" [DE]="🇩🇪" [DJ]="🇩🇯" [DK]="🇩🇰" [DM]="🇩🇲"
    [DO]="🇩🇴" [DZ]="🇩🇿" [EC]="🇪🇨" [EE]="🇪🇪" [EG]="🇪🇬"
    [EH]="🇪🇭" [ER]="🇪🇷" [ES]="🇪🇸" [ET]="🇪🇹" [FI]="🇫🇮"
    [FJ]="🇫🇯" [FK]="🇫🇰" [FM]="🇫🇲" [FO]="🇫🇴" [FR]="🇫🇷"
    [GA]="🇬🇦" [GB]="🇬🇧" [GD]="🇬🇩" [GE]="🇬🇪" [GF]="🇬🇫"
    [GG]="🇬🇬" [GH]="🇬🇭" [GI]="🇬🇮" [GL]="🇬🇱" [GM]="🇬🇲"
    [GN]="🇬🇳" [GP]="🇬🇵" [GQ]="🇬🇶" [GR]="🇬🇷" [GS]="🇬🇸"
    [GT]="🇬🇹" [GU]="🇬🇺" [GW]="🇬🇼" [GY]="🇬🇾" [HK]="🇭🇰"
    [HM]="🇭🇲" [HN]="🇭🇳" [HR]="🇭🇷" [HT]="🇭🇹" [HU]="🇭🇺"
    [ID]="🇮🇩" [IE]="🇮🇪" [IL]="🇮🇱" [IM]="🇮🇲" [IN]="🇮🇳"
    [IO]="🇮🇴" [IQ]="🇮🇶" [IR]="🇮🇷" [IS]="🇮🇸" [IT]="🇮🇹"
    [JE]="🇯🇪" [JM]="🇯🇲" [JO]="🇯🇴" [JP]="🇯🇵" [KE]="🇰🇪"
    [KG]="🇰🇬" [KH]="🇰🇭" [KI]="🇰🇮" [KM]="🇰🇲" [KN]="🇰🇳"
    [KP]="🇰🇵" [KR]="🇰🇷" [KW]="🇰🇼" [KY]="🇰🇾" [KZ]="🇰🇿"
    [LA]="🇱🇦" [LB]="🇱🇧" [LC]="🇱🇨" [LI]="🇱🇮" [LK]="🇱🇰"
    [LR]="🇱🇷" [LS]="🇱🇸" [LT]="🇱🇹" [LU]="🇱🇺" [LV]="🇱🇻"
    [LY]="🇱🇾" [MA]="🇲🇦" [MC]="🇲🇨" [MD]="🇲🇩" [ME]="🇲🇪"
    [MF]="🇲🇫" [MG]="🇲🇬" [MH]="🇲🇭" [MK]="🇲🇰" [ML]="🇲🇱"
    [MM]="🇲🇲" [MN]="🇲🇳" [MO]="🇲🇴" [MP]="🇲🇵" [MQ]="🇲🇶"
    [MR]="🇲🇷" [MS]="🇲🇸" [MT]="🇲🇹" [MU]="🇲🇺" [MV]="🇲🇻"
    [MW]="🇲🇼" [MX]="🇲🇽" [MY]="🇲🇾" [MZ]="🇲🇿" [NA]="🇳🇦"
    [NC]="🇳🇨" [NE]="🇳🇪" [NF]="🇳🇫" [NG]="🇳🇬" [NI]="🇳🇮"
    [NL]="🇳🇱" [NO]="🇳🇴" [NP]="🇳🇵" [NR]="🇳🇷" [NU]="🇳🇺"
    [NZ]="🇳🇿" [OM]="🇴🇲" [PA]="🇵🇦" [PE]="🇵🇪" [PF]="🇵🇫"
    [PG]="🇵🇬" [PH]="🇵🇭" [PK]="🇵🇰" [PL]="🇵🇱" [PM]="🇵🇲"
    [PN]="🇵🇳" [PR]="🇵🇷" [PS]="🇵🇸" [PT]="🇵🇹" [PW]="🇵🇼"
    [PY]="🇵🇾" [QA]="🇶🇦" [RE]="🇷🇪" [RO]="🇷🇴" [RS]="🇷🇸"
    [RU]="🇷🇺" [RW]="🇷🇼" [SA]="🇸🇦" [SB]="🇸🇧" [SC]="🇸🇨"
    [SD]="🇸🇩" [SE]="🇸🇪" [SG]="🇸🇬" [SH]="🇸🇭" [SI]="🇸🇮"
    [SJ]="🇸🇯" [SK]="🇸🇰" [SL]="🇸🇱" [SM]="🇸🇲" [SN]="🇸🇳"
    [SO]="🇸🇴" [SR]="🇸🇷" [SS]="🇸🇸" [ST]="🇸🇹" [SV]="🇸🇻"
    [SX]="🇸🇽" [SY]="🇸🇾" [SZ]="🇸🇿" [TC]="🇹🇨" [TD]="🇹🇩"
    [TF]="🇹🇫" [TG]="🇹🇬" [TH]="🇹🇭" [TJ]="🇹🇯" [TK]="🇹🇰"
    [TL]="🇹🇱" [TM]="🇹🇲" [TN]="🇹🇳" [TO]="🇹🇴" [TR]="🇹🇷"
    [TT]="🇹🇹" [TV]="🇹🇻" [TW]="🇹🇼" [TZ]="🇹🇿" [UA]="🇺🇦"
    [UG]="🇺🇬" [UM]="🇺🇲" [US]="🇺🇸" [UY]="🇺🇾" [UZ]="🇺🇿"
    [VA]="🇻🇦" [VC]="🇻🇨" [VE]="🇻🇪" [VG]="🇻🇬" [VI]="🇻🇮"
    [VN]="🇻🇳" [VU]="🇻🇺" [WF]="🇼🇫" [WS]="🇼🇸" [YE]="🇾🇪"
    [YT]="🇾🇹" [ZA]="🇿🇦" [ZM]="🇿🇲" [ZW]="🇿🇼"
)

# URL 编码（使用 python3）
url_encode() {
  if command -v python3 &>/dev/null; then
    python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))" <<< "$1"
  else
    echo "$1"
  fi
}

# 随机 path
generate_random_path() {
  openssl rand -hex 5 2>/dev/null || echo "path$(date +%s | cut -c1-5)"
}

# 读取 global.json（以便获取 client_token 等）
load_global_config_local() {
  if [ -f "$GLOBAL_JSON" ]; then
    CLIENT_TOKEN_FILE=$(jq -r '.client_token // empty' "$GLOBAL_JSON" 2>/dev/null || echo "")
    if [ -n "$CLIENT_TOKEN_FILE" ]; then CLIENT_TOKEN="$CLIENT_TOKEN_FILE"; fi
  fi
}

# 获取公网 IPv4（用于默认建议）
detect_public_ipv4() {
  local ip=""
  if command -v curl &>/dev/null; then
    ip=$(curl -s4 --max-time 5 https://api.ipify.org || true)
  fi
  if [ -z "$ip" ] && command -v wget &>/dev/null; then
    ip=$(wget -qO- --timeout=5 https://api.ipify.org || true)
  fi
  echo "$ip"
}

# 解析域名优先 A 记录（只取 IPv4）
resolve_ipv4_for() {
  local name="$1"
  local ip=""
  if command -v dig &>/dev/null; then
    ip=$(dig +short A "$name" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)
  fi
  if [ -z "$ip" ] && command -v host &>/dev/null; then
    ip=$(host -t A "$name" 2>/dev/null | awk '/has address/ {print $4; exit}' || true)
  fi
  if [ -z "$ip" ] && command -v getent &>/dev/null; then
    ip=$(getent ahosts "$name" | awk '{print $1; exit}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)
  fi
  echo "$ip"
}

# 随机端口生成
generate_random_port() {
  if command -v shuf &>/dev/null; then
    shuf -i 1025-65535 -n 1
  else
    echo $(( (RANDOM % 64511) + 1025 ))
  fi
}

# get_location_from_ip（保留原实现）
get_location_from_ip() {
  local ip=$1
  local location_info
  location_info=$(curl -s --max-time 8 "http://ip-api.com/json/$ip?fields=status,message,countryCode,city" 2>/dev/null || echo "")
  if [ -z "$location_info" ] || echo "$location_info" | grep -q '"status":"fail"'; then
    echo "Unknown" "Unknown"
    return
  fi
  local country city
  country=$(echo "$location_info" | grep -o '"countryCode":"[^"]*"' | sed 's/.*"countryCode":"\([^"]*\)".*/\1/')
  city=$(echo "$location_info" | grep -o '"city":"[^"]*"' | sed 's/.*"city":"\([^"]*\)".*/\1/')
  if [ -z "$country" ] || [ -z "$city" ]; then
    echo "Unknown" "Unknown"
    return
  fi
  echo "$country" "$city"
}

# 生成节点信息（与主脚本兼容）
generate_node_info() {
  local uuid=$1; local port=$2; local decryption=$3; local encryption=$4; local ip=$5
  local tag=$6; local uri=$7; local domain=$8; local network=$9; local path=${10}
  local host=${11}; local fingerprint=${12}; local is_custom=${13}; local use_reality=${14}
  local dest=${15}; local sni=${16}; local shortids_json=${17}; local public_key_base64=${18}
  local flow=${19}; local push_enabled=${20}; local push_url=${21}; local push_token=${22}
  local servernames_json=${23}; local private_key=${24:-""}; local kex=${25}; local method=${26}
  local rtt=${27}; local use_mlkem=${28}
  if [ "$use_reality" = true ]; then
    cat <<EOF
{
  "uuid": "$uuid",
  "port": $port,
  "decryption": "$decryption",
  "encryption": "$encryption",
  "ip": "$ip",
  "tag": "$tag",
  "uri": "$uri",
  "domain": "$domain",
  "network": "$network",
  "path": "$path",
  "use_reality": true,
  "dest": "$dest",
  "sni": "$sni",
  "shortIds": $shortids_json,
  "public_key": "$public_key_base64",
  "flow": "$flow",
  "fingerprint": "$fingerprint",
  "is_custom_tag": $is_custom,
  "push_enabled": $push_enabled,
  "push_url": $push_url,
  "push_token": $push_token,
  "serverNames": $servernames_json,
  "privateKey": "$private_key",
  "kex": "$kex",
  "method": "$method",
  "rtt": "$rtt",
  "use_mlkem": $use_mlkem
}
EOF
  else
    cat <<EOF
{
  "uuid": "$uuid",
  "port": $port,
  "decryption": "$decryption",
  "encryption": "$encryption",
  "ip": "$ip",
  "tag": "$tag",
  "uri": "$uri",
  "domain": "$domain",
  "network": "$network",
  "path": "$path",
  "host": "$host",
  "fingerprint": "$fingerprint",
  "is_custom_tag": $is_custom,
  "push_enabled": $push_enabled,
  "push_url": $push_url,
  "push_token": $push_token,
  "kex": "$kex",
  "method": "$method",
  "rtt": "$rtt",
  "use_mlkem": $use_mlkem
}
EOF
  fi
}

# push 到远端
push_to_remote() {
  local uri=$1; local push_url=$2; local push_token=$3
  if [ -z "$push_url" ] || [ -z "$push_token" ]; then
    log "Push 配置不完整，跳过。"
    return
  fi
  local payload='{"token":"'"$push_token"'","uri":"'"$uri"'"}'
  curl -s -X POST "$push_url" -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 || warn "推送失败"
  log "已尝试推送 URI 到 $push_url"
}

# -------------------------
# ask_dns_interactive: 交互式询问两个 DNS，直接回车使用默认（1.1.1.1 / 8.8.8.8）
# -------------------------
ask_dns_interactive() {
  local default1="1.1.1.1"
  local default2="8.8.8.8"
  read -p "请输入主 DNS（默认 ${default1}，直接回车使用默认）: " DNS_PRIMARY
  DNS_PRIMARY=${DNS_PRIMARY:-$default1}
  read -p "请输入备用 DNS（默认 ${default2}，直接回车使用默认）: " DNS_SECONDARY
  DNS_SECONDARY=${DNS_SECONDARY:-$default2}
  export DNS_PRIMARY DNS_SECONDARY
}

# -------------------------
# helper: 检查是否存在冲突节点（按 ip/domain+port 或 tag 匹配）
# 返回: 0 如果找到冲突并输出冲突索引（jq filter），1 如果未找到
# -------------------------
find_conflicting_node() {
  local server="$1"
  local port="$2"
  local tag="$3"
  if [ ! -f "$VLESS_JSON" ]; then
    return 1
  fi
  # 精确匹配 domain/ip+port 或 tag
  local idx
  idx=$(jq -r --arg s "$server" --arg p "$port" --arg t "$tag" 'to_entries[] | select((.value.domain == $s or .value.ip == $s) and (.value.port|tostring == $p) or (.value.tag == $t)) | .key' "$VLESS_JSON" 2>/dev/null || true)
  if [ -n "$idx" ]; then
    echo "$idx"
    return 0
  fi
  return 1
}

# -------------------------
# add_vless: 支持循环添加与覆盖/附加询问
# 用户可以在添加完一种类型后继续添加另一种，直到选择退出
# -------------------------
add_vless() {
  load_global_config_local
  mkdir -p "$(dirname "$VLESS_JSON")"
  if [ ! -f "$VLESS_JSON" ]; then echo "[]" > "$VLESS_JSON"; fi

  echo "进入添加节点流程。每次添加后可选择继续添加其他类型或退出。"

  while true; do
    echo "---- 新节点 ----"
    # 自动建议 server
    default_server="$(detect_public_ipv4 || true)"
    read -p "服务器 IP 或域名（留空使用建议: ${default_server:-none}）: " server_addr
    if [ -z "$server_addr" ]; then server_addr="$default_server"; fi

    # 解析 IPv4（优先）
    resolved_ipv4=""
    if [ -n "$server_addr" ] && [[ ! "$server_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      resolved_ipv4=$(resolve_ipv4_for "$server_addr" || true)
      if [ -n "$resolved_ipv4" ]; then
        echo "检测到域名的 IPv4: $resolved_ipv4"
        read -p "使用该 IPv4 作为节点 IP? (Y/n): " use_resolved
        if [[ $use_resolved =~ ^[Nn]$ ]]; then resolved_ipv4=""; fi
      fi
    fi

    # reality 模式询问与端口
    default_port="$(generate_random_port)"
    read -p "是否使用 reality 模式? (y/N): " use_reality_input
    if [[ $use_reality_input =~ ^[Yy]$ ]]; then
      use_reality=true
      default_port="443"
    else
      use_reality=false
    fi
    read -p "端口（留空使用建议: ${default_port}）: " port
    if [ -z "$port" ]; then port="$default_port"; fi

    # UUID
    read -p "UUID (留空自动生成): " uuid
    if [ -z "$uuid" ]; then
      if command -v xray &>/dev/null; then uuid=$(xray uuid); else uuid=$(cat /proc/sys/kernel/random/uuid); fi
    fi

    # network/path/host
    read -p "网络类型 (tcp/ws) [ws]: " network
    network=${network:-ws}
    path=""; host=""
    if [ "$network" = "ws" ]; then
      read -p "Path (留空自动生成): " path
      if [ -z "$path" ]; then path="/$(generate_random_path)"; fi
      read -p "Host (留空使用域名或 IP): " host
      if [ -z "$host" ]; then host="$server_addr"; fi
    fi

    # TLS/SNI
    read -p "是否启用 TLS? (y/N): " use_tls
    if [[ $use_tls =~ ^[Yy]$ ]]; then
      security="tls"
      read -p "SNI（留空使用域名）: " sni
    else
      security="none"
      sni=""
    fi

    # 国家/城市/国家缩写自动检测并确认
    probe_ip="$resolved_ipv4"
    if [ -z "$probe_ip" ]; then
      if [[ "$server_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then probe_ip="$server_addr"; else probe_ip=$(resolve_ipv4_for "$server_addr" || true); fi
    fi
    if [ -z "$probe_ip" ]; then probe_ip="$(detect_public_ipv4 || true)"; fi

    suggested_country="Unknown"; suggested_city="Unknown"; suggested_country_code=""
    if [ -n "$probe_ip" ]; then
      read suggested_country suggested_city <<< "$(get_location_from_ip "$probe_ip" || echo "Unknown Unknown")"
      suggested_country_code="$suggested_country"
    fi

    suggested_country_short="${suggested_country_code}"
    read -p "国家代码（ISO alpha-2，建议: ${suggested_country_code:-HK}）: " country_code
    country_code=${country_code:-$suggested_country_code}
    country_code_upper=$(echo "$country_code" | tr '[:lower:]' '[:upper:]')

    read -p "国家缩写（显示用，例如 HKG, TWN，留空使用 ${suggested_country_short:-$country_code_upper}）: " country_short
    country_short=${country_short:-${suggested_country_short:-$country_code_upper}}

    read -p "城市（留空使用建议: ${suggested_city:-Unknown}）: " city
    city=${city:-$suggested_city}

    # 生成 tag
    flag="${FLAGS[$country_code_upper]:-🌍}"
    tag="${flag} ${country_short} ${city}"
    tag_encoded=$(url_encode "$tag")

    # encryption/decryption 默认 none（保留原逻辑）
    decryption="none"; encryption="none"

    # 生成 URI 参数
    uri_params="type=${network}&encryption=${encryption}&packetEncoding=xudp"
    if [ "$network" = "ws" ]; then
      uri_params="${uri_params}&path=$(url_encode "$path")"
      if [ -n "$host" ]; then uri_params="${uri_params}&host=$(url_encode "$host")"; fi
    fi
    if [ "$security" = "tls" ]; then
      if [ -n "$sni" ]; then uri_params="${uri_params}&security=tls&sni=$(url_encode "$sni")&fp=chrome"
      else uri_params="${uri_params}&security=tls&fp=chrome"; fi
    else
      uri_params="${uri_params}&security=none"
    fi

    server_address="$server_addr"
    if [[ "$server_address" =~ : ]] && ! [[ "$server_address" =~ \[.*\] ]]; then server_address="[$server_address]"; fi

    uri="vless://${uuid}@${server_address}:${port}?${uri_params}#${tag_encoded}"

    # 检查冲突：按 domain/ip+port 或 tag 匹配
    conflict_idx=$(find_conflicting_node "$server_addr" "$port" "$tag" || true)
    if [ -n "$conflict_idx" ]; then
      echo "检测到与现有节点冲突（索引: $conflict_idx）。"
      echo "1) 覆盖现有节点"
      echo "2) 附加为新节点"
      echo "3) 跳过添加"
      read -p "请选择操作 (1/2/3, 默认 2 附加): " conflict_choice
      conflict_choice=${conflict_choice:-2}
      if [ "$conflict_choice" = "1" ]; then
        # 覆盖：替换该索引
        tmpfile="$(mktemp)"
        new_node_json=$(generate_node_info "$uuid" "$port" "$decryption" "$encryption" "$server_addr" "$tag" "$uri" "$server_addr" "$network" "$path" "$host" "chrome" "false" "$use_reality" "" "$sni" "[]" "" "" "$push_enabled" "" "" "[]" "" "" "" "")
        # jq 替换指定索引
        jq --argjson n "$new_node_json" --arg idx "$conflict_idx" '(.['"$conflict_idx"'] ) = $n' "$VLESS_JSON" > "$tmpfile" && mv "$tmpfile" "$VLESS_JSON"
        log "已覆盖索引 $conflict_idx 的节点。"
      elif [ "$conflict_choice" = "2" ]; then
        # 附加
        tmpfile="$(mktemp)"
        node_json=$(jq -n \
          --arg uuid "$uuid" \
          --arg port "$port" \
          --arg decryption "$decryption" \
          --arg encryption "$encryption" \
          --arg ip "$server_addr" \
          --arg tag "$tag" \
          --arg uri "$uri" \
          --arg domain "$server_addr" \
          --arg network "$network" \
          --arg path "$path" \
          --arg host "$host" \
          --arg fingerprint "chrome" \
          --argjson is_custom false \
          --argjson push_enabled false \
          '{
            uuid: $uuid,
            port: ($port|tonumber),
            decryption: $decryption,
            encryption: $encryption,
            ip: $ip,
            tag: $tag,
            uri: $uri,
            domain: $domain,
            network: $network,
            path: $path,
            host: $host,
            fingerprint: $fingerprint,
            is_custom_tag: $is_custom,
            push_enabled: $push_enabled,
            push_url: "",
            push_token: ""
          }')
        jq --argjson n "$node_json" '. += [$n]' "$VLESS_JSON" > "$tmpfile" && mv "$tmpfile" "$VLESS_JSON"
        log "已附加新节点。"
      else
        log "已跳过添加该节点。"
      fi
    else
      # 无冲突，直接追加
      tmpfile="$(mktemp)"
      node_json=$(jq -n \
        --arg uuid "$uuid" \
        --arg port "$port" \
        --arg decryption "$decryption" \
        --arg encryption "$encryption" \
        --arg ip "$server_addr" \
        --arg tag "$tag" \
        --arg uri "$uri" \
        --arg domain "$server_addr" \
        --arg network "$network" \
        --arg path "$path" \
        --arg host "$host" \
        --arg fingerprint "chrome" \
        --argjson is_custom false \
        --argjson push_enabled false \
        '{
          uuid: $uuid,
          port: ($port|tonumber),
          decryption: $decryption,
          encryption: $encryption,
          ip: $ip,
          tag: $tag,
          uri: $uri,
          domain: $domain,
          network: $network,
          path: $path,
          host: $host,
          fingerprint: $fingerprint,
          is_custom_tag: $is_custom,
          push_enabled: $push_enabled,
          push_url: "",
          push_token: ""
        }')
      jq --argjson n "$node_json" '. += [$n]' "$VLESS_JSON" > "$tmpfile" && mv "$tmpfile" "$VLESS_JSON"
      log "已添加新节点。"
    fi

    # 如果启用了 push（在本流程中默认未启用），可在此处理（保留原逻辑）
    # 调用主脚本的 regenerate_full_config/restart_xray（如果存在）
    if declare -f regenerate_full_config >/dev/null 2>&1; then regenerate_full_config; fi
    if declare -f restart_xray >/dev/null 2>&1; then restart_xray; fi

    # 询问是否继续添加另一种类型或继续添加更多节点
    echo
    echo "操作完成。"
    read -p "是否继续添加另一个节点？(Y/n): " continue_choice
    continue_choice=${continue_choice:-Y}
    if [[ $continue_choice =~ ^[Nn]$ ]]; then
      break
    fi
    # 循环继续，用户可以选择不同 network/type 等
  done

  log "退出添加节点流程。"
}

# 本地删除节点（按 tag 或 push_token）
delete_node_local() {
  local identifier="$1"
  if [ -z "$identifier" ]; then echo "Missing identifier"; return 1; fi
  if [ ! -f "$VLESS_JSON" ]; then echo "No nodes file"; return 1; fi
  jq --arg id "$identifier" 'map(select(.tag != $id and (.push_token // "") != $id))' "$VLESS_JSON" > "${VLESS_JSON}.tmp" && mv "${VLESS_JSON}.tmp" "$VLESS_JSON"
  log "已删除匹配标识: $identifier"
  if declare -f regenerate_full_config >/dev/null 2>&1; then regenerate_full_config; fi
  if declare -f restart_xray >/dev/null 2>&1; then restart_xray; fi
}

# reset_all（保留你原脚本逻辑，修复加密字段拼接的潜在问题）
reset_all() {
  if [ ! -f "$VLESS_JSON" ]; then error "未找到 $VLESS_JSON"; fi
  log "重置所有节点的 UUID 和密码..."
  nodes=$(jq -c '.[]' "$VLESS_JSON")
  new_nodes=()
  while IFS= read -r node; do
    ip=$(echo "$node" | jq -r '.ip')
    port=$(echo "$node" | jq -r '.port')
    domain=$(echo "$node" | jq -r '.domain // ""')
    network=$(echo "$node" | jq -r '.network')
    path=$(echo "$node" | jq -r '.path // ""')
    host=$(echo "$node" | jq -r '.host // ""')
    fingerprint=$(echo "$node" | jq -r '.fingerprint // "chrome"')
    is_custom=$(echo "$node" | jq -r '.is_custom_tag // false')
    use_reality=$(echo "$node" | jq -r '.use_reality // false')
    dest=$(echo "$node" | jq -r '.dest // ""')
    sni=$(echo "$node" | jq -r '.sni // ""')
    shortids_json=$(echo "$node" | jq -r '.shortIds // []')
    flow=$(echo "$node" | jq -r '.flow // ""')
    push_enabled=$(echo "$node" | jq -r '.push_enabled // false')
    push_url=$(echo "$node" | jq -r '.push_url // ""')
    push_token=$(echo "$node" | jq -r '.push_token // ""')
    servernames_json=$(echo "$node" | jq -r '.serverNames // []')
    private_key=$(echo "$node" | jq -r '.privateKey // ""')
    kex=$(echo "$node" | jq -r '.kex // ""')
    method=$(echo "$node" | jq -r '.method // ""')
    rtt=$(echo "$node" | jq -r '.rtt // ""')
    use_mlkem=$(echo "$node" | jq -r '.use_mlkem // false')

    if command -v xray &>/dev/null; then new_uuid=$(xray uuid); else new_uuid=$(cat /proc/sys/kernel/random/uuid); fi

    if [ "$use_reality" = false ]; then
      if [ "$rtt" = "0rtt" ]; then time_server="600s"; else time_server="0s"; fi
      x25519_output=$(xray x25519 2>/dev/null || true)
      private=$(echo "$x25519_output" | grep -oP '(?<=PrivateKey:).*' | sed 's/^ *//;s/ *$//' || true)
      password=$(echo "$x25519_output" | grep -oP '(?<=Password:).*' | sed 's/^ *//;s/ *$//' || true)
      seed=""; client_param=""
      if [ "$use_mlkem" = true ]; then
        mlkem_output=$(xray mlkem768 2>/dev/null || true)
        seed=$(echo "$mlkem_output" | grep -oP '(?<=Seed:).*' | sed 's/^ *//;s/ *$//' || true)
        client_param=$(echo "$mlkem_output" | grep -oP '(?<=Client:).*' | sed 's/^ *//;s/ *$//' || true)
      fi
      kex_val="${kex:-none}"; method_val="${method:-none}"
      private_val="${private:-}"; password_val="${password:-}"
      decryption="${kex_val}.${method_val}.${time_server}"
      if [ -n "$private_val" ]; then decryption="${decryption}.${private_val}"; fi
      if [ "$use_mlkem" = true ] && [ -n "$seed" ]; then decryption="${decryption}.${seed}"; fi
      encryption="${kex_val}.${method_val}.${rtt}"
      if [ -n "$password_val" ]; then encryption="${encryption}.${password_val}"; fi
      if [ "$use_mlkem" = true ] && [ -n "$client_param" ]; then encryption="${encryption}.${client_param}"; fi
    else
      x25519_output=$(xray x25519 2>/dev/null || true)
      private=$(echo "$x25519_output" | grep -oP '(?<=PrivateKey:).*' | sed 's/^ *//;s/ *$//' || true)
      password=$(echo "$x25519_output" | grep -oP '(?<=Password:).*' | sed 's/^ *//;s/ *$//' || true)
      public_key_base64="$password"
      private_key="$private"
      decryption="none"; encryption="none"
    fi

    tag=$(echo "$node" | jq -r '.tag // ""')
    if [ "$is_custom" = false ] || [ -z "$tag" ]; then
      read country city <<< $(get_location_from_ip "$ip" || echo "Unknown Unknown")
      flag="${FLAGS[$country]:-🌍}"
      tag="${flag} ${city}"
    fi

    if [ -n "$domain" ]; then server_address="$domain"; else server_address="$ip"; fi
    if [[ "$server_address" =~ : ]] && ! [[ "$server_address" =~ \[.*\] ]]; then server_address="[$server_address]"; fi

    uri_params="type=${network}&encryption=${encryption}&packetEncoding=xudp"
    if [ "$network" = "ws" ]; then
      encoded_path=$(url_encode "$path")
      encoded_host=$(url_encode "$host")
      uri_params="${uri_params}&host=${encoded_host}&path=${encoded_path}"
    fi
    if [ -n "$domain" ]; then
      uri_params="${uri_params}&security=tls&sni=${domain}&fp=${fingerprint}"
    else
      uri_params="${uri_params}&security=none"
    fi

    if [ "$use_reality" = true ]; then
      shortId=""
      if [ -n "$shortids_json" ] && [ "$shortids_json" != "null" ]; then
        shortId=$(echo "$shortids_json" | jq -r '.[0] // empty' 2>/dev/null || echo "")
      fi
      uri_params="type=tcp&encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=${fingerprint}&sid=${shortId}&pbk=${public_key_base64}&packetEncoding=xudp"
    fi

    encoded_tag=$(url_encode "$tag")
    uri="vless://${new_uuid}@${server_address}:${port}?${uri_params}#${encoded_tag}"

    new_node=$(generate_node_info "$new_uuid" "$port" "$decryption" "$encryption" "$ip" "$tag" "$uri" "$domain" "$network" "$path" "$host" "$fingerprint" "$is_custom" "$use_reality" "$dest" "$sni" "$shortids_json" "$public_key_base64" "$flow" "$push_enabled" "$push_url" "$push_token" "$servernames_json" "$private_key" "$kex" "$method" "$rtt" "$use_mlkem")
    new_nodes+=("$new_node")
  done <<< "$nodes"

  printf '%s\n' "${new_nodes[@]}" | jq -s '.' > "$VLESS_JSON"
  log "所有节点已重置并保存到 $VLESS_JSON"

  if declare -f regenerate_full_config >/dev/null 2>&1; then regenerate_full_config; fi
  if declare -f restart_xray >/dev/null 2>&1; then restart_xray 0; fi

  nodes=$(jq -c '.[]' "$VLESS_JSON")
  while IFS= read -r node; do
    push_enabled=$(echo "$node" | jq -r '.push_enabled // false')
    if [ "$push_enabled" = true ]; then
      uri=$(echo "$node" | jq -r '.uri')
      push_url=$(echo "$node" | jq -r '.push_url')
      push_token=$(echo "$node" | jq -r '.push_token')
      push_to_remote "$uri" "$push_url" "$push_token"
    fi
  done <<< "$nodes"

  if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
    echo -e "${GREEN}重置完成！${NC}"
    jq -r '.[] | .uri' "$VLESS_JSON" | while read -r u; do echo "$u"; done
  fi
}

# regenerate_full_config: 使用原脚本思路（保留 streamSettings/reality/ws 等）
# 在生成前交互式询问 DNS（回车使用默认 1.1.1.1 / 8.8.8.8）
regenerate_full_config() {
  ask_dns_interactive

  if [ -f "$GLOBAL_JSON" ]; then
    strategy=$(jq -r '.strategy // "UseIPv4"' "$GLOBAL_JSON")
    domain_strategy=$(jq -r '.domain_strategy // "UseIPv4v6"' "$GLOBAL_JSON")
  else
    strategy="UseIPv4"
    domain_strategy="UseIPv4v6"
  fi

  if [ ! -f "$VLESS_JSON" ]; then
    log "未找到 $VLESS_JSON，跳过 regenerate_full_config"
    return
  fi

  nodes=$(jq -c '.[]' "$VLESS_JSON")
  inbounds_json="[]"
  while IFS= read -r node; do
    port=$(echo "$node" | jq -r '.port')
    uuid=$(echo "$node" | jq -r '.uuid')
    network=$(echo "$node" | jq -r '.network')
    path=$(echo "$node" | jq -r '.path // ""')
    host=$(echo "$node" | jq -r '.host // ""')
    fingerprint=$(echo "$node" | jq -r '.fingerprint // "chrome"')
    use_reality=$(echo "$node" | jq -r '.use_reality // false')
    dest=$(echo "$node" | jq -r '.dest // ""')
    servernames_json=$(echo "$node" | jq -r '.serverNames // []')
    private_key=$(echo "$node" | jq -r '.privateKey // ""')
    shortids_json=$(echo "$node" | jq -r '.shortIds // []')
    flow=$(echo "$node" | jq -r '.flow // ""')
    domain=$(echo "$node" | jq -r '.domain // ""')

    if [ "$use_reality" = true ]; then
      inbound=$(jq -n \
        --arg port "$port" \
        --arg uuid "$uuid" \
        --arg dest "$dest" \
        --argjson serverNames "$servernames_json" \
        --arg privateKey "$private_key" \
        --argjson shortIds "$shortids_json" \
        --arg fingerprint "$fingerprint" \
        --arg flow "$flow" \
        '{
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": {
            "clients": [
              {
                "id": $uuid,
                "flow": $flow
              }
            ],
            "decryption": "none"
          },
          "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
              "dest": $dest,
              "serverNames": $serverNames,
              "privateKey": $privateKey,
              "shortIds": $shortIds,
              "fingerprint": $fingerprint
            }
          },
          "tag": $uuid
        }')
    else
      if [ "$network" = "ws" ]; then
        streamSettings=$(jq -n --arg path "$path" --arg host "$host" '{
          "network":"ws",
          "wsSettings": {
            "path": $path,
            "headers": {"Host": $host}
          }
        }')
      else
        streamSettings=$(jq -n --arg network "$network" '{
          "network": $network
        }')
      fi

      inbound=$(jq -n \
        --arg port "$port" \
        --arg uuid "$uuid" \
        --arg fingerprint "$fingerprint" \
        --argjson streamSettings "$streamSettings" \
        '{
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": {
            "clients": [
              {
                "id": $uuid
              }
            ],
            "decryption": "none"
          },
          "streamSettings": $streamSettings,
          "tag": $uuid
        }')
    fi

    inbounds_json=$(jq -s '.[0] + [.[1]]' <(echo "$inbounds_json") <(echo "$inbound"))
  done <<< "$nodes"

  DNS_PRIMARY=${DNS_PRIMARY:-"1.1.1.1"}
  DNS_SECONDARY=${DNS_SECONDARY:-"8.8.8.8"}

  cat > "$CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": ["${DNS_PRIMARY}","${DNS_SECONDARY}"]
  },
  "inbounds": $(echo "$inbounds_json" | jq -c '.'),
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

  log "已根据 $VLESS_JSON 生成 $CONFIG（DNS: ${DNS_PRIMARY} 主, ${DNS_SECONDARY} 备用）。"
}

# 如果脚本被直接执行，打印可用函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "vless_encryption.sh - 可用函数：add_vless, delete_node_local, reset_all, regenerate_full_config, generate_node_info, push_to_remote"
  exit 0
fi