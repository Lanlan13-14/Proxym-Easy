#!/usr/bin/env bash
# vless-manager.sh - Proxym-Easy 主控脚本（完整、已修正）
# 说明：运行需 sudo 权限。管理 Xray、子脚本、生成 main.json/dns.json、添加节点、reset、卸载等。
set -euo pipefail
export LC_ALL=C.UTF-8

# -----------------------
# 常量与路径
# -----------------------
LOCAL_SCRIPT_DIR="/usr/local/bin/proxym-scripts"
SCRIPTS_RAW_BASE="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/script"
REALITY_RAW="${SCRIPTS_RAW_BASE}/vless-reality.sh%0A"
X25519_RAW="${SCRIPTS_RAW_BASE}/vless-x25519.sh"
MLKEM_RAW="${SCRIPTS_RAW_BASE}/vless-mlkem.sh"

VLESS_JSON="/etc/proxym/vless.json"
XRAY_DIR="/etc/xray"
DNS_FILE="${XRAY_DIR}/dns.json"
MAIN_FILE="${XRAY_DIR}/main.json"
URIS_TOKENS="/etc/proxym/uris_tokens.json"
MIRROR_CONF="/etc/proxym/mirror.conf"
XRAY_SERVICE_NAME="xray"
LOG_FILE="/var/log/xray/access.log"
MAIN_SCRIPT_PATH="${LOCAL_SCRIPT_DIR}/vless-manager.sh"  # if installed here

# -----------------------
# 颜色与符号
# -----------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
CHECK="✔"
WARN="⚠"
ERR="✖"

log(){ printf "%b ℹ %s%b\n" "${GREEN}" "$*" "${NC}"; }
info(){ log "$*"; }
warn(){ printf "%b %s %s%b\n" "${YELLOW}" "${WARN}" "$*" "${NC}"; }
error(){ printf "%b %s %s%b\n" "${RED}" "${ERR}" "$*" "${NC}"; }

# -----------------------
# 基础目录/文件确保
# -----------------------
ensure_dirs(){
  sudo mkdir -p "$LOCAL_SCRIPT_DIR"
  sudo mkdir -p "$XRAY_DIR"
  sudo mkdir -p "$(dirname "$VLESS_JSON")"
  sudo mkdir -p "$(dirname "$URIS_TOKENS")"
  sudo mkdir -p "$(dirname "$MIRROR_CONF")"
  if [ ! -f "$VLESS_JSON" ]; then echo "[]" | sudo tee "$VLESS_JSON" >/dev/null; fi
  if [ ! -f "$URIS_TOKENS" ]; then echo "{}" | sudo tee "$URIS_TOKENS" >/dev/null; fi
  if [ ! -f "$MIRROR_CONF" ]; then echo "" | sudo tee "$MIRROR_CONF" >/dev/null; fi
}

# -----------------------
# 镜像前缀（可选）
# -----------------------
load_mirror(){
  ensure_dirs
  MIRROR_PREFIX=$(sudo sed -n '1p' "$MIRROR_CONF" 2>/dev/null || echo "")
  MIRROR_PREFIX=${MIRROR_PREFIX:-}
}
get_raw_url(){
  local name="$1"
  local raw="${SCRIPTS_RAW_BASE}/${name}"
  load_mirror
  if [ -n "$MIRROR_PREFIX" ]; then
    echo "${MIRROR_PREFIX}/${raw}"
  else
    echo "$raw"
  fi
}

# -----------------------
# 包管理器检测与依赖安装
# -----------------------
detect_package_manager(){
  if command -v apt >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  else echo "unknown"; fi
}

