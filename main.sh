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
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
CHECK="✔"
WARN="⚠"
ERR="✖"

log()  { printf "%b ℹ %s%b\n" "${GREEN}" "$*" "${NC}"; }
info() { log "$*"; }
warn() { printf "%b %s %s%b\n" "${YELLOW}" "${WARN}" "$*" "${NC}"; }
error(){ printf "%b %s %s%b\n" "${RED}" "${ERR}" "$*" "${NC}"; exit 1; }

# -----------------------
# 基础目录/文件确保
# -----------------------
ensure_dirs() {
  sudo mkdir -p "$LOCAL_SCRIPT_DIR" "$XRAY_DIR" "$(dirname "$VLESS_JSON")" "$(dirname "$URIS_TOKENS")" "$(dirname "$MIRROR_CONF")"
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
  local raw="${SCRIPTS_RAW_BASE}/${name}"
  load_mirror
  if [ -n "${MIRROR_PREFIX}" ]; then
    echo "${MIRROR_PREFIX}/${raw}"
  else
    echo "$raw"
  fi
}

# -----------------------
# 包管理器检测与依赖安装
# -----------------------
detect_package_manager() {
  if command -v apt >/dev/null 2>&1; then
    echo "apt"
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo "yum"
    return
  fi
  if command -v apk >/dev/null 2>&1; then
    echo "apk"
    return
  fi
  if command -v pacman >/dev/null 2>&1; then
    echo "pacman"
    return
  fi
  echo "unknown"
}

install_dependencies() {
  local force_update=${1:-false}
  local pkg_manager
  pkg_manager=$(detect_package_manager)
  local deps=(curl unzip ca-certificates wget gnupg python3 jq)
  local cron_pkg="cron"
  if [ "$pkg_manager" = "apk" ]; then
    cron_pkg="dcron"
  fi
  if [ "$pkg_manager" = "pacman" ] || [ "$pkg_manager" = "yum" ] || [ "$pkg_manager" = "dnf" ]; then
    cron_pkg="cronie"
  fi
  deps+=("$cron_pkg")

  local missing=()
  for dep in "${deps[@]}"; do
    if ! command -v "${dep%% *}" >/dev/null 2>&1; then
      missing+=("$dep")
    fi
  done

  if [ "$force_update" = true ] || [ ${#missing[@]} -gt 0 ]; then
    log "正在安装缺失依赖: ${missing[*]}"
    case "$pkg_manager" in
      apt)
        sudo apt update
        sudo apt install -y "${missing[@]}"
        ;;
      dnf)
        sudo dnf update -y
        sudo dnf install -y "${missing[@]}"
        ;;
      yum)
        sudo yum update -y
        sudo yum install -y "${missing[@]}"
        ;;
      apk)
        sudo apk update
        sudo apk add --no-cache "${missing[@]}"
        ;;
      pacman)
        sudo pacman -Syu --noconfirm "${missing[@]}"
        ;;
      *)
        warn "未知包管理器，请手动安装: ${missing[*]}"
        ;;
    esac
  else
    log "依赖已满足"
  fi
}

# -----------------------
# init 系统检测
# -----------------------
detect_init_system() {
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    echo "systemd"
  elif [ -d /etc/init.d ] && (command -v rc-service >/dev/null 2>&1 || command -v rc-update >/dev/null 2>&1); then
    echo "openrc"
  else
    echo "unknown"
  fi
}

# -----------------------
# 切换 Xray 到 confdir 模式
# -----------------------
switch_to_confdir_mode() {
  local init_system
  init_system=$(detect_init_system)
  log "切换 Xray 为多配置文件模式 (-confdir /etc/xray)"

  if [ "$init_system" = "systemd" ]; then
    local service_dir="/etc/systemd/system/xray.service.d"
    local dropin_file="${service_dir}/override-confdir.conf"

    sudo mkdir -p "$service_dir"
    sudo rm -f "${service_dir}/10-donot_touch_multi_conf.conf" 2>/dev/null || true

    sudo tee "$dropin_file" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/xray run -confdir /etc/xray
EOF
    sudo systemctl daemon-reload
    log "已创建 systemd drop-in 文件: ${dropin_file}"
  elif [ "$init_system" = "openrc" ] && [ -f /etc/init.d/xray ]; then
    sudo sed -i 's|--config[^ ]*|--confdir /etc/xray|g' /etc/init.d/xray 2>/dev/null || true
    sudo rc-service xray restart 2>/dev/null || true
    log "OpenRC 已尝试修改启动参数为 --confdir /etc/xray"
  else
    warn "未知 init 系统，无法自动切换 confdir 模式，请手动修改"
  fi
}

