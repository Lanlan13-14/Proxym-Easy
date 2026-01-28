#!/usr/bin/env bash
# vless-manager.sh - 主控脚本（含镜像设置、主子脚本同时更新、proxym-easy reset）
set -euo pipefail
export LC_ALL=C.UTF-8

# -----------------------
# 常量与路径
# -----------------------
LOCAL_SCRIPT_DIR="/usr/local/bin/proxym-scripts"
SCRIPTS_RAW_BASE="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/script"
SCRIPT_NAMES=("vless-reality.sh" "vless-x25519.sh" "vless-mlkem.sh" "vless-manager.sh")
# note: vless-manager.sh raw path will be constructed from SCRIPTS_RAW_BASE + /vless-manager.sh
VLESS_JSON="/etc/proxym/vless.json"
INBOUNDS_DIR="/etc/xray/inbounds.d"
XDIR="/etc/xray"
DNS_FILE="${XDIR}/dns.json"
BASE_CONFIG="${XDIR}/base_config.json"
URIS_TOKENS="/etc/proxym/uris_tokens.json"
MIRROR_CONF="/etc/proxym/mirror.conf"
LOG_FILE="/var/log/xray/access.log"
XRAY_SERVICE_NAME="xray"

# -----------------------
# 颜色与符号
# -----------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info(){ printf "${GREEN}ℹ %s${NC}\n" "$*"; }
warn(){ printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
err(){ printf "${RED}✖ %s${NC}\n" "$*"; }

# -----------------------
# 基础目录/文件确保
# -----------------------
ensure_dirs(){
  sudo mkdir -p "$LOCAL_SCRIPT_DIR"
  sudo mkdir -p "$INBOUNDS_DIR"
  sudo mkdir -p "$(dirname "$VLESS_JSON")"
  sudo mkdir -p "$(dirname "$URIS_TOKENS")"
  sudo mkdir -p "$(dirname "$MIRROR_CONF")"
  sudo mkdir -p "$(dirname "$DNS_FILE")"
  if [ ! -f "$VLESS_JSON" ]; then echo "[]" | sudo tee "$VLESS_JSON" >/dev/null; fi
  if [ ! -f "$URIS_TOKENS" ]; then echo "{}" | sudo tee "$URIS_TOKENS" >/dev/null; fi
  if [ ! -f "$MIRROR_CONF" ]; then echo "" | sudo tee "$MIRROR_CONF" >/dev/null; fi
}

# -----------------------
# 镜像配置函数
# -----------------------
load_mirror(){
  ensure_dirs
  if [ -f "$MIRROR_CONF" ]; then
    MIRROR_PREFIX=$(sudo sed -n '1p' "$MIRROR_CONF" 2>/dev/null || echo "")
  else
    MIRROR_PREFIX=""
  fi
  MIRROR_PREFIX=${MIRROR_PREFIX:-}
}

save_mirror(){
  local prefix="$1"
  ensure_dirs
  echo -n "$prefix" | sudo tee "$MIRROR_CONF" >/dev/null
  load_mirror
}

get_raw_url(){
  # 参数：basename（例如 vless-reality.sh）
  local name="$1"
  local raw="${SCRIPTS_RAW_BASE}/${name}"
  load_mirror
  if [ -n "$MIRROR_PREFIX" ]; then
    # 如果用户输入的镜像前缀以 raw.githubusercontent.com 开头或包含占位，则直接拼接
    # 允许用户输入像 https://ghproxy.com/ 或 https://mirror.example.com/
    echo "${MIRROR_PREFIX}${raw}"
  else
    echo "$raw"
  fi
}

# -----------------------
# 包管理器检测与依赖安装（保留之前实现）
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
        info "安装 Xray 依赖..."
        case "$pkg_manager" in
            apt) sudo apt update; sudo apt install -y "${deps[@]}"; info "Debian/Ubuntu 依赖安装完成。" ;;
            yum) sudo yum update -y; sudo yum install -y "${deps[@]}"; info "CentOS/RHEL 依赖安装完成。" ;;
            dnf) sudo dnf update -y; sudo dnf install -y "${deps[@]}"; info "Fedora 依赖安装完成。" ;;
            apk) sudo apk update; sudo apk add --no-cache "${deps[@]}"; info "Alpine 依赖安装完成。" ;;
            pacman) sudo pacman -Syu --noconfirm "${deps[@]}"; info "Arch 依赖安装完成。" ;;
            *) warn "未检测到包管理器，请手动安装 curl unzip ca-certificates python3 cron jq。" ;;
        esac
    else
        local missing_deps=()
        for dep in "${deps[@]}"; do
            cmd="${dep%% *}"
            if ! command -v "$cmd" &> /dev/null; then missing_deps+=("$dep"); fi
        done
        if [ ${#missing_deps[@]} -gt 0 ]; then
            info "检测到缺少依赖: ${missing_deps[*]}，正在安装..."
            case "$pkg_manager" in
                apt) sudo apt update; sudo apt install -y "${missing_deps[@]}"; info "Debian/Ubuntu 依赖安装完成。" ;;
                yum) sudo yum install -y "${missing_deps[@]}"; info "CentOS/RHEL 依赖安装完成。" ;;
                dnf) sudo dnf install -y "${missing_deps[@]}"; info "Fedora 依赖安装完成。" ;;
                apk) sudo apk update; sudo apk add --no-cache "${missing_deps[@]}"; info "Alpine 依赖安装完成。" ;;
                pacman) sudo pacman -S --noconfirm "${missing_deps[@]}"; info "Arch 依赖安装完成。" ;;
                *) warn "未检测到包管理器，请手动安装缺少的依赖: ${missing_deps[*]}。" ;;
            esac
        else
            info "依赖已满足。"
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
# Xray 安装/更新/管理（保留并兼容）
# -----------------------
install_xray() {
    local pause=${1:-1}
    local force_deps=${2:-false}
    local is_update=${3:-false}
    local init_system
    init_system=$(detect_init_system)

    if command -v xray &> /dev/null && [ "$is_update" = false ]; then
        info "Xray 已安装。"
        if [ $pause -eq 1 ] && [ "${NON_INTERACTIVE:-}" != "true" ]; then read -p "按 Enter 返回菜单..."; fi
        return 0
    else
        install_dependencies "$force_deps"
        info "安装/更新 Xray..."
        if [ "$init_system" = "openrc" ]; then
            curl -L https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh -o /tmp/install-release.sh
            ash /tmp/install-release.sh
            rm -f /tmp/install-release.sh
            if [ "$is_update" = false ] && [ "${NON_INTERACTIVE:-}" != "true" ]; then
                read -p "是否为 Xray 节点降低网络特权（仅保留 cap_net_bind_service）？(y/N): " reduce_priv
                if [[ $reduce_priv =~ ^[Yy]$ ]]; then
                    if [ -f /etc/init.d/xray ]; then
                      sudo sed -i 's/^capabilities=".*"$/capabilities="^cap_net_bind_service"/g' /etc/init.d/xray || true
                      info "已尝试调整 Xray 网络特权，仅保留 cap_net_bind_service。"
                    fi
                fi
            fi
        else
            bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
        fi

        if [ $? -eq 0 ]; then info "Xray 安装/更新成功。"; else err "Xray 安装/更新失败。"; fi

        if command -v xray &> /dev/null; then restart_xray 0 || true; fi

        if [ $pause -eq 1 ] && [ "${NON_INTERACTIVE:-}" != "true" ]; then read -p "按 Enter 返回菜单..."; fi
    fi
}

