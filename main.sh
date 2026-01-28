#!/usr/bin/env bash
# proxym-easy - Proxym-Easy 主控脚本（完整版，已融合所有修改）
# 仓库: https://github.com/Lanlan13-14/Proxym-Easy
# 运行需 sudo 权限
set -euo pipefail
export LC_ALL=C.UTF-8

# -----------------------
# 常量与路径
# -----------------------
LOCAL_SCRIPT_DIR="/usr/local/bin/proxym-scripts"
SCRIPTS_RAW_BASE="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/script"
REALITY_RAW="${SCRIPTS_RAW_BASE}/vless-reality.sh"
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
PROXYM_EASY_PATH="/usr/local/bin/proxym-easy"

# -----------------------
# 颜色与符号
# -----------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
CHECK="✔"
WARN="⚠"
ERR="✖"

log() { printf "%b ℹ %s%b\n" "\( {GREEN}" " \)*" "${NC}"; }
info() { log "$*"; }
warn() { printf "%b %s %s%b\n" "\( {YELLOW}" " \){WARN}" "\( *" " \){NC}"; }
error() { printf "%b %s %s%b\n" "\( {RED}" " \){ERR}" "\( *" " \){NC}"; exit 1; }

# -----------------------
# 基础目录/文件确保
# -----------------------
ensure_dirs() {
  sudo mkdir -p "$LOCAL_SCRIPT_DIR" "\( XRAY_DIR" " \)(dirname "\( VLESS_JSON")" " \)(dirname "\( URIS_TOKENS")" " \)(dirname "$MIRROR_CONF")"
  [ ! -f "$VLESS_JSON" ] && echo "[]" | sudo tee "$VLESS_JSON" >/dev/null
  [ ! -f "$URIS_TOKENS" ] && echo "{}" | sudo tee "$URIS_TOKENS" >/dev/null
  [ ! -f "$MIRROR_CONF" ] && echo "" | sudo tee "$MIRROR_CONF" >/dev/null
}

# -----------------------
# 镜像前缀
# -----------------------
load_mirror() {
  ensure_dirs
  MIRROR_PREFIX=$(sudo sed -n '1p' "$MIRROR_CONF" 2>/dev/null || echo "")
}

get_raw_url() {
  local name="$1"
  local raw="\( {SCRIPTS_RAW_BASE}/ \){name}"
  load_mirror
  [ -n "\( MIRROR_PREFIX" ] && echo " \){MIRROR_PREFIX}/${raw}" || echo "$raw"
}

# -----------------------
# 包管理器检测与依赖安装
# -----------------------
detect_package_manager() {
  command -v apt >/dev/null && echo "apt" && return
  command -v dnf >/dev/null && echo "dnf" && return
  command -v yum >/dev/null && echo "yum" && return
  command -v apk >/dev/null && echo "apk" && return
  command -v pacman >/dev/null && echo "pacman" && return
  echo "unknown"
}

install_dependencies() {
  local force_update=${1:-false}
  local pkg_manager=$(detect_package_manager)
  local deps=("curl" "unzip" "ca-certificates" "wget" "gnupg" "python3" "jq")
  local cron_pkg="cron"
  [ "$pkg_manager" = "apk" ] && cron_pkg="dcron"
  [[ "$pkg_manager" = "pacman" || "$pkg_manager" = "yum" || "$pkg_manager" = "dnf" ]] && cron_pkg="cronie"
  deps+=("$cron_pkg")

  if [ "$force_update" = true ] || [ ${#deps[@]} -gt 0 ]; then
    case "$pkg_manager" in
      apt) sudo apt update && sudo apt install -y "${deps[@]}" ;;
      dnf) sudo dnf update -y && sudo dnf install -y "${deps[@]}" ;;
      yum) sudo yum update -y && sudo yum install -y "${deps[@]}" ;;
      apk) sudo apk update && sudo apk add --no-cache "${deps[@]}" ;;
      pacman) sudo pacman -Syu --noconfirm "${deps[@]}" ;;
      *) warn "未知包管理器，请手动安装依赖: curl unzip ca-certificates wget gnupg python3 jq ${cron_pkg}" ;;
    esac
    log "依赖安装完成"
  fi
}

