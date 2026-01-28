#!/bin/bash
# proxym-easy - 主控制脚本
# 版本: 4.5
# 放置: /usr/local/bin/proxym-easy
# chmod +x /usr/local/bin/proxym-easy

set -euo pipefail
export LC_ALL=C.UTF-8

# 颜色与符号
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
CHECK="${GREEN}✅${NC}"; ERROR="${RED}❌${NC}"; INFO="${BLUE}ℹ️${NC}"; WARN="${YELLOW}⚠️${NC}"

# 路径与 URL（可按需修改）
CONFIG="/usr/local/etc/xray/config.json"
VLESS_JSON="/etc/proxym/vless.json"
GLOBAL_JSON="/etc/proxym/global.json"
SCRIPT_PATH="/usr/local/bin/proxym-easy"
UPDATE_URL="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/vless-encryption.sh"
VLESS_SCRIPT_URL="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/script/vless_encryption.sh"

CRON_FILE="/tmp/proxym_cron.tmp"
NON_INTERACTIVE=false

# 默认 CLIENT_TOKEN（若 global.json 中有 client_token 会覆盖）
CLIENT_TOKEN_DEFAULT="supersecretclienttoken123456"
CLIENT_TOKEN="$CLIENT_TOKEN_DEFAULT"

# 确保目录
sudo mkdir -p /etc/proxym
sudo mkdir -p "$(dirname "$CONFIG")"

# 简单日志函数
log() { echo -e "${INFO} $1${NC}"; }
error() { echo -e "${ERROR} $1${NC}"; exit 1; }

# URL 编码（使用 python3）
url_encode() {
  if command -v python3 &>/dev/null; then
    python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))" <<< "$1"
  else
    echo "$1"
  fi
}

# 载入/保存全局配置（包含 client_token）
load_global_config() {
  if [ -f "$GLOBAL_JSON" ]; then
    dns_server=$(jq -r '.dns_server // "1.1.1.1"' "$GLOBAL_JSON")
    strategy=$(jq -r '.strategy // "UseIPv4"' "$GLOBAL_JSON")
    domain_strategy=$(jq -r '.domain_strategy // "UseIPv4v6"' "$GLOBAL_JSON")
    token_from_file=$(jq -r '.client_token // empty' "$GLOBAL_JSON" 2>/dev/null || echo "")
    if [ -n "$token_from_file" ]; then
      CLIENT_TOKEN="$token_from_file"
    fi
  else
    dns_server="1.1.1.1"
    strategy="UseIPv4"
    domain_strategy="UseIPv4v6"
  fi
}

save_global_config() {
  cat > "$GLOBAL_JSON" <<EOF
{
  "dns_server": "$dns_server",
  "strategy": "$strategy",
  "domain_strategy": "$domain_strategy",
  "client_token": "$CLIENT_TOKEN"
}
EOF
  log "全局配置已保存到 $GLOBAL_JSON"
}

# 包管理器检测与依赖安装（确保脚本所需依赖）
detect_package_manager() {
  if command -v apt &>/dev/null; then echo "apt"
  elif command -v yum &>/dev/null; then echo "yum"
  elif command -v dnf &>/dev/null; then echo "dnf"
  elif command -v apk &>/dev/null; then echo "apk"
  elif command -v pacman &>/dev/null; then echo "pacman"
  else echo "none"; fi
}

install_dependencies() {
  local pkg_manager
  pkg_manager=$(detect_package_manager)
  local deps=(curl wget jq python3 openssl unzip ca-certificates gnupg)
  local cron_pkg="cron"
  if [ "$pkg_manager" = "apk" ]; then cron_pkg="dcron"; fi
  if [ "$pkg_manager" = "pacman" ] || [ "$pkg_manager" = "yum" ] || [ "$pkg_manager" = "dnf" ]; then cron_pkg="cronie"; fi
  deps+=("$cron_pkg")
  case "$pkg_manager" in
    apt)
      sudo apt update
      sudo apt install -y "${deps[@]}"
      ;;
    yum)
      sudo yum update -y
      sudo yum install -y "${deps[@]}"
      ;;
    dnf)
      sudo dnf update -y
      sudo dnf install -y "${deps[@]}"
      ;;
    apk)
      sudo apk update
      sudo apk add --no-cache "${deps[@]}"
      ;;
    pacman)
      sudo pacman -Syu --noconfirm "${deps[@]}"
      ;;
    *)
      echo -e "${WARN} 未检测到包管理器，请手动安装: ${deps[*]}${NC}"
      ;;
  esac
  log "依赖安装/检查完成。"
}