update_xray_core() {
    info "检查 Xray Core 更新..."
    if ! command -v xray &> /dev/null; then
        info "Xray 尚未安装，将转到安装程序。"
        install_xray 1 true
        return
    fi
    local current_version latest_version
    current_version=$(xray -version 2>/dev/null | grep -m1 -Eo '([0-9]+\.)+[0-9]+' || true)
    latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -m1 '"tag_name"' | cut -d '"' -f4 | sed 's/^v//')
    if [ -z "$current_version" ]; then warn "无法获取当前 Xray 版本。"; current_version="未知"; fi
    if [ -z "$latest_version" ]; then err "无法获取 Xray 最新版本，请检查网络连接。"; return; fi
    info "当前 Xray 版本: ${current_version}"
    info "最新 Xray 版本: ${latest_version}"
    if [ "$current_version" = "$latest_version" ]; then info "您的 Xray 版本已是最新。"; else
        if [ "${NON_INTERACTIVE:-}" != "true" ]; then read -p "检测到新版本，是否立即更新 Xray Core？ (y/N): " update_choice; else update_choice="n"; fi
        if [[ $update_choice =~ ^[Yy]$ ]]; then install_xray 1 true true; else info "取消更新。"; fi
    fi
    if [ "${NON_INTERACTIVE:-}" != "true" ]; then read -p "按 Enter 返回菜单..."; fi
}