install_dependencies() {
    local force_update=${1:-false}
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    local deps=("curl" "unzip" "ca-certificates" "wget" "gnupg" "python3" "jq")
    local cron_pkg="cron"
    if [ "$pkg_manager" = "apk" ]; then cron_pkg="dcron"; fi
    if [ "$pkg_manager" = "pacman" ] || [ "$pkg_manager" = "yum" ] || [ "$pkg_manager" = "dnf" ]; then cron_pkg="cronie"; fi
    deps+=("$cron_pkg")

    if [ "$force_update" = true ]; then
        log "安装 Xray 依赖..."
        case "$pkg_manager" in
            apt) sudo apt update; sudo apt install -y "${deps[@]}"; log "Debian/Ubuntu 依赖安装完成。" ;;
            yum) sudo yum update -y; sudo yum install -y "${deps[@]}"; log "CentOS/RHEL 依赖安装完成。" ;;
            dnf) sudo dnf update -y; sudo dnf install -y "${deps[@]}"; log "Fedora 依赖安装完成。" ;;
            apk) sudo apk update; sudo apk add --no-cache "${deps[@]}"; log "Alpine 依赖安装完成。" ;;
            pacman) sudo pacman -Syu --noconfirm "${deps[@]}"; log "Arch 依赖安装完成。" ;;
            *) warn "未检测到包管理器，请手动安装 curl unzip ca-certificates python3 cron jq。" ;;
        esac
    else
        local missing_deps=()
        for dep in "${deps[@]}"; do
            cmd="${dep%% *}"
            if ! command -v "$cmd" &> /dev/null; then missing_deps+=("$dep"); fi
        done
        if [ ${#missing_deps[@]} -gt 0 ]; then
            log "检测到缺少依赖: ${missing_deps[*]}，正在安装..."
            case "$pkg_manager" in
                apt) sudo apt update; sudo apt install -y "${missing_deps[@]}"; log "Debian/Ubuntu 依赖安装完成。" ;;
                yum) sudo yum install -y "${missing_deps[@]}"; log "CentOS/RHEL 依赖安装完成。" ;;
                dnf) sudo dnf install -y "${missing_deps[@]}"; log "Fedora 依赖安装完成。" ;;
                apk) sudo apk update; sudo apk add --no-cache "${missing_deps[@]}"; log "Alpine 依赖安装完成。" ;;
                pacman) sudo pacman -S --noconfirm "${missing_deps[@]}"; log "Arch 依赖安装完成。" ;;
                *) warn "未检测到包管理器，请手动安装缺少的依赖: ${missing_deps[*]}。" ;;
            esac
        else
            log "依赖已满足。"
        fi
    fi
}

# -----------------------
# init 系统检测
# -----------------------
detect_init_system() {
    if command -v systemctl &> /dev/null; then echo "systemd"
    elif command -v rc-service &> /dev/null; then echo "openrc"
    else echo "none"; fi
}

# -----------------------
# Xray 安装/更新/管理
# -----------------------
install_xray() {
    local pause=${1:-1}
    local force_deps=${2:-false}
    local is_update=${3:-false}
    local init_system
    init_system=$(detect_init_system)

    if command -v xray &> /dev/null && [ "$is_update" = false ]; then
        log "Xray 已安装。"
        if [ "$pause" -eq 1 ] && [ "${NON_INTERACTIVE:-}" != "true" ]; then
            read -p "按 Enter 返回菜单..."
        fi
        return 0
    else
        install_dependencies "$force_deps"
        log "安装/更新 Xray..."
        if [ "$init_system" = "openrc" ]; then
            curl -L https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh -o /tmp/install-release.sh
            ash /tmp/install-release.sh
            rm -f /tmp/install-release.sh
            if [ "$is_update" = false ] && [ "${NON_INTERACTIVE:-}" != "true" ]; then
                read -p "是否为 Xray 节点降低网络特权（仅保留 cap_net_bind_service）？(y/N): " reduce_priv
                if [[ "$reduce_priv" =~ ^[Yy] ]]; then
                    if [ -f /etc/init.d/xray ]; then
                      sudo sed -i 's/^capabilities=".*"$/capabilities="^cap_net_bind_service"/g' /etc/init.d/xray || true
                      log "已尝试调整 Xray 网络特权，仅保留 cap_net_bind_service。"
                    fi
                fi
            fi
        else
            bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
        fi

        if [ $? -eq 0 ]; then log "Xray 安装/更新成功。"; else error "Xray 安装/更新失败。"; fi

        if command -v xray &> /dev/null; then restart_xray 0 || true; fi

        if [ "$pause" -eq 1 ] && [ "${NON_INTERACTIVE:-}" != "true" ]; then
            read -p "按 Enter 返回菜单..."
        fi
    fi
}