# -----------------------
# init 系统检测
# -----------------------
detect_init_system() {
  if command -v systemctl >/dev/null && systemctl --version >/dev/null 2>&1; then
    echo "systemd"
  elif [ -d /etc/init.d ] && (command -v rc-service || command -v rc-update) >/dev/null; then
    echo "openrc"
  else
    echo "unknown"
  fi
}

# -----------------------
# 切换 Xray 到 confdir 模式（-confdir /etc/xray）
# -----------------------
switch_to_confdir_mode() {
  local init_system=$(detect_init_system)
  log "切换 Xray 配置模式为 -confdir /etc/xray"

  if [ "$init_system" = "systemd" ]; then
    local service_dir="/etc/systemd/system/xray.service.d"
    local dropin_file="${service_dir}/override-confdir.conf"

    sudo mkdir -p "$service_dir"
    sudo rm -f "${service_dir}/10-donot_touch_multi_conf.conf" 2>/dev/null

    sudo tee "$dropin_file" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/xray run -confdir /etc/xray
EOF
    sudo systemctl daemon-reload
    log "systemd drop-in 已创建：${dropin_file}"
  elif [ "$init_system" = "openrc" ] && [ -f /etc/init.d/xray ]; then
    sudo sed -i 's|--config.*|--confdir /etc/xray|g' /etc/init.d/xray 2>/dev/null || true
    sudo rc-service xray restart 2>/dev/null || true
    log "OpenRC 已修改 xray 启动参数为 --confdir /etc/xray"
  else
    warn "未知 init 系统，无法自动切换 confdir 模式，请手动修改服务文件"
  fi
}

# -----------------------
# Xray 安装/更新
# -----------------------
install_xray() {
  local pause=${1:-1}
  local force_deps=${2:-false}
  local is_update=${3:-false}
  local init_system=$(detect_init_system)

  if command -v xray >/dev/null && [ "$is_update" = false ]; then
    log "Xray 已安装。"
    [ "\( pause" -eq 1 ] && [ -z " \){NON_INTERACTIVE:-}" ] && read -p "按 Enter 返回菜单..."
    return 0
  fi

  install_dependencies "$force_deps"
  log "正在安装/更新 Xray..."

  if [ "$init_system" = "openrc" ]; then
    log "检测到 OpenRC (Alpine)，使用专用安装脚本"
    curl -L https://github.com/XTLS/alpinelinux-install-xray/raw/main/install-release.sh -o /tmp/xray-install.sh || error "下载 Alpine Xray 安装脚本失败"
    ash /tmp/xray-install.sh
    rm -f /tmp/xray-install.sh
  else
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
  fi

  if command -v xray >/dev/null; then
    log "Xray 安装/更新成功。"
    switch_to_confdir_mode
    restart_xray || warn "Xray 重启失败，请检查配置和服务"
  else
    error "Xray 安装失败，请检查网络或日志"
  fi

  [ "\( pause" -eq 1 ] && [ -z " \){NON_INTERACTIVE:-}" ] && read -p "按 Enter 返回菜单..."
}

# -----------------------
# Xray 服务管理
# -----------------------
start_xray()   { sudo systemctl start xray 2>/dev/null || sudo rc-service xray start 2>/dev/null && log "Xray 已启动" || warn "启动失败"; }
stop_xray()    { sudo systemctl stop xray 2>/dev/null || sudo rc-service xray stop 2>/dev/null && log "Xray 已停止" || warn "停止失败"; }
restart_xray() { sudo systemctl restart xray 2>/dev/null || sudo rc-service xray restart 2>/dev/null && log "Xray 已重启" || warn "重启失败"; }
status_xray()  { sudo systemctl status xray --no-pager 2>/dev/null || sudo rc-service xray status 2>/dev/null || warn "无法查看状态"; }
logs_xray()    {
  if [ -f "$LOG_FILE" ]; then
    sudo tail -n 200 "$LOG_FILE"
  else
    sudo journalctl -u xray -n 200 --no-pager 2>/dev/null || warn "无日志文件或 journalctl 不可用"
  fi
}

