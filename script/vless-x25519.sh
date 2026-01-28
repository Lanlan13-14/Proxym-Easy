#!/usr/bin/env bash
# vless-x25519.sh
# 作用：交互式添加 VLESS + x25519 入站（写入 /etc/xray 顶层 JSON 文件）
# 支持：添加节点（默认）与 reset（删除本协议入站文件）
set -euo pipefail
export LC_ALL=C.UTF-8

XRAY_DIR="/etc/xray"
VLESS_JSON="/etc/proxym/vless.json"
PROTOCOL="x25519"

# 完整国家代码到旗帜与三字码映射（ISO 3166-1 alpha-2 -> emoji flag; alpha-3）
declare -A FLAGS=(
  [AF]="🇦🇫" [AX]="🇦🇽" [AL]="🇦🇱" [DZ]="🇩🇿" [AS]="🇦🇸" [AD]="🇦🇩" [AO]="🇦🇴" [AI]="🇦🇮"
  [AQ]="🇦🇶" [AG]="🇦🇬" [AR]="🇦🇷" [AM]="🇦🇲" [AW]="🇦🇼" [AU]="🇦🇺" [AT]="🇦🇹" [AZ]="🇦🇿"
  [BS]="🇧🇸" [BH]="🇧🇭" [BD]="🇧🇩" [BB]="🇧🇧" [BY]="🇧🇾" [BE]="🇧🇪" [BZ]="🇧🇿" [BJ]="🇧🇯"
  [BM]="🇧🇲" [BT]="🇧🇹" [BO]="🇧🇴" [BQ]="🇧🇶" [BA]="🇧🇦" [BW]="🇧🇼" [BV]="🇧🇻" [BR]="🇧🇷"
  [IO]="🇮🇴" [BN]="🇧🇳" [BG]="🇧🇬" [BF]="🇧🇫" [BI]="🇧🇮" [CV]="🇨🇻" [KH]="🇰🇭" [CM]="🇨🇲"
  [CA]="🇨🇦" [KY]="🇰🇾" [CF]="🇨🇫" [TD]="🇹🇩" [CL]="🇨🇱" [CN]="🇨🇳" [CX]="🇨🇽" [CC]="🇨🇨"
  [CO]="🇨🇴" [KM]="🇰🇲" [CG]="🇨🇬" [CD]="🇨🇩" [CK]="🇨🇰" [CR]="🇨🇷" [CI]="🇨🇮" [HR]="🇭🇷"
  [CU]="🇨🇺" [CW]="🇨🇼" [CY]="🇨🇾" [CZ]="🇨🇿" [DK]="🇩🇰" [DJ]="🇩🇯" [DM]="🇩🇲" [DO]="🇩🇴"
  [EC]="🇪🇨" [EG]="🇪🇬" [SV]="🇸🇻" [GQ]="🇬🇶" [ER]="🇪🇷" [EE]="🇪🇪" [SZ]="🇸🇿" [ET]="🇪🇹"
  [FK]="🇫🇰" [FO]="🇫🇴" [FJ]="🇫🇯" [FI]="🇫🇮" [FR]="🇫🇷" [GF]="🇬🇫" [PF]="🇵🇫" [TF]="🇹🇫"
  [GA]="🇬🇦" [GM]="🇬🇲" [GE]="🇬🇪" [DE]="🇩🇪" [GH]="🇬🇭" [GI]="🇬🇮" [GR]="🇬🇷" [GL]="🇬🇱"
  [GD]="🇬🇩" [GP]="🇬🇵" [GU]="🇬🇺" [GT]="🇬🇹" [GG]="🇬🇬" [GN]="🇬🇳" [GW]="🇬🇼" [GY]="🇬🇾"
  [HT]="🇭🇹" [HM]="🇭🇲" [VA]="🇻🇦" [HN]="🇭🇳" [HK]="🇭🇰" [HU]="🇭🇺" [IS]="🇮🇸" [IN]="🇮🇳"
  [ID]="🇮🇩" [IR]="🇮🇷" [IQ]="🇮🇶" [IE]="🇮🇪" [IM]="🇮🇲" [IL]="🇮🇱" [IT]="🇮🇹" [JM]="🇯🇲"
  [JP]="🇯🇵" [JE]="🇯🇪" [JO]="🇯🇴" [KZ]="🇰🇿" [KE]="🇰🇪" [KI]="🇰🇮" [KP]="🇰🇵" [KR]="🇰🇷"
  [KW]="🇰🇼" [KG]="🇰🇬" [LA]="🇱🇦" [LV]="🇱🇻" [LB]="🇱🇧" [LS]="🇱🇸" [LR]="🇱🇷" [LY]="🇱🇾"
  [LI]="🇱🇮" [LT]="🇱🇹" [LU]="🇱🇺" [MO]="🇲🇴" [MG]="🇲🇬" [MW]="🇲🇼" [MY]="🇲🇾" [MV]="🇲🇻"
  [ML]="🇲🇱" [MT]="🇲🇹" [MH]="🇲🇭" [MQ]="🇲🇶" [MR]="🇲🇷" [MU]="🇲🇺" [YT]="🇾🇹" [MX]="🇲🇽"
  [FM]="🇫🇲" [MD]="🇲🇩" [MC]="🇲🇨" [MN]="🇲🇳" [ME]="🇲🇪" [MS]="🇲🇸" [MA]="🇲🇦" [MZ]="🇲🇿"
  [MM]="🇲🇲" [NA]="🇳🇦" [NR]="🇳🇷" [NP]="🇳🇵" [NL]="🇳🇱" [NC]="🇳🇨" [NZ]="🇳🇿" [NI]="🇳🇮"
  [NE]="🇳🇪" [NG]="🇳🇬" [NU]="🇳🇺" [NF]="🇳🇫" [MK]="🇲🇰" [MP]="🇲🇵" [NO]="🇳🇴" [OM]="🇴🇲"
  [PK]="🇵🇰" [PW]="🇵🇼" [PS]="🇵🇸" [PA]="🇵🇦" [PG]="🇵🇬" [PY]="🇵🇾" [PE]="🇵🇪" [PH]="🇵🇭"
  [PN]="🇵🇳" [PL]="🇵🇱" [PT]="🇵🇹" [PR]="🇵🇷" [QA]="🇶🇦" [RE]="🇷🇪" [RO]="🇷🇴" [RU]="🇷🇺"
  [RW]="🇷🇼" [BL]="🇧🇱" [SH]="🇸🇭" [KN]="🇰🇳" [LC]="🇱🇨" [MF]="🇲🇫" [PM]="🇵🇲" [VC]="🇻🇨"
  [WS]="🇼🇸" [SM]="🇸🇲" [ST]="🇸🇹" [SA]="🇸🇦" [SN]="🇸🇳" [RS]="🇷🇸" [SC]="🇸🇨" [SL]="🇸🇱"
  [SG]="🇸🇬" [SX]="🇸🇽" [SK]="🇸🇰" [SI]="🇸🇮" [SB]="🇸🇧" [SO]="🇸🇴" [ZA]="🇿🇦" [GS]="🇬🇸"
  [SS]="🇸🇸" [ES]="🇪🇸" [LK]="🇱🇰" [SD]="🇸🇩" [SR]="🇸🇷" [SJ]="🇸🇯" [SE]="🇸🇪" [CH]="🇨🇭"
  [SY]="🇸🇾" [TW]="🇹🇼" [TJ]="🇹🇯" [TZ]="🇹🇿" [TH]="🇹🇭" [TL]="🇹🇱" [TG]="🇹🇬" [TK]="🇹🇰"
  [TO]="🇹🇴" [TT]="🇹🇹" [TN]="🇹🇳" [TR]="🇹🇷" [TM]="🇹🇲" [TC]="🇹🇨" [TV]="🇹🇻" [UG]="🇺🇬"
  [UA]="🇺🇦" [AE]="🇦🇪" [GB]="🇬🇧" [US]="🇺🇸" [UM]="🇺🇲" [UY]="🇺🇾" [UZ]="🇺🇿" [VU]="🇻🇺"
  [VE]="🇻🇪" [VN]="🇻🇳" [VG]="🇻🇬" [VI]="🇻🇮" [WF]="🇼🇫" [EH]="🇪🇭" [YE]="🇾🇪" [ZM]="🇿🇲"
  [ZW]="🇿🇼"
)