# -----------------------
# update_xray_core（整合）
# -----------------------
update_xray_core() {
    log "检查 Xray Core 更新..."

    if ! command -v xray &> /dev/null; then
        log "Xray 尚未安装，将转到安装程序。"
        install_xray 1 true
        return
    fi

    # 1. 获取当前版本
    local current_version
    current_version=$(xray -version 2>/dev/null | awk '/Xray/ {print $2; exit}' || true)

    # 2. 获取最新版本
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -E '"tag_name"' | head -n1 | cut -d '"' -f4 | sed 's/^v//' || true)

    if [ -z "$current_version" ]; then
        echo -e "${YELLOW} 无法获取当前 Xray 版本。 ${NC}"
        current_version="未知"
    fi

    if [ -z "$latest_version" ]; then
        error "无法获取 Xray 最新版本，请检查网络连接。"
        return
    fi

    log "当前 Xray 版本: ${YELLOW}${current_version}${NC}"
    log "最新 Xray 版本: ${GREEN}${latest_version}${NC}"

    # 3. 版本对比 (简单字符串比较)
    if [ "$current_version" = "$latest_version" ]; then
        log "您的 Xray 版本已是最新，无需更新。 ${CHECK}"
    else
        echo -e "${YELLOW}检测到新版本。是否立即更新 Xray Core？ (y/N): ${NC}"
        if [ "${NON_INTERACTIVE:-}" != "true" ]; then
            read -p "请输入选项 (y/N, 默认 N): " update_choice
        else
            update_choice="n"
        fi

        if [[ "$update_choice" =~ ^[Yy] ]]; then
            install_xray 1 true true
            return
        else
            log "取消更新，返回主菜单。"
        fi
    fi

    if [ "${NON_INTERACTIVE:-}" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}

# -----------------------
# Xray systemd 管理（强制 systemd）
# -----------------------
start_xray(){
  if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl start "${XRAY_SERVICE_NAME}" && log "Xray 已通过 systemd 启动" || warn "通过 systemd 启动 Xray 失败"
  else
    error "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}。请安装 Xray 的 systemd 服务或创建 unit。"
    return 1
  fi
}
stop_xray(){
  if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl stop "${XRAY_SERVICE_NAME}" && log "Xray 已通过 systemd 停止" || warn "通过 systemd 停止 Xray 失败"
  else
    error "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}。无法停止。"
    return 1
  fi
}
restart_xray(){
  if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl restart "${XRAY_SERVICE_NAME}" && log "Xray 已通过 systemd 重启" || warn "通过 systemd 重启 Xray 失败"
  else
    error "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}。无法重启。"
    return 1
  fi
}
status_xray(){
  if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl status "${XRAY_SERVICE_NAME}" --no-pager
  else
    error "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}。无法显示状态。"
    return 1
  fi
}
logs_xray(){
  if [ -f "$LOG_FILE" ]; then
    sudo tail -n 200 "$LOG_FILE"
  else
    if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then
      sudo journalctl -u "${XRAY_SERVICE_NAME}" -n 200 --no-pager
    else
      warn "未找到日志文件 ${LOG_FILE}，也未检测到 systemd 服务"
    fi
  fi
}

# -----------------------
# 子脚本安装/更新/删除（使用镜像前缀）
# -----------------------
install_children(){
  ensure_dirs
  log "安装/更新子脚本到 ${LOCAL_SCRIPT_DIR}"
  mkdir -p /tmp/proxym-scripts-download
  for raw in "$REALITY_RAW" "$X25519_RAW" "$MLKEM_RAW"; do
    name=$(basename "$raw")
    url=$(get_raw_url "$name")
    tmp="/tmp/proxym-scripts-download/${name}.new"
    log "下载 ${name} <- ${url}"
    if curl -fsSL "$url" -o "$tmp"; then
      sudo mv "$tmp" "${LOCAL_SCRIPT_DIR}/${name}"
      sudo chmod +x "${LOCAL_SCRIPT_DIR}/${name}"
      log "已安装/更新 ${name}"
    else
      warn "下载失败: $url"
      [ -f "$tmp" ] && rm -f "$tmp"
    fi
  done
  rm -rf /tmp/proxym-scripts-download
  log "子脚本安装/更新完成。"
}
remove_children(){ ensure_dirs; sudo rm -rf "$LOCAL_SCRIPT_DIR"; log "已删除子脚本目录 ${LOCAL_SCRIPT_DIR}"; }