# -----------------------
# 子脚本管理
# -----------------------
install_children() {
  ensure_dirs
  log "安装/更新子脚本..."
  mkdir -p /tmp/proxym-download
  for script in "$REALITY_RAW" "$X25519_RAW" "$MLKEM_RAW"; do
    name=$(basename "$script")
    url=$(get_raw_url "$name")
    tmp="/tmp/proxym-download/${name}.new"
    if curl -fsSL "$url" -o "$tmp"; then
      sudo mv "\( tmp" " \){LOCAL_SCRIPT_DIR}/${name}"
      sudo chmod +x "\( {LOCAL_SCRIPT_DIR}/ \){name}"
      log "已安装/更新 ${name}"
    else
      warn "下载失败: ${url}"
    fi
  done
  rm -rf /tmp/proxym-download
  log "子脚本处理完成"
}

remove_children() {
  sudo rm -rf "$LOCAL_SCRIPT_DIR" && log "子脚本目录已删除"
}

# -----------------------
# 配置生成
# -----------------------
write_main_config() {
  if [ -f "$MAIN_FILE" ]; then
    read -p "${MAIN_FILE} 已存在，是否覆盖？(y/N): " overwrite
    [[ "\( overwrite" =~ ^[Yy] \) ]] || return
  fi
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
  log "已写入 main.json"
}

write_dns_config() {
  if [ -f "$DNS_FILE" ]; then
    read -p "${DNS_FILE} 已存在，是否覆盖？(y/N): " overwrite
    [[ "\( overwrite" =~ ^[Yy] \) ]] || return
  fi
  read -p "主 DNS (默认 1.1.1.1): " dns1
  dns1=${dns1:-1.1.1.1}
  read -p "备 DNS (默认 8.8.8.8): " dns2
  dns2=${dns2:-8.8.8.8}
  sudo tee "$DNS_FILE" >/dev/null <<EOF
{
  "dns": {
    "servers": [
      "${dns1}",
      "${dns2}"
    ],
    "queryStrategy": "UseIPv4"
  }
}
EOF
  log "已写入 dns.json"
}

# -----------------------
# 节点管理（简化版，假设子脚本存在）
# -----------------------
add_node_menu() {
  while true; do
    echo
    echo "[1] 添加 VLESS Reality 节点"
    echo "[2] 添加 VLESS x25519 节点"
    echo "[3] 添加 VLESS MLKEM 节点"
    echo "[4] 返回"
    read -p "选择 [1-4]: " choice
    case $choice in
      1) [ -x "\( {LOCAL_SCRIPT_DIR}/vless-reality.sh" ] && sudo " \){LOCAL_SCRIPT_DIR}/vless-reality.sh" || warn "子脚本未安装" ;;
      2) [ -x "\( {LOCAL_SCRIPT_DIR}/vless-x25519.sh" ] && sudo " \){LOCAL_SCRIPT_DIR}/vless-x25519.sh" || warn "子脚本未安装" ;;
      3) [ -x "\( {LOCAL_SCRIPT_DIR}/vless-mlkem.sh" ] && sudo " \){LOCAL_SCRIPT_DIR}/vless-mlkem.sh" || warn "子脚本未安装" ;;
      4) return ;;
      *) warn "无效选项" ;;
    esac
    read -p "按 Enter 继续..." || true
  done
}

# -----------------------
# 卸载函数
# -----------------------
uninstall_all_scripts_only() {
  echo "即将卸载 Proxym-Easy 脚本部分（保留 Xray 和 /etc/xray）："
  echo "  - 主命令: ${PROXYM_EASY_PATH}"
  echo "  - 子脚本目录: ${LOCAL_SCRIPT_DIR}"
  echo "  - 配置目录: /etc/proxym"
  read -p "确认卸载？(y/N): " yn
  [[ "\( yn" =~ ^[Yy] \) ]] || { log "取消卸载"; return; }

  sudo rm -f "${PROXYM_EASY_PATH}" && log "已删除主命令 ${PROXYM_EASY_PATH}"
  sudo rm -rf "${LOCAL_SCRIPT_DIR}" && log "子脚本目录已删除"
  sudo rm -rf /etc/proxym && log "配置目录已删除"

  log "Proxym-Easy 脚本卸载完成。"
  echo -e "如需重新安装，请执行："
  echo -e "${GREEN}curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/main.sh -o /tmp/proxym-easy && chmod +x /tmp/proxym-easy && sudo mv /tmp/proxym-easy \( {PROXYM_EASY_PATH} && sudo proxym-easy \){NC}"
}

