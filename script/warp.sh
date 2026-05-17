#!/bin/bash
set -o pipefail

CONF_DIR="/etc/xray/conf.d"
XRAY_BIN="/etc/xray/bin/xray"
BASE_JSON="$CONF_DIR/02-base.json"
WARP_JSON="$CONF_DIR/03-outbound-warp.json"
WARP_TAG="warp"
TMP_TEST_LOG="/tmp/proxym-easy-warp-check.log"

red='\e[31m'; yellow='\e[33m'; green='\e[92m'; cyan='\e[96m'; none='\e[0m'
_red() { echo -e "${red}$*${none}"; }
_yellow() { echo -e "${yellow}$*${none}"; }
_green() { echo -e "${green}$*${none}"; }
_cyan() { echo -e "${cyan}$*${none}"; }

check_root() { [[ $EUID != 0 ]] && { _red "请使用 root 用户执行"; exit 1; }; }

ensure_deps() {
    local missing=""
    for c in jq curl; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [[ -n "$missing" ]]; then
        local mgr
        mgr=$(type -P apt-get || type -P yum)
        [[ -z "$mgr" ]] && { _red "缺少依赖:$missing，请先手动安装"; return 1; }
        _yellow "安装依赖:$missing"
        $mgr update -y >/dev/null 2>&1 || true
        $mgr install -y $missing >/dev/null 2>&1 || { _red "依赖安装失败"; return 1; }
    fi
}

check_xray() {
    [[ -x "$XRAY_BIN" ]] || { _red "未找到 Xray: $XRAY_BIN"; return 1; }
    mkdir -p "$CONF_DIR"
}

backup_file() {
    local file="$1"
    [[ -f "$file" ]] && cp -a "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
}

validate_xray_config() {
    if "$XRAY_BIN" run -test -confdir "$CONF_DIR" >"$TMP_TEST_LOG" 2>&1; then
        return 0
    fi
    _red "Xray 配置验证失败:"
    cat "$TMP_TEST_LOG"
    return 1
}

reload_xray_if_running() {
    if systemctl is-active --quiet xray 2>/dev/null; then
        systemctl restart xray
        _green "Xray 已重启"
    fi
}

normalize_endpoint() {
    local endpoint="$1"
    endpoint=${endpoint#"\""}; endpoint=${endpoint%"\""}
    if [[ "$endpoint" =~ ^\[[^]]+\]:[0-9]+$ || "$endpoint" =~ ^[^:]+:[0-9]+$ ]]; then
        echo "$endpoint"
    elif [[ "$endpoint" =~ ^\[[^]]+\]$ ]]; then
        echo "${endpoint}:2408"
    elif [[ "$endpoint" =~ : ]]; then
        echo "[$endpoint]:2408"
    else
        echo "${endpoint}:2408"
    fi
}