declare -A ALPHA3=(
  [AF]="AFG" [AX]="ALA" [AL]="ALB" [DZ]="DZA" [AS]="ASM" [AD]="AND" [AO]="AGO" [AI]="AIA"
  [AQ]="ATA" [AG]="ATG" [AR]="ARG" [AM]="ARM" [AW]="ABW" [AU]="AUS" [AT]="AUT" [AZ]="AZE"
  [BS]="BHS" [BH]="BHR" [BD]="BGD" [BB]="BRB" [BY]="BLR" [BE]="BEL" [BZ]="BLZ" [BJ]="BEN"
  [BM]="BMU" [BT]="BTN" [BO]="BOL" [BQ]="BES" [BA]="BIH" [BW]="BWA" [BV]="BVT" [BR]="BRA"
  [IO]="IOT" [BN]="BRN" [BG]="BGR" [BF]="BFA" [BI]="BDI" [CV]="CPV" [KH]="KHM" [CM]="CMR"
  [CA]="CAN" [KY]="CYM" [CF]="CAF" [TD]="TCD" [CL]="CHL" [CN]="CHN" [CX]="CXR" [CC]="CCK"
  [CO]="COL" [KM]="COM" [CG]="COG" [CD]="COD" [CK]="COK" [CR]="CRI" [CI]="CIV" [HR]="HRV"
  [CU]="CUB" [CW]="CUW" [CY]="CYP" [CZ]="CZE" [DK]="DNK" [DJ]="DJI" [DM]="DMA" [DO]="DOM"
  [EC]="ECU" [EG]="EGY" [SV]="SLV" [GQ]="GNQ" [ER]="ERI" [EE]="EST" [SZ]="SWZ" [ET]="ETH"
  [FK]="FLK" [FO]="FRO" [FJ]="FJI" [FI]="FIN" [FR]="FRA" [GF]="GUF" [PF]="PYF" [TF]="ATF"
  [GA]="GAB" [GM]="GMB" [GE]="GEO" [DE]="DEU" [GH]="GHA" [GI]="GIB" [GR]="GRC" [GL]="GRL"
  [GD]="GRD" [GP]="GLP" [GU]="GUM" [GT]="GTM" [GG]="GGY" [GN]="GIN" [GW]="GNB" [GY]="GUY"
  [HT]="HTI" [HM]="HMD" [VA]="VAT" [HN]="HND" [HK]="HKG" [HU]="HUN" [IS]="ISL" [IN]="IND"
  [ID]="IDN" [IR]="IRN" [IQ]="IRQ" [IE]="IRL" [IM]="IMN" [IL]="ISR" [IT]="ITA" [JM]="JAM"
  [JP]="JPN" [JE]="JEY" [JO]="JOR" [KZ]="KAZ" [KE]="KEN" [KI]="KIR" [KP]="PRK" [KR]="KOR"
  [KW]="KWT" [KG]="KGZ" [LA]="LAO" [LV]="LVA" [LB]="LBN" [LS]="LSO" [LR]="LBR" [LY]="LBY"
  [LI]="LIE" [LT]="LTU" [LU]="LUX" [MO]="MAC" [MG]="MDG" [MW]="MWI" [MY]="MYS" [MV]="MDV"
  [ML]="MLI" [MT]="MLT" [MH]="MHL" [MQ]="MTQ" [MR]="MRT" [MU]="MUS" [YT]="MYT" [MX]="MEX"
  [FM]="FSM" [MD]="MDA" [MC]="MCO" [MN]="MNG" [ME]="MNE" [MS]="MSR" [MA]="MAR" [MZ]="MOZ"
  [MM]="MMR" [NA]="NAM" [NR]="NRU" [NP]="NPL" [NL]="NLD" [NC]="NCL" [NZ]="NZL" [NI]="NIC"
  [NE]="NER" [NG]="NGA" [NU]="NIU" [NF]="NFK" [MK]="MKD" [MP]="MNP" [NO]="NOR" [OM]="OMN"
  [PK]="PAK" [PW]="PLW" [PS]="PSE" [PA]="PAN" [PG]="PNG" [PY]="PRY" [PE]="PER" [PH]="PHL"
  [PN]="PCN" [PL]="POL" [PT]="PRT" [PR]="PRI" [QA]="QAT" [RE]="REU" [RO]="ROU" [RU]="RUS"
  [RW]="RWA" [BL]="BLM" [SH]="SHN" [KN]="KNA" [LC]="LCA" [MF]="MAF" [PM]="SPM" [VC]="VCT"
  [WS]="WSM" [SM]="SMR" [ST]="STP" [SA]="SAU" [SN]="SEN" [RS]="SRB" [SC]="SYC" [SL]="SLE"
  [SG]="SGP" [SX]="SXM" [SK]="SVK" [SI]="SVN" [SB]="SLB" [SO]="SOM" [ZA]="ZAF" [GS]="SGS"
  [SS]="SSD" [ES]="ESP" [LK]="LKA" [SD]="SDN" [SR]="SUR" [SJ]="SJM" [SE]="SWE" [CH]="CHE"
  [SY]="SYR" [TW]="TWN" [TJ]="TJK" [TZ]="TZA" [TH]="THA" [TL]="TLS" [TG]="TGO" [TK]="TKL"
  [TO]="TON" [TT]="TTO" [TN]="TUN" [TR]="TUR" [TM]="TKM" [TC]="TCA" [TV]="TUV" [UG]="UGA"
  [UA]="UKR" [AE]="ARE" [GB]="GBR" [US]="USA" [UM]="UMI" [UY]="URY" [UZ]="UZB" [VU]="VUT"
  [VE]="VEN" [VN]="VNM" [VG]="VGB" [VI]="VIR" [WF]="WLF" [EH]="ESH" [YE]="YEM" [ZM]="ZMB"
  [ZW]="ZWE"
)

