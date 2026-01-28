#!/usr/bin/env bash
# vless-mlkem.sh
# 只负责 VLESS + MLKEM（抗量子）入站文件（mlkem_<port>.json）与对应节点记录（/etc/proxym/vless.json）
# 要求：
#  - 仅包含 mlkem 或 mlkem+reality 相关字段（不出现 x25519 字段）
#  - 端口随机选择空闲端口（可由用户覆盖）
#  - UUID 与密码自动生成，节点名称自动生成：国旗 + 三字码 + 城市
#  - 自动优先检测公网 IPv4 并做地理探测
#  - 支持交互式添加（默认）与 reset（仅删除 mlkem_* 文件）
set -euo pipefail
export LC_ALL=C.UTF-8

VLESS_JSON="/etc/proxym/vless.json"
INBOUNDS_DIR="/etc/xray/inbounds.d"
PROTOCOL="mlkem"

# ---------------------------
# 完整国旗映射（ISO alpha-2 -> emoji）
# ---------------------------
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

# ---------------------------
# ISO alpha-2 -> alpha-3 映射（完整）
# ---------------------------
declare -A ALPHA3=(
  [AD]="AND" [AE]="ARE" [AF]="AFG" [AG]="ATG" [AI]="AIA"
  [AL]="ALB" [AM]="ARM" [AO]="AGO" [AR]="ARG" [AS]="ASM"
  [AT]="AUT" [AU]="AUS" [AW]="ABW" [AX]="ALA" [AZ]="AZE"
  [BA]="BIH" [BB]="BRB" [BD]="BGD" [BE]="BEL" [BF]="BFA"
  [BG]="BGR" [BH]="BHR" [BI]="BDI" [BJ]="BEN" [BL]="BLM"
  [BM]="BMU" [BN]="BRN" [BO]="BOL" [BQ]="BES" [BR]="BRA"
  [BS]="BHS" [BT]="BTN" [BV]="BVT" [BW]="BWA" [BY]="BLR"
  [BZ]="BLZ" [CA]="CAN" [CC]="CCK" [CD]="COD" [CF]="CAF"
  [CG]="COG" [CH]="CHE" [CI]="CIV" [CK]="COK" [CL]="CHL"
  [CM]="CMR" [CN]="CHN" [CO]="COL" [CR]="CRI" [CU]="CUB"
  [CV]="CPV" [CW]="CUW" [CX]="CXR" [CY]="CYP" [CZ]="CZE"
  [DE]="DEU" [DJ]="DJI" [DK]="DNK" [DM]="DMA" [DO]="DOM"
  [DZ]="DZA" [EC]="ECU" [EE]="EST" [EG]="EGY" [EH]="ESH"
  [ER]="ERI" [ES]="ESP" [ET]="ETH" [FI]="FIN" [FJ]="FJI"
  [FK]="FLK" [FM]="FSM" [FO]="FRO" [FR]="FRA" [GA]="GAB"
  [GB]="GBR" [GD]="GRD" [GE]="GEO" [GF]="GUF" [GG]="GGY"
  [GH]="GHA" [GI]="GIB" [GL]="GRL" [GM]="GMB" [GN]="GIN"
  [GP]="GLP" [GQ]="GNQ" [GR]="GRC" [GS]="SGS" [GT]="GTM"
  [GU]="GUM" [GW]="GNB" [GY]="GUY" [HK]="HKG" [HM]="HMD"
  [HN]="HND" [HR]="HRV" [HT]="HTI" [HU]="HUN" [ID]="IDN"
  [IE]="IRL" [IL]="ISR" [IM]="IMN" [IN]="IND" [IO]="IOT"
  [IQ]="IRQ" [IR]="IRN" [IS]="ISL" [IT]="ITA" [JE]="JEY"
  [JM]="JAM" [JO]="JOR" [JP]="JPN" [KE]="KEN" [KG]="KGZ"
  [KH]="KHM" [KI]="KIR" [KM]="COM" [KN]="KNA" [KP]="PRK"
  [KR]="KOR" [KW]="KWT" [KY]="CYM" [KZ]="KAZ" [LA]="LAO"
  [LB]="LBN" [LC]="LCA" [LI]="LIE" [LK]="LKA" [LR]="LBR"
  [LS]="LSO" [LT]="LTU" [LU]="LUX" [LV]="LVA" [LY]="LBY"
  [MA]="MAR" [MC]="MCO" [MD]="MDA" [ME]="MNE" [MF]="MAF"
  [MG]="MDG" [MH]="MHL" [MK]="MKD" [ML]="MLI" [MM]="MMR"
  [MN]="MNG" [MO]="MAC" [MP]="MNP" [MQ]="MTQ" [MR]="MRT"
  [MS]="MSR" [MT]="MLT" [MU]="MUS" [MV]="MDV" [MW]="MWI"
  [MX]="MEX" [MY]="MYS" [MZ]="MOZ" [NA]="NAM" [NC]="NCL"
  [NE]="NER" [NF]="NFK" [NG]="NGA" [NI]="NIC" [NL]="NLD"
  [NO]="NOR" [NP]="NPL" [NR]="NRU" [NU]="NIU" [NZ]="NZL"
  [OM]="OMN" [PA]="PAN" [PE]="PER" [PF]="PYF" [PG]="PNG"
  [PH]="PHL" [PK]="PAK" [PL]="POL" [PM]="SPM" [PN]="PCN"
  [PR]="PRI" [PS]="PSE" [PT]="PRT" [PW]="PLW" [PY]="PRY"
  [QA]="QAT" [RE]="REU" [RO]="ROU" [RS]="SRB" [RU]="RUS"
  [RW]="RWA" [SA]="SAU" [SB]="SLB" [SC]="SYC" [SD]="SDN"
  [SE]="SWE" [SG]="SGP" [SH]="SHN" [SI]="SVN" [SJ]="SJM"
  [SK]="SVK" [SL]="SLE" [SM]="SMR" [SN]="SEN" [SO]="SOM"
  [SR]="SUR" [SS]="SSD" [ST]="STP" [SV]="SLV" [SX]="SXM"
  [SY]="SYR" [SZ]="SWZ" [TC]="TCA" [TD]="TCD" [TF]="ATF"
  [TG]="TGO" [TH]="THA" [TJ]="TJK" [TK]="TKL" [TL]="TLS"
  [TM]="TKM" [TN]="TUN" [TO]="TON" [TR]="TUR" [TT]="TTO"
  [TV]="TUV" [TW]="TWN" [TZ]="TZA" [UA]="UKR" [UG]="UGA"
  [UM]="UMI" [US]="USA" [UY]="URY" [UZ]="UZB" [VA]="VAT"
  [VC]="VCT" [VE]="VEN" [VG]="VGB" [VI]="VIR" [VN]="VNM"
  [VU]="VUT" [WF]="WLF" [WS]="WSM" [YE]="YEM" [YT]="MYT"
  [ZA]="ZAF" [ZM]="ZMB" [ZW]="ZWE"
)

