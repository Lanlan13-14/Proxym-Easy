#!/usr/bin/env bash
# proxym-easy - Proxym‑Easy 主控脚本（完整）
# 说明：需要 sudo 权限运行。管理 Xray、子脚本、生成 config.json/dns.json、安装/卸载、添加节点等。
set -euo pipefail
export LC_ALL=C.UTF-8

# -----------------------
# 常量与路径
# -----------------------
LOCAL_SCRIPT_DIR="/usr/local/bin/proxym-scripts"
PROXYM_EASY_PATH="/usr/local/bin/proxym-easy"
SCRIPTS_RAW_BASE="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/script"
REALITY_RAW="${SCRIPTS_RAW_BASE}/vless-reality.sh"
X25519_RAW="${SCRIPTS_RAW_BASE}/vless-x25519.sh"
MLKEM_RAW="${SCRIPTS_RAW_BASE}/vless-mlkem.sh"

XRAY_DIR="/etc/xray"
CONFIG_FILE="${XRAY_DIR}/config.json"
DNS_FILE="${XRAY_DIR}/dns.json"
VLESS_JSON="/etc/proxym/vless.json"
URI_JSON_DIR="/etc/proxym-easy"
URI_JSON="${URI_JSON_DIR}/uri.json"
URIS_TOKENS="/etc/proxym/uris_tokens.json"
MIRROR_CONF="/etc/proxym/mirror.conf"
XRAY_SERVICE_NAME="xray"
LOG_FILE="/var/log/xray/access.log"

# -----------------------
# 颜色与符号
# -----------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
CHECK="✔"; WARN="⚠"; ERR="✖"

log(){ printf "${GREEN}ℹ %s${NC}\n" "$*"; }
info(){ log "$*"; }
warn(){ printf "${YELLOW}%s %s${NC}\n" "$WARN" "$*"; }
error(){ printf "${RED}%s %s${NC}\n" "$ERR" "$*"; }

# -----------------------
# 基础目录/文件确保
# -----------------------
ensure_dirs(){
  sudo mkdir -p "$LOCAL_SCRIPT_DIR" "$XRAY_DIR" "$(dirname "$VLESS_JSON")" "$URI_JSON_DIR" "$(dirname "$URIS_TOKENS")" "$(dirname "$MIRROR_CONF")"
  sudo touch "$VLESS_JSON" "$URIS_TOKENS" "$URI_JSON" 2>/dev/null || true
  # initialize files if empty
  if [ ! -s "$VLESS_JSON" ]; then echo "[]" | sudo tee "$VLESS_JSON" >/dev/null; fi
  if [ ! -s "$URIS_TOKENS" ]; then echo "{}" | sudo tee "$URIS_TOKENS" >/dev/null; fi
  if [ ! -s "$URI_JSON" ]; then echo "[]" | sudo tee "$URI_JSON" >/dev/null; fi
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
    # allow mirror prefix to be full URL prefix
    case "$MIRROR_PREFIX" in
      */) echo "${MIRROR_PREFIX}${raw#https://}" ;;
      *)  echo "${MIRROR_PREFIX}${raw}" ;;
    esac
  else
    echo "$raw"
  fi
}

# -----------------------
# 包管理器检测与依赖安装（简化）
# -----------------------
detect_package_manager(){
  if command -v apt >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  else echo "unknown"; fi
}
install_dependencies(){
  local force=${1:-false}
  local pm; pm=$(detect_package_manager)
  local deps=(curl wget jq python3)
  if [ "$pm" = "apt" ]; then
    sudo apt update
    sudo apt install -y "${deps[@]}"
  elif [ "$pm" = "apk" ]; then
    sudo apk add --no-cache "${deps[@]}"
  elif [ "$pm" = "dnf" ] || [ "$pm" = "yum" ]; then
    sudo $pm install -y "${deps[@]}"
  elif [ "$pm" = "pacman" ]; then
    sudo pacman -Syu --noconfirm "${deps[@]}"
  else
    warn "未识别包管理器，请手动安装: ${deps[*]}"
  fi
}

# -----------------------
# init 系统检测
# -----------------------
detect_init_system(){
  if command -v systemctl >/dev/null 2>&1; then echo "systemd"
  elif command -v rc-service >/dev/null 2>&1; then echo "openrc"
  else echo "none"; fi
}