# Utilities
ensure_dirs(){
  sudo mkdir -p "$XRAY_DIR"
  sudo mkdir -p "$(dirname "$VLESS_JSON")"
  if [ ! -f "$VLESS_JSON" ]; then echo "[]" | sudo tee "$VLESS_JSON" >/dev/null; fi
}

detect_public_ipv4(){
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip=$(curl -s4 --max-time 5 https://api.ipify.org || true)
  fi
  if [ -z "$ip" ] && command -v wget >/dev/null 2>&1; then
    ip=$(wget -qO- --timeout=5 https://api.ipify.org || true)
  fi
  echo "$ip"
}

get_geo_from_ip(){
  local ip="$1"
  if [ -z "$ip" ]; then echo "||"; return; fi
  if command -v curl >/dev/null 2>&1; then
    local res
    res=$(curl -s --max-time 6 "http://ip-api.com/json/${ip}?fields=status,countryCode,city" || true)
    if [ -z "$res" ]; then echo "||"; return; fi
    local status cc city
    status=$(echo "$res" | grep -o '"status":"[^"]*"' | sed 's/.*"status":"\([^"]*\)".*/\1/')
    if [ "$status" != "success" ]; then echo "||"; return; fi
    cc=$(echo "$res" | grep -o '"countryCode":"[^"]*"' | sed 's/.*"countryCode":"\([^"]*\)".*/\1/')
    city=$(echo "$res" | grep -o '"city":"[^"]*"' | sed 's/.*"city":"\([^"]*\)".*/\1/')
    echo "${cc}|${city}"
    return
  fi
  echo "||"
}

country_flag(){ local cc="$1"; cc=$(echo "$cc" | tr '[:lower:]' '[:upper:]'); echo "${FLAGS[$cc]:-🌍}"; }
alpha3_from_cc(){ local cc="$1"; cc=$(echo "$cc" | tr '[:lower:]' '[:upper:]'); echo "${ALPHA3[$cc]:-$cc}"; }

url_encode(){
  local s="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PY "$s"
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
  else
    printf '%s' "$s" | sed -e 's/ /%20/g' -e 's/#/%23/g'
  fi
}

generate_uuid(){
  if command -v xray >/dev/null 2>&1; then xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; else cat /proc/sys/kernel/random/uuid; fi
}

random_port(){
  while :; do
    local p=$(( (RANDOM % 40000) + 10000 ))
    if ! ss -tuln 2>/dev/null | awk '{print $5}' | grep -q ":${p}\$"; then
      echo "$p"; return
    fi
  done
}

random_password(){
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 8 2>/dev/null || echo "pass$(date +%s)"; else echo "pass$RANDOM$RANDOM"; fi
}

# x25519 inbound JSON（顶层片段）
generate_inbound_json(){
  local uuid="$1" port="$2" network="$3" path="$4" host="$5"
  if [ "$network" = "ws" ]; then
    jq -n --arg port "$port" --arg uuid "$uuid" --arg path "$path" --arg host "$host" '{
      "inbounds": [
        {
          "tag": ("vless-x25519-" + ($port|tostring)),
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": { "clients":[{"id": $uuid}], "decryption":"none" },
          "streamSettings": { "network":"ws", "wsSettings": {"path": $path, "headers":{"Host": $host}} }
        }
      ]
    }'
  else
    jq -n --arg port "$port" --arg uuid "$uuid" '{
      "inbounds": [
        {
          "tag": ("vless-x25519-" + ($port|tostring)),
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": { "clients":[{"id": $uuid}], "decryption":"none" },
          "streamSettings": { "network":"tcp" }
        }
      ]
    }'
  fi
}