start_xray(){
  if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl start "${XRAY_SERVICE_NAME}" && info "Xray 已通过 systemd 启动" || warn "通过 systemd 启动 Xray 失败"
  else
    err "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}。请安装 Xray 的 systemd 服务或创建 unit。"
    return 1
  fi
}
stop_xray(){
  if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl stop "${XRAY_SERVICE_NAME}" && info "Xray 已通过 systemd 停止" || warn "通过 systemd 停止 Xray 失败"
  else err "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}。无法停止。"; return 1; fi
}
restart_xray(){
  if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl restart "${XRAY_SERVICE_NAME}" && info "Xray 已通过 systemd 重启" || warn "通过 systemd 重启 Xray 失败"
  else err "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}。无法重启。"; return 1; fi
}
status_xray(){
  if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then sudo systemctl status "${XRAY_SERVICE_NAME}" --no-pager; else err "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}。无法显示状态。"; return 1; fi
}
logs_xray(){
  if [ -f "$LOG_FILE" ]; then sudo tail -n 200 "$LOG_FILE"; else if systemctl list-unit-files | grep -q "^${XRAY_SERVICE_NAME}"; then sudo journalctl -u "${XRAY_SERVICE_NAME}" -n 200 --no-pager; else warn "未找到日志文件 ${LOG_FILE}，也未检测到 systemd 服务"; fi; fi
}

# -----------------------
# 子脚本安装/更新/删除（使用镜像前缀）
# -----------------------
install_children(){
  ensure_dirs
  info "安装/更新子脚本到 ${LOCAL_SCRIPT_DIR}"
  for name in "${SCRIPT_NAMES[@]}"; do
    # 主脚本也包含在 SCRIPT_NAMES，raw path built accordingly
    url=$(get_raw_url "$name")
    dest="${LOCAL_SCRIPT_DIR}/${name}"
    info "下载 ${name} -> ${dest}"
    if curl -fsSL "$url" -o "/tmp/${name}.new"; then
      sudo mv "/tmp/${name}.new" "$dest"
      sudo chmod +x "$dest"
      info "已安装/更新 ${name}"
    else
      warn "下载失败: $url"
      [ -f "/tmp/${name}.new" ] && rm -f "/tmp/${name}.new"
    fi
  done
  info "子脚本安装/更新完成。"
}

update_children(){
  install_children
}

remove_children(){
  ensure_dirs
  sudo rm -rf "$LOCAL_SCRIPT_DIR"
  info "已删除子脚本目录 ${LOCAL_SCRIPT_DIR}"
}

# -----------------------
# 自更新：同时更新主脚本与子脚本（使用镜像）
# -----------------------
self_update(){
  ensure_dirs
  info "开始更新 主脚本 与 子脚本（使用镜像: ${MIRROR_PREFIX:-none})"
  # 更新子脚本与主脚本（主脚本名为 vless-manager.sh）
  for name in "${SCRIPT_NAMES[@]}"; do
    url=$(get_raw_url "$name")
    tmp="/tmp/${name}.new"
    info "下载 ${name} <- ${url}"
    if curl -fsSL "$url" -o "$tmp"; then
      if [ "$name" = "vless-manager.sh" ]; then
        # 更新当前运行脚本：先写临时文件，再替换
        sudo mv "$tmp" "$(realpath "$0")"
        sudo chmod +x "$(realpath "$0")"
        info "已更新主脚本"
      else
        sudo mv "$tmp" "${LOCAL_SCRIPT_DIR}/${name}"
        sudo chmod +x "${LOCAL_SCRIPT_DIR}/${name}"
        info "已更新 ${name}"
      fi
    else
      warn "下载失败: $url"
      [ -f "$tmp" ] && rm -f "$tmp"
    fi
  done
  info "主脚本与子脚本更新完成。"
}