# -----------------------
# 切换 Xray 到 confdir 模式（并确保主配置名为 config.json，dns.json）
# -----------------------
switch_to_confdir_mode(){
  local init; init=$(detect_init_system)
  log "切换 Xray 为多配置文件模式 (-confdir /etc/xray) 并确保主配置名为 config.json"
  sudo mkdir -p "$XRAY_DIR"

  local XRAY_BIN
  XRAY_BIN="$(command -v xray 2>/dev/null || true)"
  XRAY_BIN=${XRAY_BIN:-/usr/bin/xray}

  if [ "$init" = "systemd" ]; then
    local service_dir="/etc/systemd/system/${XRAY_SERVICE_NAME}.service.d"
    local dropin="${service_dir}/override.conf"
    sudo mkdir -p "$service_dir"
    sudo tee "$dropin" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=${XRAY_BIN} run -confdir /etc/xray
EOF
    sudo systemctl daemon-reload || true
    log "已创建 systemd drop-in: $dropin"
  elif [ "$init" = "openrc" ] && [ -f /etc/init.d/xray ]; then
    sudo sed -i 's|--config[^ ]*|--confdir /etc/xray|g' /etc/init.d/xray 2>/dev/null || true
    log "尝试修改 OpenRC 启动脚本为 --confdir /etc/xray（请手动确认）"
  else
    warn "无法自动切换 init 系统，请手动修改服务启动参数为: ${XRAY_BIN} run -confdir /etc/xray"
  fi
}

# -----------------------
# 安装/更新 Xray（并切换 confdir）
# -----------------------
install_xray(){
  install_dependencies true
  log "安装/更新 Xray..."
  # 使用官方安装脚本（容错）
  if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root 2>/dev/null; then
    warn "调用官方安装脚本失败，尝试备用地址"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root || true
  fi
  if command -v xray >/dev/null 2>&1; then
    log "Xray 安装成功，切换 confdir 模式"
    switch_to_confdir_mode
    restart_xray || true
  else
    error "Xray 安装失败"
  fi
}

# -----------------------
# Xray 服务控制
# -----------------------
start_xray(){ if sudo systemctl start xray 2>/dev/null || sudo rc-service xray start 2>/dev/null; then log "Xray 已启动"; else warn "启动失败"; fi }
stop_xray(){ if sudo systemctl stop xray 2>/dev/null || sudo rc-service xray stop 2>/dev/null; then log "Xray 已停止"; else warn "停止失败"; fi }
restart_xray(){ if sudo systemctl restart xray 2>/dev/null || sudo rc-service xray restart 2>/dev/null; then log "Xray 已重启"; else warn "重启失败"; fi }
status_xray(){ if ! sudo systemctl status xray --no-pager 2>/dev/null; then sudo rc-service xray status 2>/dev/null || warn "状态查看失败"; fi }
logs_xray(){ if [ -f "$LOG_FILE" ]; then sudo tail -n 200 "$LOG_FILE"; else sudo journalctl -u xray -n 200 --no-pager 2>/dev/null || warn "日志不可用"; fi }

# -----------------------
# 子脚本安装/更新/删除
# -----------------------
install_children(){
  ensure_dirs
  log "安装/更新子脚本到 ${LOCAL_SCRIPT_DIR}"
  mkdir -p /tmp/proxym-download
  for raw in "$REALITY_RAW" "$X25519_RAW" "$MLKEM_RAW"; do
    name=$(basename "$raw")
    url=$(get_raw_url "$name")
    tmp="/tmp/proxym-download/${name}.new"
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
  rm -rf /tmp/proxym-download
  log "子脚本安装/更新完成。"
}
remove_children(){ sudo rm -rf "$LOCAL_SCRIPT_DIR" && log "已删除子脚本目录 ${LOCAL_SCRIPT_DIR}"; }

# -----------------------
# 写入主配置（config.json）与 dns.json
# -----------------------
write_main_config(){
  sudo mkdir -p "$XRAY_DIR"
  sudo tee "$CONFIG_FILE" >/dev/null <<'EOF'
{
  "log": { "loglevel": "warning" },
  "outbounds": [
    { "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4v6" }, "tag": "direct" }
  ]
}
EOF
  sudo cp -f "$CONFIG_FILE" "${XRAY_DIR}/99-config.json" 2>/dev/null || true
  log "已写入 ${CONFIG_FILE} 并同步到 99-config.json"
}
write_dns_config(){
  sudo mkdir -p "$XRAY_DIR"
  read -r -p "主 DNS (默认 1.1.1.1): " dns1
  dns1=${dns1:-1.1.1.1}
  read -r -p "备 DNS (默认 8.8.8.8): " dns2
  dns2=${dns2:-8.8.8.8}
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
  sudo cp -f "$DNS_FILE" "${XRAY_DIR}/20-dns.json" 2>/dev/null || true
  log "已写入 ${DNS_FILE} 并同步到 20-dns.json"
}

