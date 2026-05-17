#!/bin/bash
set -o pipefail

CONF_DIR="/etc/xray/conf.d"
XRAY_BIN="/etc/xray/bin/xray"
BASE_JSON="$CONF_DIR/02-base.json"
WARP_JSON="$CONF_DIR/03-outbound-warp.json"
WARP_TAG="warp"
TMP_TEST_LOG="/tmp/proxym-easy-warp-check.log"
WGCF_BIN="/usr/local/bin/wgcf"
WGCF_DIR="/etc/xray/warp"
WGCF_PROFILE="$WGCF_DIR/wgcf-profile.conf"
WGCF_ACCOUNT="$WGCF_DIR/wgcf-account.toml"

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
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v openssl >/dev/null 2>&1; then
        missing="$missing openssl"
    fi
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
    [[ -f "$file" ]] || return 0
    local backup="$file.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$file" "$backup"
    cleanup_backups "$file" "$backup"
}

cleanup_backups() {
    local file="$1"
    local keep="$2"
    local old
    for old in "$file".bak.*; do
        [[ -f "$old" ]] || continue
        [[ -n "$keep" && "$old" == "$keep" ]] && continue
        rm -f "$old"
    done
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


get_arch() {
    case $(uname -m) in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64|armv8*) echo "arm64" ;;
        armv7*|armv7l) echo "armv7" ;;
        armv6*|armv6l) echo "armv6" ;;
        armv5*|armv5l) echo "armv5" ;;
        i386|i686) echo "386" ;;
        *) _red "wgcf 暂不支持当前架构: $(uname -m)"; return 1 ;;
    esac
}

install_wgcf() {
    if [[ -x "$WGCF_BIN" ]]; then
        return 0
    fi
    ensure_deps || return 1
    local arch version api_url url tmpdir checksum expected actual
    arch=$(get_arch) || return 1
    api_url="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
    _yellow "正在获取 wgcf 最新版本..."
    version=$(curl -fsSL "$api_url" | jq -r '.tag_name') || return 1
    [[ -n "$version" && "$version" != "null" ]] || { _red "获取 wgcf 版本失败"; return 1; }
    url="https://github.com/ViRb3/wgcf/releases/download/${version}/wgcf_${version#v}_linux_${arch}"
    tmpdir=$(mktemp -d)
    _yellow "下载 wgcf: $url"
    curl -fL --retry 3 -o "$tmpdir/wgcf" "$url" || { rm -rf "$tmpdir"; _red "wgcf 下载失败"; return 1; }
    curl -fsSL -o "$tmpdir/checksums.txt" "https://github.com/ViRb3/wgcf/releases/download/${version}/checksums.txt" || { rm -rf "$tmpdir"; _red "wgcf 校验文件下载失败"; return 1; }
    checksum="wgcf_${version#v}_linux_${arch}"
    expected=$(awk -v f="$checksum" '$0 ~ f {print $1; exit}' "$tmpdir/checksums.txt")
    if [[ -n "$expected" ]]; then
        if command -v sha256sum >/dev/null 2>&1; then
            actual=$(sha256sum "$tmpdir/wgcf" | awk '{print $1}')
        else
            actual=$(openssl dgst -sha256 "$tmpdir/wgcf" | awk '{print $NF}')
        fi
        [[ "$expected" == "$actual" ]] || { rm -rf "$tmpdir"; _red "wgcf SHA256 校验失败"; return 1; }
    else
        _yellow "未在 checksums.txt 找到匹配项，跳过 SHA256 校验"
    fi
    install -m 0755 "$tmpdir/wgcf" "$WGCF_BIN" || { rm -rf "$tmpdir"; _red "安装 wgcf 失败"; return 1; }
    rm -rf "$tmpdir"
    _green "wgcf 安装完成: $WGCF_BIN"
}

auto_generate_warp_profile() {
    install_wgcf || return 1
    mkdir -p "$WGCF_DIR"
    chmod 700 "$WGCF_DIR"
    local oldpwd
    oldpwd=$(pwd)
    cd "$WGCF_DIR" || return 1

    if [[ ! -f "$WGCF_ACCOUNT" ]]; then
        _yellow "正在注册 Cloudflare WARP 账户..."
        yes | "$WGCF_BIN" register || { cd "$oldpwd"; _red "wgcf register 失败"; return 1; }
    else
        _yellow "检测到已有 WARP 账户，复用: $WGCF_ACCOUNT"
    fi

    _yellow "正在生成 WireGuard Profile..."
    "$WGCF_BIN" generate || { cd "$oldpwd"; _red "wgcf generate 失败"; return 1; }
    cd "$oldpwd" || return 1
    [[ -f "$WGCF_PROFILE" ]] || { _red "未生成 $WGCF_PROFILE"; return 1; }
}

parse_wgcf_profile_json() {
    local profile="$1"
    awk '
      BEGIN { section="" }
      /^\[Interface\]/ { section="interface"; next }
      /^\[Peer\]/ { section="peer"; next }
      /^[[:space:]]*PrivateKey[[:space:]]*=/ && section=="interface" { sub(/^[^=]*=[[:space:]]*/, ""); private=$0; next }
      /^[[:space:]]*Address[[:space:]]*=/ && section=="interface" { sub(/^[^=]*=[[:space:]]*/, ""); addr[++n]=$0; next }
      /^[[:space:]]*PublicKey[[:space:]]*=/ && section=="peer" { sub(/^[^=]*=[[:space:]]*/, ""); public=$0; next }
      /^[[:space:]]*Endpoint[[:space:]]*=/ && section=="peer" { sub(/^[^=]*=[[:space:]]*/, ""); endpoint=$0; next }
      END {
        printf "{\"private\":\"%s\",\"public\":\"%s\",\"endpoint\":\"%s\",\"addresses\":[", private, public, endpoint;
        for (i=1; i<=n; i++) { gsub(/\"/, "\\\"", addr[i]); printf "%s\"%s\"", (i>1 ? "," : ""), addr[i]; }
        print "]}"
      }
    ' "$profile"
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
    _cyan "添加 WARP 出站（自动生成 Cloudflare WARP WireGuard 配置）"
    echo "说明：本功能会使用 wgcf 自动注册/生成 WARP 配置并写入 Xray wireguard 出站。"
    echo "默认不会改路由；添加完成后可按提示选择是否让中国大陆流量走 WARP。"
    echo

    auto_generate_warp_profile || return 1

    local info secret_key public_key endpoint address_json reserved_json
    info=$(parse_wgcf_profile_json "$WGCF_PROFILE") || return 1
    secret_key=$(echo "$info" | jq -r '.private')
    public_key=$(echo "$info" | jq -r '.public')
    endpoint=$(normalize_endpoint "$(echo "$info" | jq -r '.endpoint')")
    address_json=$(echo "$info" | jq -c '.addresses')
    reserved_json='[0,0,0]'

    [[ -z "$secret_key" || "$secret_key" == "null" ]] && { _red "解析 PrivateKey 失败"; return 1; }
    [[ -z "$public_key" || "$public_key" == "null" ]] && { _red "解析 Peer PublicKey 失败"; return 1; }
    if [[ $(echo "$address_json" | jq 'length') -eq 0 ]]; then
        _red "解析 WARP address 失败"
        return 1
    fi

    backup_file "$WARP_JSON"
    write_warp_outbound "$secret_key" "$address_json" "$public_key" "$endpoint" "$reserved_json"

    if validate_xray_config; then
        _green "WARP 出站已添加: $WARP_JSON"
        _green "WARP 账户与 Profile 保存在: $WGCF_DIR"
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