# -----------------------
# Xray 安装/更新
# -----------------------
install_xray() {
  local pause=${1:-1}
  local force_deps=${2:-false}
  local is_update=${3:-false}
  local init_system
  init_system=$(detect_init_system)

  if command -v xray >/dev/null 2>&1 && [ "$is_update" = false ]; then
    log "Xray 已安装。"
    if [ "$pause" -eq 1 ] && [ -z "${NON_INTERACTIVE:-}" ]; then
      read -r -p "按 Enter 返回..."
    fi
    return 0
  fi

  install_dependencies "$force_deps"
  log "安装/更新 Xray..."

  if [ "$init_system" = "openrc" ]; then
    curl -L https://github.com/XTLS/alpinelinux-install-xray/raw/main/install-release.sh -o /tmp/xray-install.sh || error "下载 Alpine 脚本失败"
    ash /tmp/xray-install.sh
    rm -f /tmp/xray-install.sh
  else
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root || true
  fi

  if command -v xray >/dev/null 2>&1; then
    log "Xray 安装/更新成功。"
    switch_to_confdir_mode
    if ! restart_xray; then
      warn "Xray 重启失败，请检查"
    fi
  else
    error "Xray 安装失败"
  fi

  if [ "$pause" -eq 1 ] && [ -z "${NON_INTERACTIVE:-}" ]; then
    read -r -p "按 Enter 返回..."
  fi
}

# -----------------------
# Xray 服务控制
# -----------------------
start_xray() {
  if sudo systemctl start xray 2>/dev/null || sudo rc-service xray start 2>/dev/null; then
    log "Xray 已启动"
    return 0
  else
    warn "启动失败"
    return 1
  fi
}
stop_xray() {
  if sudo systemctl stop xray 2>/dev/null || sudo rc-service xray stop 2>/dev/null; then
    log "Xray 已停止"
    return 0
  else
    warn "停止失败"
    return 1
  fi
}
restart_xray() {
  if sudo systemctl restart xray 2>/dev/null || sudo rc-service xray restart 2>/dev/null; then
    log "Xray 已重启"
    return 0
  else
    warn "重启失败"
    return 1
  fi
}
status_xray() {
  if ! sudo systemctl status xray --no-pager 2>/dev/null; then
    sudo rc-service xray status 2>/dev/null || warn "状态查看失败"
  fi
}
logs_xray() {
  if [ -f "$LOG_FILE" ]; then
    sudo tail -n 200 "$LOG_FILE"
  else
    if ! sudo journalctl -u xray -n 200 --no-pager 2>/dev/null; then
      warn "日志不可用"
    fi
  fi
}

# -----------------------
# 子脚本管理
# -----------------------
install_children() {
  ensure_dirs
  log "安装/更新子脚本..."
  mkdir -p /tmp/proxym-download
  for url in "$REALITY_RAW" "$X25519_RAW" "$MLKEM_RAW"; do
    name=$(basename "$url")
    raw_url=$(get_raw_url "$name")
    tmp="/tmp/proxym-download/${name}.new"
    if curl -fsSL "$raw_url" -o "$tmp"; then
      sudo mv "$tmp" "${LOCAL_SCRIPT_DIR}/${name}"
      sudo chmod +x "${LOCAL_SCRIPT_DIR}/${name}"
      log "已更新 ${name}"
    else
      warn "下载失败: ${raw_url}"
      [ -f "$tmp" ] && rm -f "$tmp"
    fi
  done
  rm -rf /tmp/proxym-download
}

remove_children() {
  sudo rm -rf "$LOCAL_SCRIPT_DIR" && log "子脚本已删除"
}

# -----------------------
# 配置生成
# -----------------------
write_main_config() {
  if [ -f "$MAIN_FILE" ]; then
    read -r -p "${MAIN_FILE} 已存在，覆盖？(y/N): " ow
    if [[ ! "$ow" =~ ^[Yy]$ ]]; then
      return
    fi
  fi
  sudo tee "$MAIN_FILE" >/dev/null <<'EOF'
{
  "log": { "loglevel": "warning" },
  "outbounds": [
    { "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4v6" }, "tag": "direct" }
  ]
}
EOF
  log "已生成 main.json"
}

write_dns_config() {
  if [ -f "$DNS_FILE" ]; then
    read -r -p "${DNS_FILE} 已存在，覆盖？(y/N): " ow
    if [[ ! "$ow" =~ ^[Yy]$ ]]; then
      return
    fi
  fi
  read -r -p "主 DNS (默认 1.1.1.1): " dns1
  dns1=${dns1:-1.1.1.1}
  read -r -p "备 DNS (默认 8.8.8.8): " dns2
  dns2=${dns2:-8.8.8.8}
  sudo tee "$DNS_FILE" >/dev/null <<EOF
{
  "dns": {
    "servers": ["${dns1}", "${dns2}"],
    "queryStrategy": "UseIPv4"
  }
}
EOF
  log "已生成 dns.json"
}

# -----------------------
# 添加节点菜单
# -----------------------
add_node_menu() {
  while true; do
    echo
    echo "[1] 添加 VLESS Reality 节点"
    echo "[2] 添加 VLESS x25519 节点"
    echo "[3] 添加 VLESS MLKEM 节点"
    echo "[4] 返回"
    read -r -p "选择: " c
    case $c in
      1)
        if [ -x "${LOCAL_SCRIPT_DIR}/vless-reality.sh" ]; then
          sudo bash "${LOCAL_SCRIPT_DIR}/vless-reality.sh"
        else
          warn "Reality 子脚本未安装"
        fi
        ;;
      2)
        if [ -x "${LOCAL_SCRIPT_DIR}/vless-x25519.sh" ]; then
          sudo bash "${LOCAL_SCRIPT_DIR}/vless-x25519.sh"
        else
          warn "x25519 子脚本未安装"
        fi
        ;;
      3)
        if [ -x "${LOCAL_SCRIPT_DIR}/vless-mlkem.sh" ]; then
          sudo bash "${LOCAL_SCRIPT_DIR}/vless-mlkem.sh"
        else
          warn "MLKEM 子脚本未安装"
        fi
        ;;
      4) return ;;
      *)
        warn "无效选项"
        ;;
    esac
    read -r -p "按 Enter 继续..." || true
  done
}