# ---------------------------
# 工具函数
# ---------------------------
ensure_dirs(){
  sudo mkdir -p "$INBOUNDS_DIR"
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
    local status
    status=$(echo "$res" | grep -o '"status":"[^"]*"' | sed 's/.*"status":"\([^"]*\)".*/\1/')
    if [ "$status" != "success" ]; then echo "||"; return; fi
    local cc city
    cc=$(echo "$res" | grep -o '"countryCode":"[^"]*"' | sed 's/.*"countryCode":"\([^"]*\)".*/\1/')
    city=$(echo "$res" | grep -o '"city":"[^"]*"' | sed 's/.*"city":"\([^"]*\)".*/\1/')
    echo "${cc}|${city}"
    return
  fi
  echo "||"
}

country_flag(){
  local cc="$1"
  cc=$(echo "$cc" | tr '[:lower:]' '[:upper:]')
  echo "${FLAGS[$cc]:-🌍}"
}

alpha3_from_cc(){
  local cc="$1"
  cc=$(echo "$cc" | tr '[:lower:]' '[:upper:]')
  echo "${ALPHA3[$cc]:-$cc}"
}

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
  if command -v xray >/dev/null 2>&1; then
    xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
  else
    cat /proc/sys/kernel/random/uuid
  fi
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

# mlkem inbound JSON（支持 reality 模式或普通 tcp/ws）
generate_inbound_json(){
  local uuid="$1" port="$2" use_reality="$3" dest="$4" sni="$5" privateKey="$6" shortId="$7" network="$8" path="$9" host="${10}" fp="${11}"
  if [ "$use_reality" = "true" ]; then
    jq -n --arg port "$port" --arg uuid "$uuid" --arg dest "$dest" --arg sni "$sni" --arg privateKey "$privateKey" --arg shortId "$shortId" --arg fp "$fp" '{
      "port": ($port|tonumber),
      "protocol": "vless",
      "settings": { "clients":[{"id":$uuid}], "decryption":"none" },
      "streamSettings": { "network":"tcp", "security":"reality", "realitySettings": { "dest": $dest, "serverNames": [$sni], "privateKey": $privateKey, "shortIds": [$shortId], "fingerprint": $fp } },
      "tag": $uuid }'
  else
    if [ "$network" = "ws" ]; then
      jq -n --arg port "$port" --arg uuid "$uuid" --arg path "$path" --arg host "$host" '{
        "port": ($port|tonumber),
        "protocol": "vless",
        "settings": { "clients":[{"id": $uuid}], "decryption":"none" },
        "streamSettings": { "network":"ws", "wsSettings": {"path": $path, "headers":{"Host": $host}} },
        "tag": $uuid }'
    else
      jq -n --arg port "$port" --arg uuid "$uuid" '{
        "port": ($port|tonumber),
        "protocol": "vless",
        "settings": { "clients":[{"id": $uuid}], "decryption":"none" },
        "streamSettings": { "network":"tcp" },
        "tag": $uuid }'
    fi
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
  sudo mkdir -p "$INBOUNDS_DIR"
  printf '%s\n' "$content" | sudo tee "${INBOUNDS_DIR}/${fname}" >/dev/null
}