# init system 检测
detect_init_system() {
  if command -v systemctl &>/dev/null; then echo "systemd"
  elif command -v rc-service &>/dev/null; then echo "openrc"
  else echo "none"; fi
}

# Xray 控制（start/stop/restart/status）
start_xray() {
  local init_system; init_system=$(detect_init_system)
  if [ "$init_system" = "systemd" ]; then sudo systemctl start xray || true
  elif [ "$init_system" = "openrc" ]; then sudo rc-service xray start || true
  else
    if command -v xray &>/dev/null; then nohup xray run -c "$CONFIG" >/dev/null 2>&1 & fi
  fi
  log "Xray 已启动。"
}

stop_xray() {
  local init_system; init_system=$(detect_init_system)
  if [ "$init_system" = "systemd" ]; then sudo systemctl stop xray || true
  elif [ "$init_system" = "openrc" ]; then sudo rc-service xray stop || true
  else pkill -f 'xray' || true; fi
  log "Xray 已停止。"
}

restart_xray() {
  stop_xray
  sleep 1
  start_xray
  log "Xray 已重启。"
}

status_xray() {
  local init_system; init_system=$(detect_init_system)
  if [ "$init_system" = "systemd" ]; then sudo systemctl status xray --no-pager || true
  elif [ "$init_system" = "openrc" ]; then sudo rc-service xray status || true
  else ps aux | grep -E 'xray' | grep -v grep || true; fi
}

# 更新脚本（从 UPDATE_URL）
update_script() {
  log "检查更新..."
  if [ ! -f "$SCRIPT_PATH" ]; then error "脚本未在 $SCRIPT_PATH 找到"; fi
  cp "$SCRIPT_PATH" "${SCRIPT_PATH}.bak"
  if ! curl -fsSL -o "${SCRIPT_PATH}.new" "$UPDATE_URL"; then
    mv "${SCRIPT_PATH}.bak" "$SCRIPT_PATH"
    error "从 $UPDATE_URL 下载更新失败"
  fi
  if bash -n "${SCRIPT_PATH}.new" 2>/dev/null; then
    mv "${SCRIPT_PATH}.new" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    log "更新成功，已替换脚本。"
    rm -f "${SCRIPT_PATH}.bak"
    exec bash "$SCRIPT_PATH"
  else
    rm -f "${SCRIPT_PATH}.new"
    mv "${SCRIPT_PATH}.bak" "$SCRIPT_PATH"
    error "更新语法错误，已回滚。"
  fi
}

# 删除节点接口（按 tag 或 push_token 匹配），供 webhook 调用
# 示例: curl 'https://example.workers.dev/delete?token=CLIENT_TOKEN&server=hk01'
delete_node_by_identifier() {
  local token="$1"; local server="$2"
  if [ -z "$token" ] || [ -z "$server" ]; then echo "Missing token or server"; return 1; fi
  load_global_config
  if [ "$token" != "$CLIENT_TOKEN" ]; then echo "Unauthorized"; return 1; fi
  if [ ! -f "$VLESS_JSON" ]; then echo "No nodes file"; return 1; fi
  jq --arg s "$server" 'map(select(.tag != $s and (.push_token // "") != $s))' "$VLESS_JSON" > "${VLESS_JSON}.tmp" && mv "${VLESS_JSON}.tmp" "$VLESS_JSON"
  # 如果外部脚本提供 regenerate_full_config/restart_xray，则调用
  if declare -f regenerate_full_config >/dev/null 2>&1; then regenerate_full_config; fi
  if declare -f restart_xray >/dev/null 2>&1; then restart_xray; fi
  echo "Deleted"
  return 0
}