# -----------------------
# DNS 与 基础配置生成
# -----------------------
generate_new_config(){
  ensure_dirs
  if [ -f "$DNS_FILE" ]; then
    echo "检测到已存在 DNS 配置："
    cat "$DNS_FILE"
    read -p "是否要修改 DNS 配置? (y/N): " ch
    if [[ ! $ch =~ ^[Yy]$ ]]; then info "保留现有 DNS 配置"; return; fi
  fi
  default1="1.1.1.1"; default2="8.8.8.8"
  read -p "请输入主 DNS（默认 ${default1}）: " DNS_PRIMARY
  DNS_PRIMARY=${DNS_PRIMARY:-$default1}
  read -p "请输入备用 DNS（默认 ${default2}）: " DNS_SECONDARY
  DNS_SECONDARY=${DNS_SECONDARY:-$default2}
  sudo mkdir -p "$XDIR"
  sudo tee "$DNS_FILE" >/dev/null <<EOF
{
  "dns": {
    "servers": ["${DNS_PRIMARY}", "${DNS_SECONDARY}"]
  }
}
EOF
  sudo tee "$BASE_CONFIG" >/dev/null <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["${DNS_PRIMARY}", "${DNS_SECONDARY}"] },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
EOF
  info "已生成基础配置 ${BASE_CONFIG} 并写入 DNS ${DNS_FILE}"
}

# -----------------------
# inbounds 列表与删除
# -----------------------
list_inbounds(){
  ensure_dirs
  echo "inbounds 文件 (${INBOUNDS_DIR}):"
  ls -1 "${INBOUNDS_DIR}" 2>/dev/null || echo "(无文件)"
}

delete_inbound_file(){
  ensure_dirs
  read -p "输入要删除的入站文件名（例如 reality_443.json）: " fname
  if [ -z "$fname" ]; then warn "未输入文件名"; return; fi
  if [ -f "${INBOUNDS_DIR}/${fname}" ]; then
    sudo rm -f "${INBOUNDS_DIR}/${fname}"
    info "已删除 ${INBOUNDS_DIR}/${fname}"
    proto_port="${fname%.*}"
    proto="${proto_port%%_*}"
    port="${proto_port#*_}"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      tmp=$(mktemp)
      jq "map(select(.port != ($port|tonumber)))" "$VLESS_JSON" > "$tmp" && sudo mv "$tmp" "$VLESS_JSON" && info "已从 vless.json 中移除端口 $port 的条目（若存在）"
    fi
  else
    warn "文件不存在: ${INBOUNDS_DIR}/${fname}"
  fi
}