uninstall_everything_including_xray() {
  echo "即将彻底卸载 Proxym-Easy 和 Xray（不可逆）："
  echo "  - 主命令、子脚本、/etc/proxym"
  echo "  - Xray 二进制、服务、配置 (/etc/xray 等)"
  read -p "确认彻底卸载？(y/N): " yn
  [[ "\( yn" =~ ^[Yy] \) ]] || { log "取消卸载"; return; }

  stop_xray
  sudo systemctl disable xray 2>/dev/null || sudo rc-update del xray default 2>/dev/null || true

  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null || true

  sudo rm -f "${PROXYM_EASY_PATH}"
  sudo rm -rf "${LOCAL_SCRIPT_DIR}" /etc/proxym /etc/xray /var/log/xray /usr/local/bin/xray /usr/bin/xray /usr/local/etc/xray /usr/local/share/xray

  log "彻底卸载完成。"
  echo -e "重新安装命令："
  echo -e "${GREEN}curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/main.sh -o /tmp/proxym-easy && chmod +x /tmp/proxym-easy && sudo mv /tmp/proxym-easy \( {PROXYM_EASY_PATH} && sudo proxym-easy \){NC}"
}

# -----------------------
# 主菜单
# -----------------------
main_menu() {
  ensure_dirs
  load_mirror

  while true; do
    clear
    cat <<'EOF'
===========================================
       Proxym-Easy VLESS 管理器
===========================================

[1] 安装/更新 Xray
[2] 生成 main.json & dns.json
[3] 添加节点
[4] 启动 Xray
[5] 停止 Xray
[6] 重启 Xray
[7] 查看 Xray 状态
[8] 查看 Xray 日志
[9] 安装/更新 子脚本
[10] 删除 子脚本
[11] 卸载 Proxym-Easy
[0] 退出

EOF

    read -p "请选择 [0-11]: " choice
    case $choice in
      1) install_xray ;;
      2) write_dns_config; write_main_config ;;
      3) add_node_menu ;;
      4) start_xray ;;
      5) stop_xray ;;
      6) restart_xray ;;
      7) status_xray ;;
      8) logs_xray ;;
      9) install_children ;;
      10) remove_children ;;
      11)
        echo "[1] 仅卸载 Proxym-Easy 脚本（保留 Xray）"
        echo "[2] 彻底卸载（包括 Xray）"
        read -p "选择 [1/2]: " u
        case $u in
          1) uninstall_all_scripts_only ;;
          2) uninstall_everything_including_xray ;;
          *) warn "无效选择" ;;
        esac
        ;;
      0)
        clear
        echo -e "\( {GREEN}感谢使用 Proxym-Easy！ \){NC}"
        echo "下次运行请输入："
        echo -e "  \( {GREEN}sudo proxym-easy \){NC}"
        echo "常用快捷命令示例："
        echo "  sudo proxym-easy restart"
        echo "  sudo proxym-easy reset   （如果已实现 reset 功能）"
        exit 0
        ;;
      *) warn "无效选项，请重新输入" ;;
    esac
    [ -z "${NON_INTERACTIVE:-}" ] && read -p "按 Enter 返回主菜单..." || true
  done
}

# -----------------------
# CLI 模式支持（可选）
# -----------------------
if [ $# -gt 0 ]; then
  case "$1" in
    start)    start_xray ;;
    stop)     stop_xray ;;
    restart)  restart_xray ;;
    status)   status_xray ;;
    logs)     logs_xray ;;
    *) warn "不支持的命令: $1 （支持: start/stop/restart/status/logs）" ;;
  esac
  exit 0
fi

# 默认进入菜单
main_menu