parse_reserved_json() {
    local raw="$1"
    raw=${raw// /}
    [[ -z "$raw" ]] && { echo '[0,0,0]'; return; }
    if [[ "$raw" =~ ^\[[0-9]+,[0-9]+,[0-9]+\]$ ]]; then
        echo "$raw"
    elif [[ "$raw" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]]; then
        echo "[$raw]"
    else
        _red "reserved 格式无效，应为 0,0,0 或 [0,0,0]"
        return 1
    fi
}

write_warp_outbound() {
    local secret_key="$1"
    local address_json="$2"
    local public_key="$3"
    local endpoint="$4"
    local reserved_json="$5"

    jq -n \
      --arg tag "$WARP_TAG" \
      --arg secretKey "$secret_key" \
      --argjson address "$address_json" \
      --arg publicKey "$public_key" \
      --arg endpoint "$endpoint" \
      --argjson reserved "$reserved_json" \
      '{outbounds:[{tag:$tag,protocol:"wireguard",settings:{secretKey:$secretKey,address:$address,peers:[{publicKey:$publicKey,allowedIPs:["0.0.0.0/0","::/0"],endpoint:$endpoint}],reserved:$reserved,mtu:1280}}]}' > "$WARP_JSON"
}

add_warp_outbound() {
    check_xray || return 1
    ensure_deps || return 1

    echo
    _cyan "添加 WARP 出站（参考 Xray 官方 WARP 文档）"
    echo "说明：本功能只添加 wireguard 出站，不会默认改路由；如需使用，请在菜单中单独配置路由。"
    echo "你需要先通过 wgcf / wgcf-cli / warp-reg 获取 WARP 账户参数。"
    echo
    read -r -p "PrivateKey / secretKey: " secret_key
    read -r -p "IPv4 地址（如 172.16.0.2/32，可留空）: " addr4
    read -r -p "IPv6 地址（如 2606:4700:110:.../128，可留空）: " addr6
    read -r -p "Peer PublicKey（默认 Cloudflare WARP 公钥）: " public_key
    read -r -p "Endpoint（默认 engage.cloudflareclient.com:2408）: " endpoint
    read -r -p "reserved（三个数字，默认 0,0,0；如 35,74,190）: " reserved_raw

    [[ -z "$secret_key" ]] && { _red "secretKey 不能为空"; return 1; }
    public_key=${public_key:-"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="}
    endpoint=$(normalize_endpoint "${endpoint:-engage.cloudflareclient.com:2408}")
    local reserved_json
    reserved_json=$(parse_reserved_json "${reserved_raw:-0,0,0}") || return 1

    local address_json
    address_json=$(jq -n --arg a4 "$addr4" --arg a6 "$addr6" '[ $a4, $a6 | select(length > 0) ]')
    if [[ $(echo "$address_json" | jq 'length') -eq 0 ]]; then
        _red "至少需要填写一个 WARP address"
        return 1
    fi

    backup_file "$WARP_JSON"
    write_warp_outbound "$secret_key" "$address_json" "$public_key" "$endpoint" "$reserved_json"

    if validate_xray_config; then
        _green "WARP 出站已添加: $WARP_JSON"
        reload_xray_if_running
        read -r -p "是否现在配置中国大陆流量通过 WARP 出站？[y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] && route_cn_to_warp
    else
        rm -f "$WARP_JSON"
        _red "已撤销 WARP 出站写入"
        return 1
    fi
}

ensure_base_json() {
    if [[ ! -f "$BASE_JSON" ]]; then
        cat > "$BASE_JSON" <<'EOF'
{
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4v6"}},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {"domainStrategy": "UseIPv4v6", "rules": []}
}
EOF
    fi
}

route_cn_to_warp() {
    check_xray || return 1
    ensure_deps || return 1
    [[ -f "$WARP_JSON" ]] || { _red "请先添加 WARP 出站"; return 1; }
    ensure_base_json
    backup_file "$BASE_JSON"

    local tmp
    tmp=$(mktemp)
    jq --arg tag "$WARP_TAG" '
      .routing = (.routing // {}) |
      .routing.domainStrategy = (.routing.domainStrategy // "IPIfNonMatch") |
      .routing.rules = ((.routing.rules // [])
        | map(select(.outboundTag != $tag or ((.domain // []) | index("geosite:cn") | not) and ((.ip // []) | index("geoip:cn") | not)))
      ) |
      .routing.rules = ([
        {"type":"field","domain":["geosite:cn"],"outboundTag":$tag},
        {"type":"field","ip":["geoip:cn"],"outboundTag":$tag}
      ] + .routing.rules)
    ' "$BASE_JSON" > "$tmp" && mv "$tmp" "$BASE_JSON"

    if validate_xray_config; then
        _green "已配置中国大陆流量（geosite:cn / geoip:cn）通过 WARP 出站"
        reload_xray_if_running
    else
        _red "路由配置失败，请检查备份: $BASE_JSON.bak.*"
        return 1
    fi
}

delete_cn_warp_route() {
    check_xray || return 1
    ensure_deps || return 1
    [[ -f "$BASE_JSON" ]] || { _yellow "未找到 $BASE_JSON"; return 0; }
    backup_file "$BASE_JSON"

    local tmp
    tmp=$(mktemp)
    jq --arg tag "$WARP_TAG" '
      if .routing and .routing.rules then
        .routing.rules |= map(select((.outboundTag == $tag and (((.domain // []) | index("geosite:cn")) or ((.ip // []) | index("geoip:cn")))) | not))
      else . end
    ' "$BASE_JSON" > "$tmp" && mv "$tmp" "$BASE_JSON"

    if validate_xray_config; then
        _green "已删除中国大陆流量通过 WARP 的路由规则"
        reload_xray_if_running
    else
        _red "删除路由后配置验证失败，请检查备份: $BASE_JSON.bak.*"
        return 1
    fi
}

delete_warp_outbound() {
    check_xray || return 1
    ensure_deps || return 1
    delete_cn_warp_route || return 1
    if [[ -f "$WARP_JSON" ]]; then
        backup_file "$WARP_JSON"
        rm -f "$WARP_JSON"
        _green "已删除 WARP 出站: $WARP_JSON"
    else
        _yellow "WARP 出站不存在"
    fi
    if validate_xray_config; then
        reload_xray_if_running
    else
        _red "删除 WARP 出站后配置验证失败，请检查其他配置"
        return 1
    fi
}

test_warp_outbound() {
    check_xray || return 1
    ensure_deps || return 1
    [[ -f "$WARP_JSON" ]] || { _red "请先添加 WARP 出站"; return 1; }
    validate_xray_config || return 1

    local tmpdir port pid ret body
    tmpdir=$(mktemp -d)
    port=$((RANDOM % 20000 + 20000))
    jq -s --argjson port "$port" '{inbounds:[{tag:"warp-test-in",listen:"127.0.0.1",port:$port,protocol:"socks",settings:{udp:true}}],outbounds:(.[0].outbounds),routing:{rules:[{type:"field",inboundTag:["warp-test-in"],outboundTag:"warp"}]}}' "$WARP_JSON" > "$tmpdir/config.json"

    "$XRAY_BIN" run -c "$tmpdir/config.json" >"$tmpdir/xray.log" 2>&1 &
    pid=$!
    sleep 2
    body=$(curl -sS --max-time 15 --socks5-hostname "127.0.0.1:$port" https://www.cloudflare.com/cdn-cgi/trace 2>"$tmpdir/curl.err")
    ret=$?
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true

    if [[ $ret -eq 0 && "$body" == *"warp="* ]]; then
        _green "WARP 出站连通性测试成功"
        echo "$body" | grep -E '^(ip|loc|colo|warp)=' || true
    else
        _red "WARP 出站连通性测试失败"
        echo "curl 错误:"
        cat "$tmpdir/curl.err"
        echo "Xray 日志:"
        cat "$tmpdir/xray.log"
    fi
    rm -rf "$tmpdir"
    return $ret
}

main_menu() {
    check_root
    while true; do
        clear
        echo "========== WARP 出站管理 =========="
        echo "[1] 添加 WARP 出站"
        echo "[2] 测试 WARP 出站连通性"
        echo "[3] 删除 WARP 出站（并自动删除 base.json 中 WARP 相关路由）"
        echo "[4] 配置中国大陆流量通过 WARP 出站"
        echo "[5] 删除中国大陆流量通过 WARP 出站"
        echo "[0] 退出"
        echo "==================================="
        echo
        read -r -p "请选择 [0-5]: " choice
        case "$choice" in
            1) add_warp_outbound; read -r -p "按回车键继续..." ;;
            2) test_warp_outbound; read -r -p "按回车键继续..." ;;
            3) delete_warp_outbound; read -r -p "按回车键继续..." ;;
            4) route_cn_to_warp; read -r -p "按回车键继续..." ;;
            5) delete_cn_warp_route; read -r -p "按回车键继续..." ;;
            0) exit 0 ;;
            *) _red "无效选择"; sleep 1 ;;
        esac
    done
}

main_menu "$@"