# -----------------------
# URIs 与 上传管理（简化）
# -----------------------
list_uris_tokens(){
  ensure_dirs
  jq -r 'to_entries[] | "[\(.key)] uri: \(.value.uri) endpoint: \(.value.upload_endpoint // "") token: \(.value.upload_token // "")"' "$URIS_TOKENS" 2>/dev/null || echo "{}"
}
set_uri_token(){
  ensure_dirs
  read -p "输入协议_端口 (例如 reality_443): " key
  read -p "输入对应 URI: " uri
  read -p "输入 upload endpoint (例如 https://worker.example/upload): " ep
  read -p "输入 upload token (留空无 token): " tok
  tmp=$(mktemp)
  jq --arg k "$key" --arg uri "$uri" --arg ep "$ep" --arg tok "$tok" '. + {($k): {uri:$uri, upload_endpoint:$ep, upload_token:$tok}}' "$URIS_TOKENS" > "$tmp" && sudo mv "$tmp" "$URIS_TOKENS"
  info "已保存映射 [$key]"
}
delete_uri_token(){
  ensure_dirs
  read -p "输入要删除的协议_端口: " key
  tmp=$(mktemp)
  jq "del(.\"$key\")" "$URIS_TOKENS" > "$tmp" && sudo mv "$tmp" "$URIS_TOKENS"
  info "已删除映射 [$key]"
}
upload_single_impl(){ ensure_dirs; read -p "输入要上传的协议_端口: " key; uri=$(jq -r --arg k "$key" '.[$k].uri // empty' "$URIS_TOKENS"); endpoint=$(jq -r --arg k "$key" '.[$k].upload_endpoint // empty' "$URIS_TOKENS"); token=$(jq -r --arg k "$key" '.[$k].upload_token // empty' "$URIS_TOKENS"); if [ -z "$uri" ] || [ -z "$endpoint" ]; then err "[$key] 未配置 uri 或 endpoint"; return 1; fi; info "上传 [$key] -> $endpoint"; if [ -n "$token" ]; then curl -s -X POST "$endpoint" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "{\"uri\":\"$uri\"}" | sed -n '1,200p'; else curl -s -X POST "$endpoint" -H "Content-Type: application/json" -d "{\"uri\":\"$uri\"}" | sed -n '1,200p'; fi; }
upload_all_impl(){ ensure_dirs; keys=$(jq -r 'keys[]' "$URIS_TOKENS"); for k in $keys; do echo "---- [$k] ----"; uri=$(jq -r --arg k "$k" '.[$k].uri' "$URIS_TOKENS"); endpoint=$(jq -r --arg k "$k" '.[$k].upload_endpoint // empty' "$URIS_TOKENS"); token=$(jq -r --arg k "$k" '.[$k].upload_token // empty' "$URIS_TOKENS"); if [ -z "$endpoint" ]; then warn "[$k] 未配置 endpoint"; continue; fi; if [ -n "$token" ]; then curl -s -X POST "$endpoint" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "{\"uri\":\"$uri\"}" >/dev/null || warn "上传失败 [$k]"; else curl -s -X POST "$endpoint" -H "Content-Type: application/json" -d "{\"uri\":\"$uri\"}" >/dev/null || warn "上传失败 [$k]"; fi; done; info "批量上传完成"; }
delete_uploaded_single_impl(){ ensure_dirs; read -p "输入要删除已上传的协议_端口: " key; uri=$(jq -r --arg k "$key" '.[$k].uri // empty' "$URIS_TOKENS"); endpoint=$(jq -r --arg k "$key" '.[$k].upload_endpoint // empty' "$URIS_TOKENS"); token=$(jq -r --arg k "$key" '.[$k].upload_token // empty' "$URIS_TOKENS"); if [ -z "$uri" ] || [ -z "$endpoint" ]; then err "[$key] 未配置 uri 或 endpoint"; return 1; fi; enc_uri=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$uri" 2>/dev/null || printf '%s' "$uri"); info "删除已上传 [$key] -> ${endpoint}?uri=${enc_uri}"; if [ -n "$token" ]; then curl -s -X DELETE "${endpoint}?uri=${enc_uri}" -H "Authorization: Bearer $token" | sed -n '1,200p'; else curl -s -X DELETE "${endpoint}?uri=${enc_uri}" | sed -n '1,200p'; fi; }
delete_all_uploaded_impl(){ ensure_dirs; keys=$(jq -r 'keys[]' "$URIS_TOKENS"); for k in $keys; do echo "---- [$k] ----"; uri=$(jq -r --arg k "$k" '.[$k].uri' "$URIS_TOKENS"); endpoint=$(jq -r --arg k "$k" '.[$k].upload_endpoint // empty' "$URIS_TOKENS"); token=$(jq -r --arg k "$k" '.[$k].upload_token // empty' "$URIS_TOKENS"); if [ -z "$endpoint" ]; then warn "[$k] 未配置 endpoint"; continue; fi; enc_uri=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$uri" 2>/dev/null || printf '%s' "$uri"); if [ -n "$token" ]; then curl -s -X DELETE "${endpoint}?uri=${enc_uri}" -H "Authorization: Bearer $token" >/dev/null || warn "删除失败 [$k]"; else curl -s -X DELETE "${endpoint}?uri=${enc_uri}" >/dev/null || warn "删除失败 [$k]"; fi; done; info "批量删除已上传完成"; }

# -----------------------
# 调用子脚本 reset（单个）
# -----------------------
call_child_reset(){
  ensure_dirs
  echo "[1] reset reality"
  echo "[2] reset x25519"
  echo "[3] reset mlkem"
  read -p "选择 (1/2/3): " r
  case "$r" in
    1) script="${LOCAL_SCRIPT_DIR}/vless-reality.sh" ;;
    2) script="${LOCAL_SCRIPT_DIR}/vless-x25519.sh" ;;
    3) script="${LOCAL_SCRIPT_DIR}/vless-mlkem.sh" ;;
    *) warn "取消"; return ;;
  esac
  if [ -x "$script" ]; then
    "$script" reset || warn "调用 reset 失败"
    info "已调用 $script reset"
  else warn "未安装或不可执行: $script"; fi
}