# -----------------------
# 写入 main.json 与 dns.json（主配置与 DNS）
# -----------------------
write_main_config(){
  if [ -f "$MAIN_FILE" ]; then
    read -p "${MAIN_FILE} 已存在，是否覆盖? (y/N): " overwrite
    if ! [[ "$overwrite" =~ ^[Yy] ]]; then
      log "取消写入 ${MAIN_FILE}"
      return
    fi
  fi
  sudo mkdir -p "$XRAY_DIR"
  sudo tee "$MAIN_FILE" >/dev/null <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4v6"
      },
      "tag": "direct"
    }
  ]
}
EOF
  log "已写入 ${MAIN_FILE}"
}

write_dns_config(){
  if [ -f "$DNS_FILE" ]; then
    read -p "${DNS_FILE} 已存在，是否覆盖? (y/N): " overwrite
    if ! [[ "$overwrite" =~ ^[Yy] ]]; then
      log "取消写入 ${DNS_FILE}"
      return
    fi
  fi
  read -p "主 DNS（默认 1.1.1.1）: " dns1
  dns1=${dns1:-1.1.1.1}
  read -p "备 DNS（默认 8.8.8.8）: " dns2
  dns2=${dns2:-8.8.8.8}
  sudo mkdir -p "$XRAY_DIR"
  sudo tee "$DNS_FILE" >/dev/null <<EOF
{
  "dns": {
    "servers": [
      { "address": "${dns1}" },
      { "address": "${dns2}" }
    ],
    "queryStrategy": "UseIPv4"
  }
}
EOF
  log "已写入 ${DNS_FILE}"
}