# -----------------------
# 列出 /etc/xray 下已用的数字前缀（避免重复）
# -----------------------
list_used_numbers(){
  ensure_dirs
  # 列出以数字开头的文件名的数字前缀（两位或多位）
  find "$XRAY_DIR" -maxdepth 1 -type f -name '[0-9]*' -printf '%f\n' 2>/dev/null | sed -n 's/^\([0-9]\+\).*/\1/p' | sort -u
}

# -----------------------
# 打印 URI 列表（/etc/proxym-easy/uri.json）
# -----------------------
print_uri_list(){
  ensure_dirs
  if [ -s "$URI_JSON" ]; then
    jq -r '.[] | "\(.name) -> \(.uri)"' "$URI_JSON" 2>/dev/null || echo "(uri.json 格式异常或为空)"
  else
    echo "(无 URI)"
  fi
}

# -----------------------
# 卸载（脚本 / Xray）
# -----------------------
uninstall_all_scripts_only(){
  ensure_dirs
  echo "将删除：主脚本（${PROXYM_EASY_PATH}）、子脚本（${LOCAL_SCRIPT_DIR}）、/etc/proxym 与 /etc/proxym-easy（保留 Xray）"
  read -r -p "确认？(y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    sudo rm -f "${PROXYM_EASY_PATH}" || true
    sudo rm -rf "${LOCAL_SCRIPT_DIR}" || true
    sudo rm -rf /etc/proxym /etc/proxym-easy || true
    log "已删除脚本与 proxym 数据（Xray 保留）"
  else
    log "取消"
  fi
}
uninstall_everything_including_xray(){
  echo "彻底卸载 Xray 与所有配置（不可逆）"
  read -r -p "确认？(y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    stop_xray || true
    sudo systemctl disable xray 2>/dev/null || true
    # 尝试官方卸载（容错）
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null || true
    sudo rm -f "${PROXYM_EASY_PATH}" || true
    sudo rm -rf "${LOCAL_SCRIPT_DIR}" /etc/proxym /etc/proxym-easy /etc/xray /var/log/xray /usr/local/bin/xray /usr/bin/xray || true
    log "彻底卸载完成"
  else
    log "取消"
  fi
}

# -----------------------
# 菜单
# -----------------------
main_menu(){
  ensure_dirs
  load_mirror
  while true; do
    clear
    cat <<'MENU'
===========================================
       Proxym‑Easy VLESS 管理器
===========================================
[1] 安装/更新 Xray
[2] 生成 config.json & dns.json
[3] 安装/更新 子脚本
[4] 添加节点（调用子脚本）
[5] 列出已用数字前缀
[6] 打印 URI 列表
[7] 启动 Xray
[8] 停止 Xray
[9] 重启 Xray
[10] 查看状态
[11] 查看日志
[12] 删除 子脚本
[13] 卸载
[0] 退出
MENU
    read -r -p "选择: " opt
    case "$opt" in
      1) install_xray ;;
      2) write_dns_config; write_main_config ;;
      3) install_children ;;
      4)
         echo "[1] Reality  [2] x25519  [3] mlkem"
         read -r -p "选择: " c
         case "$c" in
           1) sudo "${LOCAL_SCRIPT_DIR}/vless-reality.sh" || warn "调用失败" ;;
           2) sudo "${LOCAL_SCRIPT_DIR}/vless-x25519.sh" || warn "调用失败" ;;
           3) sudo "${LOCAL_SCRIPT_DIR}/vless-mlkem.sh" || warn "调用失败" ;;
           *) warn "无效" ;;
         esac
         ;;
      5) list_used_numbers ;;
      6) print_uri_list ;;
      7) start_xray ;;
      8) stop_xray ;;
      9) restart_xray ;;
      10) status_xray ;;
      11) logs_xray ;;
      12) remove_children ;;
      13)
         echo "[1] 卸载脚本（保留 Xray）"
         echo "[2] 彻底卸载（包括 Xray）"
         read -r -p "选择: " u
         case "$u" in
           1) uninstall_all_scripts_only ;;
           2) uninstall_everything_including_xray ;;
           *) warn "无效" ;;
         esac
         ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
    read -r -p "按 Enter 返回..." || true
  done
}

# -----------------------
# CLI 支持
# -----------------------
if [ "$#" -gt 0 ]; then
  case "$1" in
    install-xray) install_xray ;;
    install-children) install_children ;;
    remove-children) remove_children ;;
    list-numbers) list_used_numbers ;;
    print-uris) print_uri_list ;;
    *) warn "未知命令" ;;
  esac
  exit 0
fi

ensure_dirs
main_menu