# -----------------------
# proxym-easy reset（重置所有）
# -----------------------
proxym_easy_reset_all(){
  ensure_dirs
  info "开始 proxym-easy reset：依次调用已安装的子脚本 reset（仅本协议文件）"
  local any=false
  for s in "vless-reality.sh" "vless-x25519.sh" "vless-mlkem.sh"; do
    if [ -x "${LOCAL_SCRIPT_DIR}/${s}" ]; then
      info "调用 ${s} reset"
      "${LOCAL_SCRIPT_DIR}/${s}" reset || warn "调用 ${s} reset 失败"
      any=true
    else
      info "未安装 ${s}，跳过"
    fi
  done
  if [ "$any" = true ]; then
    read -p "是否重启 Xray 以应用变更? (y/N): " rr
    if [[ $rr =~ ^[Yy]$ ]]; then restart_xray; fi
    info "proxym-easy reset 完成。"
  else
    warn "未检测到任何子脚本，未执行 reset。"
  fi
}

# -----------------------
# 打印 VLESS URI
# -----------------------
print_vless_uris(){
  ensure_dirs
  if [ ! -f "$VLESS_JSON" ]; then echo "[]"; return; fi
  jq -r '.[] | "\(.tag) \(.domain // .ip):\(.port) \n\(.uri)\n"' "$VLESS_JSON"
}

# -----------------------
# 镜像设置菜单
# -----------------------
manage_mirror(){
  ensure_dirs
  load_mirror
  echo "当前镜像前缀: ${MIRROR_PREFIX:-(未设置)}"
  cat <<M
[1] 设置镜像前缀（例如 https://ghproxy.com/ 或 https://mirror.example.com/）
[2] 删除镜像设置（恢复直接拉取 raw）
[3] 返回
M
  read -p "选择 [1-3]: " m
  case "$m" in
    1)
      read -p "输入镜像前缀（以 https:// 开头，结尾不强制斜杠）: " prefix
      prefix=${prefix:-}
      if [ -n "$prefix" ]; then
        # 保证以 / 结尾
        case "$prefix" in */) ;; *) prefix="${prefix}";; esac
        save_mirror "$prefix"
        info "已保存镜像前缀: $prefix"
      else warn "未输入镜像前缀"; fi
      ;;
    2)
      save_mirror ""
      info "已删除镜像设置，恢复直接拉取 raw"
      ;;
    3) return ;;
    *) warn "无效选项" ;;
  esac
}

# -----------------------
# 编辑/测试配置（简短）
# -----------------------
edit_config(){
  ensure_dirs
  if [ -f "/usr/local/etc/xray/config.json" ]; then cfg="/usr/local/etc/xray/config.json"; else cfg="$BASE_CONFIG"; fi
  editor="${EDITOR:-vi}"
  sudo $editor "$cfg"
}
test_config(){
  ensure_dirs
  if command -v xray >/dev/null 2>&1; then
    if [ -d "$XDIR" ]; then info "使用 xray 测试 confdir ${XDIR}"; sudo xray test -confdir "$XDIR" || warn "配置测试失败"; else warn "未找到 ${XDIR}"; fi
  else warn "未安装 xray，无法测试"; fi
}