# -----------------------
# inbounds 列表与删除（管理 /etc/xray 下入站文件）
# -----------------------
list_inbounds(){
  ensure_dirs
  echo "inbounds 文件 (${XRAY_DIR}):"
  # 列出包含 inbounds 的文件或以 inbound/ vless- 前缀命名的文件
  for f in "${XRAY_DIR}"/*.json; do
    [ -e "$f" ] || continue
    if grep -q '"inbounds"' "$f" 2>/dev/null || echo "$f" | grep -q -E 'inbound|vless'; then
      echo " - $(basename "$f")"
    fi
  done
}

delete_inbound_file(){
  ensure_dirs
  read -p "输入要删除的入站文件名（例如 01-inbound-tcp.json）: " fname
  if [ -z "$fname" ]; then warn "未输入文件名"; return; fi
  if [ -f "${XRAY_DIR}/${fname}" ]; then
    sudo rm -f "${XRAY_DIR}/${fname}"
    log "已删除 ${XRAY_DIR}/${fname}"
  else
    warn "文件不存在: ${XRAY_DIR}/${fname}"
  fi
}

# -----------------------
# 添加节点菜单（调用子脚本交互式添加）
# -----------------------
add_node_menu(){
  ensure_dirs
  while true; do
    cat <<'ADDMENU'

[1] 添加 VLESS Reality 节点
[2] 添加 VLESS x25519 节点
[3] 添加 VLESS MLKEM 节点
[4] 返回
ADDMENU
    read -p "选择 [1-4]: " a
    case "$a" in
      1)
        if [ -x "${LOCAL_SCRIPT_DIR}/vless-reality.sh" ]; then
          sudo "${LOCAL_SCRIPT_DIR}/vless-reality.sh"
        else
          warn "未安装子脚本: ${LOCAL_SCRIPT_DIR}/vless-reality.sh，请先安装子脚本（菜单: 子脚本安装/更新/删除）"
        fi
        ;;
      2)
        if [ -x "${LOCAL_SCRIPT_DIR}/vless-x25519.sh" ]; then
          sudo "${LOCAL_SCRIPT_DIR}/vless-x25519.sh"
        else
          warn "未安装子脚本: ${LOCAL_SCRIPT_DIR}/vless-x25519.sh，请先安装子脚本"
        fi
        ;;
      3)
        if [ -x "${LOCAL_SCRIPT_DIR}/vless-mlkem.sh" ]; then
          sudo "${LOCAL_SCRIPT_DIR}/vless-mlkem.sh"
        else
          warn "未安装子脚本: ${LOCAL_SCRIPT_DIR}/vless-mlkem.sh，请先安装子脚本"
        fi
        ;;
      4) return ;;
      *) warn "无效选项" ;;
    esac
    echo
    read -p "按 Enter 返回 添加节点 菜单..." _ || true
  done
}

# -----------------------
# proxym-easy reset（重置所有）
# -----------------------
proxym_easy_reset_all(){
  ensure_dirs
  log "开始 proxym-easy reset：依次调用已安装的子脚本 reset（仅本协议文件）"
  local any=false
  for s in "${LOCAL_SCRIPT_DIR}/vless-reality.sh" "${LOCAL_SCRIPT_DIR}/vless-x25519.sh" "${LOCAL_SCRIPT_DIR}/vless-mlkem.sh"; do
    if [ -x "$s" ]; then
      log "调用 $(basename "$s") reset"
      sudo "$s" reset || warn "调用 $(basename "$s") reset 失败"
      any=true
    else
      log "未安装 $(basename "$s")，跳过"
    fi
  done
  if [ "$any" = true ]; then
    read -p "是否重启 Xray 以应用变更? (y/N): " rr
    if [[ "$rr" =~ ^[Yy] ]]; then restart_xray; fi
    log "proxym-easy reset 完成。"
  else
    warn "未检测到任何子脚本，未执行 reset。"
  fi
}

# -----------------------
# URIs 与 上传管理（简化）
# -----------------------
list_uris_tokens(){
  ensure_dirs
  if [ -f "$URIS_TOKENS" ]; then
    jq -r 'to_entries[] | "[\(.key)] uri: \(.value.uri) endpoint: \(.value.upload_endpoint // "") token: \(.value.upload_token // "")"' "$URIS_TOKENS" 2>/dev/null || echo "{}"
  else
    echo "{}"
  fi
}
set_uri_token(){
  ensure_dirs
  read -p "输入协议_端口 (例如 reality_443): " key
  read -p "输入对应 URI: " uri
  read -p "输入 upload endpoint (例如 https://worker.example/upload): " ep
  read -p "输入 upload token (留空无 token): " tok
  tmp=$(mktemp)
  jq --arg k "$key" --arg uri "$uri" --arg ep "$ep" --arg tok "$tok" '. + {($k): {uri:$uri, upload_endpoint:$ep, upload_token:$tok}}' "$URIS_TOKENS" > "$tmp" && sudo mv "$tmp" "$URIS_TOKENS"
  log "已保存映射 [$key]"
}
delete_uri_token(){
  ensure_dirs
  read -p "输入要删除的协议_端口: " key
  tmp=$(mktemp)
  jq "del(.\"$key\")" "$URIS_TOKENS" > "$tmp" && sudo mv "$tmp" "$URIS_TOKENS"
  log "已删除映射 [$key]"
}
upload_single_impl(){
  ensure_dirs
  read -p "输入要上传的协议_端口: " key
  uri=$(jq -r --arg k "$key" '.[$k].uri // empty' "$URIS_TOKENS")
  endpoint=$(jq -r --arg k "$key" '.[$k].upload_endpoint // empty' "$URIS_TOKENS")
  token=$(jq -r --arg k "$key" '.[$k].upload_token // empty' "$URIS_TOKENS")
  if [ -z "$uri" ] || [ -z "$endpoint" ]; then error "[$key] 未配置 uri 或 endpoint"; return 1; fi
  log "上传 [$key] -> $endpoint"
  if [ -n "$token" ]; then
    curl -s -X POST "$endpoint" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "{\"uri\":\"$uri\"}" | sed -n '1,200p'
  else
    curl -s -X POST "$endpoint" -H "Content-Type: application/json" -d "{\"uri\":\"$uri\"}" | sed -n '1,200p'
  fi
}
upload_all_impl(){
  ensure_dirs
  if [ ! -f "$URIS_TOKENS" ]; then warn "未找到 $URIS_TOKENS"; return; fi
  keys=$(jq -r 'keys[]' "$URIS_TOKENS")
  for k in $keys; do
    echo "---- [${k}] ----"
    uri=$(jq -r --arg k "$k" '.[$k].uri' "$URIS_TOKENS")
    endpoint=$(jq -r --arg k "$k" '.[$k].upload_endpoint // empty' "$URIS_TOKENS")
    token=$(jq -r --arg k "$k" '.[$k].upload_token // empty' "$URIS_TOKENS")
    if [ -z "$endpoint" ]; then warn "[$k] 未配置 endpoint"; continue; fi
    if [ -n "$token" ]; then
      curl -s -X POST "$endpoint" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "{\"uri\":\"$uri\"}" >/dev/null || warn "上传失败 [$k]"
    else
      curl -s -X POST "$endpoint" -H "Content-Type: application/json" -d "{\"uri\":\"$uri\"}" >/dev/null || warn "上传失败 [$k]"
    fi
  done
  log "批量上传完成"
}
delete_uploaded_single_impl(){
  ensure_dirs
  read -p "输入要删除已上传的协议_端口: " key
  uri=$(jq -r --arg k "$key" '.[$k].uri // empty' "$URIS_TOKENS")
  endpoint=$(jq -r --arg k "$key" '.[$k].upload_endpoint // empty' "$URIS_TOKENS")
  token=$(jq -r --arg k "$key" '.[$k].upload_token // empty' "$URIS_TOKENS")
  if [ -z "$uri" ] || [ -z "$endpoint" ]; then error "[$key] 未配置 uri 或 endpoint"; return 1; fi
  enc_uri=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$uri" 2>/dev/null || printf '%s' "$uri")
  log "删除已上传 [$key] -> ${endpoint}?uri=${enc_uri}"
  if [ -n "$token" ]; then
    curl -s -X DELETE "${endpoint}?uri=${enc_uri}" -H "Authorization: Bearer ${token}" | sed -n '1,200p'
  else
    curl -s -X DELETE "${endpoint}?uri=${enc_uri}" | sed -n '1,200p'
  fi
}
delete_all_uploaded_impl(){
  ensure_dirs
  if [ ! -f "$URIS_TOKENS" ]; then warn "未找到 $URIS_TOKENS"; return; fi
  keys=$(jq -r 'keys[]' "$URIS_TOKENS")
  for k in $keys; do
    echo "---- [${k}] ----"
    uri=$(jq -r --arg k "$k" '.[$k].uri' "$URIS_TOKENS")
    endpoint=$(jq -r --arg k "$k" '.[$k].upload_endpoint // empty' "$URIS_TOKENS")
    token=$(jq -r --arg k "$k" '.[$k].upload_token // empty' "$URIS_TOKENS")
    if [ -z "$endpoint" ]; then warn "[$k] 未配置 endpoint"; continue; fi
    enc_uri=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$uri" 2>/dev/null || printf '%s' "$uri")
    if [ -n "$token" ]; then
      curl -s -X DELETE "${endpoint}?uri=${enc_uri}" -H "Authorization: Bearer ${token}" >/dev/null || warn "删除失败 [$k]"
    else
      curl -s -X DELETE "${endpoint}?uri=${enc_uri}" >/dev/null || warn "删除失败 [$k]"
    fi
  done
  log "批量删除已上传完成"
}

# -----------------------
# Cron 管理（重启/重置）
# -----------------------
set_cron_restart(){
  read -p "输入 cron 表达式（例如 0 4 * * * 表示每天 04:00）: " expr
  (crontab -l 2>/dev/null | grep -v '#vless-manager-restart' ; echo "${expr} systemctl restart ${XRAY_SERVICE_NAME} #vless-manager-restart") | crontab -
  log "已设置 Cron 重启"
}
list_cron_restart(){ crontab -l 2>/dev/null | nl -ba | sed -n '/vless-manager-restart/,$p' || echo "(无重启 Cron)"; }
delete_cron_restart(){ (crontab -l 2>/dev/null | grep -v '#vless-manager-restart') | crontab -; log "已删除重启相关 Cron 条目"; }

set_cron_reset(){
  read -p "输入 cron 表达式（例如 0 3 * * 0 表示每周日 03:00）: " expr
  (crontab -l 2>/dev/null | grep -v '#vless-manager-reset' ; echo "${expr} ${LOCAL_SCRIPT_DIR}/vless-manager.sh proxym-easy reset #vless-manager-reset") | crontab -
  log "已设置 Cron 重置"
}
list_cron_reset(){ crontab -l 2>/dev/null | nl -ba | sed -n '/vless-manager-reset/,$p' || echo "(无重置 Cron)"; }
delete_cron_reset(){ (crontab -l 2>/dev/null | grep -v '#vless-manager-reset') | crontab -; log "已删除重置相关 Cron 条目"; }

# -----------------------
# 编辑/测试 配置
# -----------------------
edit_config(){
  ensure_dirs
  editor="${EDITOR:-vi}"
  sudo $editor "$MAIN_FILE"
}
test_config(){
  ensure_dirs
  if command -v xray >/dev/null 2>&1; then
    log "使用 xray 测试 confdir ${XRAY_DIR}"
    sudo xray test -confdir "$XRAY_DIR" || warn "配置测试失败"
  else
    warn "未安装 xray，无法测试"
  fi
}

# -----------------------
# 打印 VLESS URIs（从 /etc/proxym/vless.json）
# -----------------------
print_vless_uris(){
  ensure_dirs
  if [ ! -f "$VLESS_JSON" ]; then
    echo "无 vless.json 文件。"
    return
  fi
  jq -r '.[] | "Name: \(.tag // \"-\")\nURI: \(.uri // \"-\")\n---"' "$VLESS_JSON" 2>/dev/null || echo "(无节点或格式不正确)"
}

# -----------------------
# 卸载模块（两种模式）
# -----------------------
uninstall_all_scripts_only(){
  ensure_dirs
  echo "即将卸载：主脚本、子脚本、/etc/proxym 数据（但保留 Xray 与 /etc/xray 配置）"
  read -p "确认卸载全部脚本与 proxym 数据？(y/N): " yn
  yn=${yn:-N}
  if [[ "$yn" =~ ^[Yy] ]]; then
    sudo rm -rf "$LOCAL_SCRIPT_DIR"
    sudo rm -f "$MAIN_SCRIPT_PATH"
    sudo rm -rf /etc/proxym
    log "已删除子脚本、主脚本（若位于 ${MAIN_SCRIPT_PATH}）与 /etc/proxym 数据。"
  else
    log "已取消。"
  fi
}

uninstall_everything_including_xray(){
  ensure_dirs
  echo "彻底卸载：Xray、主脚本、子脚本、/etc/xray、/etc/proxym 等全部数据"
  read -p "确认彻底卸载并删除 Xray 与所有配置？(y/N): " yn
  yn=${yn:-N}
  if [[ "$yn" =~ ^[Yy] ]]; then
    # 停止并禁用服务（如果存在）
    if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then
      sudo systemctl stop "${XRAY_SERVICE_NAME}" || true
      sudo systemctl disable "${XRAY_SERVICE_NAME}" || true
      sudo rm -f "/etc/systemd/system/${XRAY_SERVICE_NAME}.service" || true
      sudo systemctl daemon-reload || true
    fi
    # 使用官方脚本卸载 Xray
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove || warn "Xray 官方卸载脚本执行失败，请手动检查。"
    # 删除文件与目录
    sudo rm -rf "$LOCAL_SCRIPT_DIR"
    sudo rm -f "$MAIN_SCRIPT_PATH"
    sudo rm -rf /etc/proxym
    sudo rm -rf /etc/xray
    sudo rm -rf /var/log/xray
    sudo rm -rf /usr/bin/xray || true
    sudo rm -rf /usr/local/bin/xray || true
    log "已尝试卸载 Xray 并删除所有相关文件与配置。请手动检查残留服务或文件。"
  else
    log "已取消。"
  fi
}

# -----------------------
# 子脚本安装/更新/删除（菜单入口）
# -----------------------
manage_children_menu(){
  ensure_dirs
  echo "[1] 安装/更新 子脚本"
  echo "[2] 删除 子脚本"
  read -p "选择 [1-2]: " c
  case "$c" in
    1) install_children ;;
    2) remove_children ;;
    *) warn "无效选项" ;;
  esac
}

# -----------------------
# 菜单（带标题，包含卸载选项）
# -----------------------
main_menu(){
  ensure_dirs
  load_mirror
  while true; do
    clear
    cat <<'HEADER'
===========================================
   Proxym‑Easy VLESS 管理器 — 主控面板
   仓库: Lanlan13-14/Proxym-Easy
   脚本位置: /usr/local/bin/proxym-scripts
===========================================
HEADER

    cat <<'MENU'

[1] 🔧 安装 Xray
[2] ⚙️ 生成主配置 main.json 与 dns.json（不含入站）
[3] ➕ 添加节点（选择 Reality / x25519 / mlkem）
[4] ▶️ 启动 Xray
[5] ⏹️ 停止 Xray
[6] 🔄 重启 Xray
[7] 📊 查看状态
[8] 📝 打印 VLESS URI
[9] 📁 子脚本安装/更新/删除
[10] ♻️ proxym-easy reset（重置所有）
[11] 🌐 镜像设置（拉取脚本时套加速）
[12] 🧪 检查/更新 Xray Core
[13] 📝 编辑配置
[14] 🧪 测试配置
[15] ⏰ Cron 管理（重启/重置）
[16] 📤 管理推送（upload）
[17] 🗑️ 卸载（脚本 / Xray）
[0] 退出

MENU
    read -p "选择 [0-17]: " opt
    case "$opt" in
      1) install_xray 1 false false ;;
      2)
         write_dns_config
         write_main_config
         ;;
      3) add_node_menu ;;
      4) start_xray ;;
      5) stop_xray ;;
      6) restart_xray ;;
      7) status_xray ;;
      8) print_vless_uris ;;
      9) manage_children_menu ;;
      10) proxym_easy_reset_all ;;
      11)
         echo "当前镜像前缀: ${MIRROR_PREFIX:-(未设置)}"
         read -p "输入镜像前缀（留空取消）: " prefix
         if [ -n "$prefix" ]; then
           echo -n "$prefix" | sudo tee "$MIRROR_CONF" >/dev/null
           info "已保存镜像前缀: $prefix"
         else
           sudo tee "$MIRROR_CONF" >/dev/null <<< ""
           info "已清除镜像前缀，恢复直接拉取 raw"
         fi
         ;;
      12) update_xray_core ;;
      13) edit_config ;;
      14) test_config ;;
      15)
         echo "[1] 设置 Cron 重启"
         echo "[2] 查看 Cron 重启"
         echo "[3] 删除 Cron 重启"
         read -p "选择 [1-3]: " cc
         case "$cc" in
           1) set_cron_restart ;;
           2) list_cron_restart ;;
           3) delete_cron_restart ;;
           *) warn "无效选项" ;;
         esac
         ;;
      16)
         while true; do
           cat <<PUSH
[1] 列出推送映射
[2] 添加映射
[3] 删除映射
[4] 上传单个
[5] 上传全部
[6] 删除已上传单个
[7] 删除已上传全部
[8] 返回
PUSH
           read -p "选择 [1-8]: " p
           case "$p" in
             1) list_uris_tokens ;;
             2) set_uri_token ;;
             3) delete_uri_token ;;
             4) upload_single_impl ;;
             5) upload_all_impl ;;
             6) delete_uploaded_single_impl ;;
             7) delete_all_uploaded_impl ;;
             8) break ;;
             *) warn "无效选项" ;;
           esac
         done
         ;;
      17)
         echo "[1] 卸载全部脚本（保留 Xray 与 /etc/xray）"
         echo "[2] 卸载 Xray 及全部脚本与配置（彻底）"
         read -p "选择 [1-2]: " u
         case "$u" in
           1) uninstall_all_scripts_only ;;
           2) uninstall_everything_including_xray ;;
           *) warn "无效选项" ;;
         esac
         ;;
      0) info "退出"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
    echo
    read -p "按 Enter 返回菜单..." _ || true
  done
}

# -----------------------
# CLI 入口（兼容 proxym-easy）
# -----------------------
handle_cli_invocation(){
  if [ "$#" -eq 0 ]; then return 0; fi
  local cmd=""
  if [ "$1" = "proxym-easy" ]; then cmd="${2:-}"; else cmd="$1"; fi
  case "$cmd" in
    start) start_xray ;;
    stop) stop_xray ;;
    restart) restart_xray ;;
    state|status) status_xray ;;
    reset) proxym_easy_reset_all ;;
    update-xray) update_xray_core ;;
    uninstall-scripts) uninstall_all_scripts_only ;;
    uninstall-all) uninstall_everything_including_xray ;;
    *) warn "未知命令: $cmd"; return 2 ;;
  esac
  exit 0
}

# -----------------------
# 入口
# -----------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ensure_dirs
  load_mirror
  if [ "$#" -ge 1 ]; then
    handle_cli_invocation "$@"
  fi
  main_menu
fi