# -----------------------
# 卸载函数（含一键重装）
# -----------------------
uninstall_all_scripts_only() {
  echo "即将卸载 Proxym-Easy 脚本（保留 Xray）："
  echo "  - 主命令: ${PROXYM_EASY_PATH}"
  echo "  - 子脚本: ${LOCAL_SCRIPT_DIR}"
  echo "  - 配置: /etc/proxym"
  read -r -p "确认？(y/N): " yn
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    log "取消"
    return
  fi

  sudo rm -f "${PROXYM_EASY_PATH}" && log "已删除主命令"
  sudo rm -rf "${LOCAL_SCRIPT_DIR}" && log "子脚本已删除"
  sudo rm -rf /etc/proxym && log "配置已删除"

  log "卸载完成。"

  echo -e "${GREEN}是否立即重新安装最新版并启动？(y/N)${NC}"
  read -r -p "请输入: " reinstall
  if [[ "$reinstall" =~ ^[Yy]$ ]]; then
    log "下载最新版..."
    curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/main.sh -o /tmp/proxym-easy || error "下载失败"
    chmod +x /tmp/proxym-easy
    sudo mv /tmp/proxym-easy "${PROXYM_EASY_PATH}"
    log "重新安装完成！"
    echo -e "${GREEN}感谢你的使用！正在启动...${NC}"
    exec sudo proxym-easy
  else
    echo -e "如需重新安装："
    echo -e "${GREEN}curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/main.sh -o /tmp/proxym-easy && chmod +x /tmp/proxym-easy && sudo mv /tmp/proxym-easy ${PROXYM_EASY_PATH} && sudo proxym-easy${NC}"
  fi
}

uninstall_everything_including_xray() {
  echo "即将彻底卸载（包括 Xray）："
  read -r -p "确认？不可逆！(y/N): " yn
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    log "取消"
    return
  fi

  stop_xray
  sudo systemctl disable xray 2>/dev/null || sudo rc-update del xray default 2>/dev/null || true
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null || true

  sudo rm -f "${PROXYM_EASY_PATH}"
  sudo rm -rf "${LOCAL_SCRIPT_DIR}" /etc/proxym /etc/xray /var/log/xray /usr/local/bin/xray /usr/bin/xray /usr/local/etc/xray /usr/local/share/xray

  log "彻底卸载完成。"

  echo -e "${GREEN}是否立即重新安装 Proxym-Easy？(y/N)${NC}"
  read -r -p "请输入: " reinstall
  if [[ "$reinstall" =~ ^[Yy]$ ]]; then
    log "重新安装中..."
    curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/main.sh -o /tmp/proxym-easy || error "下载失败"
    chmod +x /tmp/proxym-easy
    sudo mv /tmp/proxym-easy "${PROXYM_EASY_PATH}"
    log "安装完成！"
    echo -e "${GREEN}启动中...${NC}"
    exec sudo proxym-easy
  else
    echo -e "重新安装命令："
    echo -e "${GREEN}curl -L https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/main.sh -o /tmp/proxym-easy && chmod +x /tmp/proxym-easy && sudo mv /tmp/proxym-easy ${PROXYM_EASY_PATH} && sudo proxym-easy${NC}"
  fi
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
[7] 查看状态
[8] 查看日志
[9] 安装/更新 子脚本
[10] 删除 子脚本
[11] 卸载
[0] 退出

EOF
    read -r -p "选择 [0-11]: " opt
    case "$opt" in
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
        echo "[1] 卸载脚本（保留 Xray）"
        echo "[2] 彻底卸载（包括 Xray）"
        read -r -p "选择 [1/2]: " u
        case "$u" in
          1) uninstall_all_scripts_only ;;
          2) uninstall_everything_including_xray ;;
          *) warn "无效" ;;
        esac
        ;;
      0)
        clear
        echo -e "${GREEN}感谢使用 Proxym-Easy！${NC}"
        echo "下次运行： sudo proxym-easy"
        echo "谢谢～"
        exit 0
        ;;
      *) warn "无效选项" ;;
    esac
    read -r -p "按 Enter 返回..." || true
  done
}

# -----------------------
# CLI 支持
# -----------------------
if [ $# -gt 0 ]; then
  case "$1" in
    start) start_xray ;;
    stop) stop_xray ;;
    restart) restart_xray ;;
    status) status_xray ;;
    logs) logs_xray ;;
    *) warn "未知命令，支持: start stop restart status logs" ;;
  esac
  exit 0
fi

main_menu