# -----------------------
# 菜单
# -----------------------
main_menu(){
  ensure_dirs
  load_mirror
  while true; do
    cat <<'MENU'

[1] 🔧 安装 Xray
[2] ⚙️ 生成新配置
[3] ▶️ 启动 Xray
[4] ⏹️ 停止 Xray
[5] 🔄 重启 Xray
[6] 📊 查看状态
[7] 📝 查看日志
[8] 🚀 更新 Xray Core
[9] ⏰ 设置 Cron 重启
[10] 👁️ 查看 Cron 任务 (重启)
[11] 🗑️ 删除 Cron (重启)
[12] 🖨️ 打印 VLESS URI
[13] 🔄 更新脚本（主脚本 + 子脚本）
[14] 🗑️ 卸载
[15] 📝 编辑配置
[16] 🧪 测试配置
[17] 🔄 设置 Cron 重置 UUID/密码
[18] 👁️ 查看 Cron 任务 (重置)
[19] 🗑️ 删除 Cron (重置)
[20] 📤 管理推送设置
[21] 📁 子脚本安装/更新/删除
[22] 📂 列出 inbounds 文件
[23] 🔼 上传单个/全部
[24] 🔽 删除已上传单个/全部
[25] 🔧 安装依赖
[26] 🌐 镜像设置（拉取脚本时套加速）
[27] ♻️ proxym-easy reset（重置所有）
[0] 退出

MENU
    read -p "选择 [0-27]: " opt
    case "$opt" in
      1) install_xray 1 false false ;;
      2) generate_new_config ;;
      3) start_xray ;;
      4) stop_xray ;;
      5) restart_xray ;;
      6) status_xray ;;
      7) logs_xray ;;
      8) update_xray_core ;;
      9) set_cron_restart ;;
      10) list_cron_restart ;;
      11) delete_cron_restart ;;
      12) print_vless_uris ;;
      13) self_update ;;   # 同时更新主子脚本
      14) uninstall ;;
      15) edit_config ;;
      16) test_config ;;
      17) set_cron_reset ;;
      18) list_cron_reset ;;
      19) delete_cron_reset ;;
      20)
         while true; do
           cat <<PUSH
[1] 列出推送映射
[2] 添加映射
[3] 修改映射
[4] 删除映射
[5] 返回
PUSH
           read -p "选择 [1-5]: " p
           case "$p" in
             1) list_uris_tokens ;;
             2) set_uri_token ;;
             3) modify_push_setting ;; # 若未定义，可用 set_uri_token + delete_uri_token 替代
             4) delete_uri_token ;;
             5) break ;;
             *) warn "无效选项" ;;
           esac
         done
         ;;
      21)
         echo "[1] 安装子脚本"
         echo "[2] 更新子脚本"
         echo "[3] 删除子脚本"
         read -p "选择 [1-3]: " c
         case "$c" in
           1) install_children ;;
           2) update_children ;;
           3) remove_children ;;
           *) warn "无效选项" ;;
         esac
         ;;
      22) list_inbounds ;;
      23)
         echo "[1] 上传单个"
         echo "[2] 上传全部"
         read -p "选择 [1/2]: " u
         if [ "$u" = "1" ]; then upload_single_impl; else upload_all_impl; fi
         ;;
      24)
         echo "[1] 删除已上传单个"
         echo "[2] 删除已上传全部"
         read -p "选择 [1/2]: " d
         if [ "$d" = "1" ]; then delete_uploaded_single_impl; else delete_all_uploaded_impl; fi
         ;;
      25)
         read -p "是否强制更新并安装所有依赖? (y/N): " f
         if [[ $f =~ ^[Yy]$ ]]; then install_dependencies true; else install_dependencies false; fi
         ;;
      26) manage_mirror ;;
      27)
         proxym_easy_reset_all
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
    *) warn "未知命令: $cmd"; return 2 ;;
  esac
  exit 0
}

# -----------------------
# 入口
# -----------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ensure_dirs
  load_mirror
  if [ "$#" -ge 1 ]; then
    handle_cli_invocation "$@"
  fi
  main_menu
fi