# ---------------------------
# 主流程：添加节点（交互式）
# ---------------------------
ensure_dirs

add_node_interactive(){
  echo "添加 VLESS + MLKEM 节点（仅 mlkem）"

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

  read -p "是否使用 reality 模式? (Y/n): " r
  r=${r:-Y}
  if [[ $r =~ ^[Nn]$ ]]; then use_reality="false"; else use_reality="true"; fi

  dest="${pubip}:443"
  read -p "dest (host:port) [默认 ${dest}]: " dest_in
  dest=${dest_in:-$dest}

  read -p "SNI（留空使用 ${pubip}）: " sni
  sni=${sni:-$pubip}

  read -p "fingerprint (默认 chrome): " fp
  fp=${fp:-chrome}

  flag=$(country_flag "$cc")
  alpha3=$(alpha3_from_cc "$cc")
  default_name="${flag} ${alpha3} ${city}"
  read -p "自定义节点名称（留空使用 ${default_name}）: " name
  name=${name:-$default_name}

  uuid=$(generate_uuid)
  shortid=$(random_password) # 用作短 id 或密码
  privateKey=""
  if command -v xray >/dev/null 2>&1; then
    mlout=$(xray mlkem768 2>/dev/null || true)
    privateKey=$(echo "$mlout" | grep -oP '(?<=Private:).*' | sed 's/^ *//;s/ *$//' || true)
  fi

  name_enc=$(url_encode "$name")
  sni_enc=$(url_encode "$sni")

  if [ "$use_reality" = "true" ]; then
    uri="vless://${uuid}@${pubip}:${port}?type=tcp&security=reality&encryption=none&sni=${sni_enc}&fp=${fp}&pbk=&packetEncoding=xudp#${name_enc}"
  else
    uri="vless://${uuid}@${pubip}:${port}?type=tcp&security=none&encryption=mlkem&psk=${shortid}#${name_enc}"
  fi

  inbound_json=$(generate_inbound_json "$uuid" "$port" "$use_reality" "$dest" "$sni" "$privateKey" "$shortid" "tcp" "" "" "$fp")
  fname="${PROTOCOL}_${port}.json"
  write_inbound_file "$fname" "$inbound_json"

  node_json=$(jq -n \
    --arg uuid "$uuid" \
    --arg port "$port" \
    --arg ip "$pubip" \
    --arg tag "$name" \
    --arg uri "$uri" \
    --arg domain "$pubip" \
    --arg network "tcp" \
    --arg path "" \
    --arg host "" \
    --arg fingerprint "$fp" \
    --arg privateKey "$privateKey" \
    --arg shortid "$shortid" \
    --argjson use_mlkem true \
    --argjson use_reality "$([ "$use_reality" = "true" ] && echo true || echo false)" \
    '{
      uuid:$uuid, port:($port|tonumber), decryption:"none", encryption:"none", ip:$ip, tag:$tag, uri:$uri, domain:$domain, network:$network, path:$path, host:$host, fingerprint:$fingerprint, is_custom_tag:false, push_enabled:false, push_url:"", push_token:"", privateKey:$privateKey, shortId:$shortid, use_mlkem:$use_mlkem, use_reality:$use_reality }')

  append_or_update_vless_json "$node_json"

  echo
  echo "已写入入站文件: ${INBOUNDS_DIR}/${fname}"
  echo "VLESS MLKEM URI:"
  echo "$uri"
}

# ---------------------------
# reset：仅删除 mlkem_* 入站文件
# ---------------------------
reset_only(){
  ensure_dirs
  sudo rm -f "${INBOUNDS_DIR}/${PROTOCOL}_"*.json 2>/dev/null || true
  echo "已删除所有 ${PROTOCOL}_*.json（仅本协议）。"
}

case "${1:-}" in
  reset) reset_only ;;
  *) add_node_interactive ;;
esac