# 拉取并 source 外部 vless 脚本（节点生成/配置逻辑全部放外部）
fetch_and_source_vless_script() {
  local tmp="/tmp/vless_encryption.sh"
  if curl -fsSL "$VLESS_SCRIPT_URL" -o "$tmp"; then
    chmod +x "$tmp"
    # shellcheck disable=SC1090
    source "$tmp"
    log "已加载外部 vless 脚本：$VLESS_SCRIPT_URL"
    return 0
  else
    log "无法拉取外部 vless 脚本，确保 $VLESS_SCRIPT_URL 可访问。"
    return 1
  fi
}

# 安装/更新 Xray（包装）
install_xray_wrapper() {
  install_dependencies
  local init_system; init_system=$(detect_init_system)
  if [ "$init_system" = "openrc" ]; then
    curl -fsSL https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh -o /tmp/install-release.sh
    ash /tmp/install-release.sh || error "Xray 安装失败"
    rm -f /tmp/install-release.sh
  else
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root || error "Xray 安装失败"
  fi
  log "Xray 安装/更新完成"
  restart_xray
}

# 命令行子命令支持
if [ "${1:-}" = "update" ]; then update_script; exit 0; fi
if [ "${1:-}" = "stop" ]; then stop_xray; exit 0; fi
if [ "${1:-}" = "start" ]; then start_xray; exit 0; fi
if [ "${1:-}" = "restart" ]; then restart_xray; exit 0; fi
if [ "${1:-}" = "state" ]; then status_xray; exit 0; fi

# 主菜单（选项2拆分为子菜单）
main_menu() {
  fetch_and_source_vless_script
  while true; do
    echo "================ proxym-easy ================"
    echo "1) 安装/更新 Xray 并安装依赖"
    echo "2) 生成 VLESS 配置（子菜单）"
    echo "3) 删除单个服务器节点（按 tag 或 push_token）"
    echo "4) Xray 控制: start/stop/restart/state"
    echo "5) 更新 proxym-easy 脚本"
    echo "6) 保存/查看全局配置"
    echo "0) 退出"
    read -p "请选择: " opt
    case "$opt" in
      1)
        install_dependencies
        install_xray_wrapper
        ;;
      2)
        while true; do
          echo "---- 生成 VLESS 配置 子菜单 ----"
          echo "1) 添加 Vless"
          echo "2) 返回"
          read -p "请选择: " subopt
          case "$subopt" in
            1)
              if declare -f add_vless >/dev/null 2>&1; then
                add_vless
              else
                echo "add_vless 未实现或外部脚本加载失败。"
              fi
              ;;
            2) break ;;
            *) echo "无效选项" ;;
          esac
        done
        ;;
      3)
        read -p "请输入 CLIENT_TOKEN: " token
        read -p "请输入要删除的 server 标识 (tag 或 push_token): " server
        delete_node_by_identifier "$token" "$server"
        ;;
      4)
        echo "a) start  b) stop  c) restart  d) state"
        read -p "选择: " ctl
        case "$ctl" in
          a) start_xray ;;
          b) stop_xray ;;
          c) restart_xray ;;
          d) status_xray ;;
          *) echo "无效" ;;
        esac
        ;;
      5) update_script ;;
      6)
        load_global_config
        echo "当前全局配置:"
        cat "$GLOBAL_JSON" 2>/dev/null || echo "{}"
        read -p "是否编辑 CLIENT_TOKEN? (y/N): " yn
        if [[ $yn =~ ^[Yy]$ ]]; then
          read -p "请输入新的 CLIENT_TOKEN: " newt
          CLIENT_TOKEN="$newt"
          save_global_config
        fi
        ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

main_menu