append_or_update_vless_json(){
  local node_json="$1"
  ensure_dirs
  local uuid; uuid=$(echo "$node_json" | jq -r '.uuid')
  if jq -e --arg u "$uuid" '.[] | select(.uuid == $u)' "$VLESS_JSON" >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --argjson n "$node_json" 'map(if .uuid == $n.uuid then $n else . end)' "$VLESS_JSON" > "$tmp" && sudo mv "$tmp" "$VLESS_JSON"
  else
    tmp=$(mktemp)
    jq --argjson n "$node_json" '. += [$n]' "$VLESS_JSON" > "$tmp" && sudo mv "$tmp" "$VLESS_JSON"
  fi
}

write_inbound_file(){
  local fname="$1" content="$2"
  sudo mkdir -p "$XRAY_DIR"
  printf '%s\n' "$content" | sudo tee "${XRAY_DIR}/${fname}" >/dev/null
}

add_node_interactive(){
  ensure_dirs
  echo "添加 VLESS + x25519 节点（仅 x25519）"

  pubip=$(detect_public_ipv4)
  probe_ip="$pubip"
  geo=$(get_geo_from_ip "$probe_ip")
  cc=$(echo "$geo" | cut -d'|' -f1)
  city=$(echo "$geo" | cut -d'|' -f2)
  cc=${cc:-""}
  city=${city:-"Unknown"}

  port=$(random_port)
  echo "随机选择端口: $port"
  read -p "是否修改端口? 输入新端口或回车保持 [$port]: " p2
  port=${p2:-$port}

  read -p "网络类型 (tcp/ws) [tcp]: " network
  network=${network:-tcp}
  path=""; host=""
  if [ "$network" = "ws" ]; then
    read -p "Path (留空自动生成): " path
    if [ -z "$path" ]; then path="/$(openssl rand -hex 5 2>/dev/null || echo p$(date +%s))"; fi
    read -p "Host (留空使用公网 IP/域名): " host
    host=${host:-$pubip}
  fi

  flag=$(country_flag "$cc")
  alpha3=$(alpha3_from_cc "$cc")
  default_name="${flag} ${alpha3} ${city}"
  read -p "自定义节点名称（留空使用 ${default_name}）: " name
  name=${name:-$default_name}

  uuid=$(generate_uuid)
  pass=$(random_password)
  name_enc=$(url_encode "$name")

  uri="vless://${uuid}@${pubip}:${port}?type=${network}&encryption=x25519&security=none&psk=${pass}#${name_enc}"

  inbound_json=$(generate_inbound_json "$uuid" "$port" "$network" "$path" "$host")
  fname="$(printf '%02d' $((RANDOM%90+1)))-vless-x25519-${port}.json"
  write_inbound_file "$fname" "$inbound_json"

  node_json=$(jq -n \
    --arg uuid "$uuid" \
    --arg port "$port" \
    --arg ip "$pubip" \
    --arg tag "$name" \
    --arg uri "$uri" \
    --arg domain "$pubip" \
    --arg network "$network" \
    --arg path "$path" \
    --arg host "$host" \
    --arg fingerprint "chrome" \
    --arg kex "x25519" \
    --arg method "x25519" \
    --arg rtt "" \
    --argjson use_mlkem false \
    '{
      uuid:$uuid, port:($port|tonumber), decryption:"none", encryption:"x25519", ip:$ip, tag:$tag, uri:$uri, domain:$domain, network:$network, path:$path, host:$host, fingerprint:$fingerprint, is_custom_tag:false, push_enabled:false, push_url:"", push_token:"", kex:$kex, method:$method, rtt:$rtt, use_mlkem:$use_mlkem }')

  append_or_update_vless_json "$node_json"

  echo
  echo "已写入入站文件: ${XRAY_DIR}/${fname}"
  echo "VLESS x25519 URI:"
  echo "$uri"
  echo
  echo "提示：请运行 'sudo xray test -confdir /etc/xray' 验证配置，或重启 Xray：sudo systemctl restart xray"
}

reset_only(){
  ensure_dirs
  sudo rm -f "${XRAY_DIR}"/*vless-x25519-*.json 2>/dev/null || true
  echo "已删除所有 x25519 入站文件（仅本协议）。"
}

case "${1:-}" in
  reset) reset_only ;;
  *) add_node_interactive ;;
esac