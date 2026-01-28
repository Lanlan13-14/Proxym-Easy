#!/usr/bin/env bash
# vless-manager.sh - 主控脚本（完整）
# 功能：
#  - 管理 Xray（安装/启动/停止/重启/状态/日志/更新）
#  - 生成新配置（在此选项询问 DNS，已有时询问是否修改）
#  - 安装/更新/卸载 子脚本（vless-reality.sh / vless-x25519.sh / vless-mlkem.sh）
#  - 管理 inbounds 文件（协议_端口.json），维护 /etc/proxym/vless.json 与 /etc/proxym/uris_tokens.json
#  - 批量/单个上传到 worker（通过 URIS_TOKENS 中配置的 endpoint/token）
#  - Cron 管理（重启 Xray；重置 UUID/密码）
#  - 打印 VLESS URI、编辑/测试配置、管理推送设置
#
# 说明：
#  - 运行本脚本需要 sudo 权限（写 /etc、重启服务等）
#  - 子脚本来源（raw GitHub）: https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/script
#  - 子脚本职责：仅生成对应类型入站文件并写入 /etc/proxym/vless.json；不做上传/删除已上传等操作
#
# 安装：保存为 /usr/local/bin/vless-manager.sh 并 chmod +x
# 运行：sudo /usr/local/bin/vless-manager.sh
#
set -euo pipefail
export LC_ALL=C.UTF-8

# -----------------------
# 配置路径与常量
# -----------------------
LOCAL_SCRIPT_DIR="/usr/local/bin/proxym-scripts"
SCRIPTS_REPO_BASE="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/script"
VLESS_JSON="/etc/proxym/vless.json"
INBOUNDS_DIR="/etc/xray/inbounds.d"
XDIR="/etc/xray"
DNS_FILE="${XDIR}/dns.json"
BASE_CONFIG="${XDIR}/base_config.json"
URIS_TOKENS="/etc/proxym/uris_tokens.json"
LOG_FILE="/var/log/xray/access.log"   # 可根据系统调整
XRAY_SERVICE_NAME="xray"

# -----------------------
# 颜色与日志
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
  if [ ! -f "$VLESS_JSON" ]; then echo "[]" | sudo tee "$VLESS_JSON" >/dev/null; fi
  if [ ! -f "$URIS_TOKENS" ]; then echo "{}" | sudo tee "$URIS_TOKENS" >/dev/null; fi
  sudo mkdir -p "$(dirname "$DNS_FILE")"
}

# -----------------------
# 子脚本安装/更新/删除
# -----------------------
install_children(){
  ensure_dirs
  info "从 GitHub 拉取子脚本到 ${LOCAL_SCRIPT_DIR}"
  files=(vless-reality.sh vless-x25519.sh vless-mlkem.sh)
  for f in "${files[@]}"; do
    url="${SCRIPTS_REPO_BASE}/${f}"
    info "下载 ${f}"
    if curl -fsSL "$url" -o "${LOCAL_SCRIPT_DIR}/${f}"; then
      sudo chmod +x "${LOCAL_SCRIPT_DIR}/${f}"
      info "已安装 ${f}"
    else
      warn "下载 ${f} 失败: $url"
    fi
  done
  info "子脚本安装完成。"
}

update_children(){
  ensure_dirs
  info "更新子脚本（从 GitHub）"
  install_children
}

remove_children(){
  ensure_dirs
  sudo rm -rf "$LOCAL_SCRIPT_DIR"
  info "已删除子脚本目录 ${LOCAL_SCRIPT_DIR}"
}

# -----------------------
# Xray 管理（安装/启动/停止/重启/状态/日志/更新）
# -----------------------
install_xray(){
  info "安装 Xray（按系统包管理器）"
  if command -v apt >/dev/null 2>&1; then
    sudo apt update
    sudo apt install -y xray || warn "apt 安装 xray 失败，请手动安装"
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y xray || warn "yum 安装 xray 失败，请手动安装"
  else
    warn "未识别包管理器，请手动安装 Xray"
  fi
  info "安装完成（若包管理器支持）。"
  # ensure systemd service exists or instruct user
  if systemctl list-units --type=service | grep -q "${XRAY_SERVICE_NAME}"; then
    info "检测到 systemd 服务 ${XRAY_SERVICE_NAME}"
  else
    warn "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}，请根据 Xray 官方文档创建服务或使用 xray run -confdir ${XDIR}"
  fi
}

start_xray(){
  if systemctl list-units --type=service | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl start "${XRAY_SERVICE_NAME}" && info "Xray 已启动（systemd）" || warn "启动 Xray 失败"
  else
    info "使用 xray run -confdir ${XDIR} 启动（前台）"
    info "建议使用 systemd 服务以便后台运行"
  fi
}

stop_xray(){
  if systemctl list-units --type=service | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl stop "${XRAY_SERVICE_NAME}" && info "Xray 已停止" || warn "停止 Xray 失败"
  else
    warn "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}，请手动停止运行的 xray 进程"
  fi
}

restart_xray(){
  if systemctl list-units --type=service | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl restart "${XRAY_SERVICE_NAME}" && info "Xray 已重启" || warn "重启 Xray 失败"
  else
    warn "未检测到 systemd 服务 ${XRAY_SERVICE_NAME}，请手动重启 xray"
  fi
}

status_xray(){
  if systemctl list-units --type=service | grep -q "^${XRAY_SERVICE_NAME}"; then
    sudo systemctl status "${XRAY_SERVICE_NAME}" --no-pager
  else
    ps aux | grep -E 'xray' | grep -v grep || echo "未检测到 xray 进程"
  fi
}

logs_xray(){
  if [ -f "$LOG_FILE" ]; then
    sudo tail -n 200 "$LOG_FILE"
  else
    if systemctl list-units --type=service | grep -q "^${XRAY_SERVICE_NAME}"; then
      sudo journalctl -u "${XRAY_SERVICE_NAME}" -n 200 --no-pager
    else
      warn "未找到日志文件 ${LOG_FILE}，也未检测到 systemd 服务"
    fi
  fi
}

update_xray(){
  info "更新 Xray（尝试使用官方安装脚本）"
  if command -v curl >/dev/null 2>&1; then
    sudo bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" || warn "更新脚本执行失败"
  else
    warn "缺少 curl，无法自动更新"
  fi
}

# -----------------------
# Cron 管理（重启 Xray / 重置 UUID/密码）
# -----------------------
set_cron_restart(){
  read -p "输入 cron 表达式（例如 0 4 * * * 表示每天 04:00）: " expr
  (crontab -l 2>/dev/null | grep -v '#vless-manager-restart' ; echo "${expr} systemctl restart ${XRAY_SERVICE_NAME} #vless-manager-restart") | crontab -
  info "已设置 Cron 重启"
}

list_cron_restart(){
  crontab -l 2>/dev/null | nl -ba | sed -n '/vless-manager-restart/,$p' || echo "(无重启 Cron)"
}

delete_cron_restart(){
  (crontab -l 2>/dev/null | grep -v '#vless-manager-restart') | crontab -
  info "已删除重启相关 Cron 条目"
}

set_cron_reset(){
  read -p "输入 cron 表达式（例如 0 3 * * 0 表示每周日 03:00）: " expr
  # 假设存在 /usr/local/bin/vless-reset-nodes.sh 或子脚本支持 reset
  (crontab -l 2>/dev/null | grep -v '#vless-manager-reset' ; echo "${expr} ${LOCAL_SCRIPT_DIR}/vless-reset-nodes.sh reset #vless-manager-reset") | crontab -
  info "已设置 Cron 重置 UUID/密码"
}

list_cron_reset(){
  crontab -l 2>/dev/null | nl -ba | sed -n '/vless-manager-reset/,$p' || echo "(无重置 Cron)"
}

delete_cron_reset(){
  (crontab -l 2>/dev/null | grep -v '#vless-manager-reset') | crontab -
  info "已删除重置相关 Cron 条目"
}

# -----------------------
# 生成新配置（在此选项询问 DNS；若已有 dns.json 则询问是否修改）
# -----------------------
generate_new_config(){
  ensure_dirs
  if [ -f "$DNS_FILE" ]; then
    echo "检测到已存在 DNS 配置："
    cat "$DNS_FILE"
    read -p "是否要修改 DNS 配置? (y/N): " ch
    if [[ ! $ch =~ ^[Yy]$ ]]; then
      info "保留现有 DNS 配置"
      return
    fi
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
  # base config without inbounds
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
  info "已生成基础配置（无入站）: ${BASE_CONFIG}"
  info "DNS 已写入 ${DNS_FILE}"
}

# -----------------------
# 编辑配置（打开 /etc/xray/config.json 或 base_config.json）
# -----------------------
edit_config(){
  ensure_dirs
  # prefer main config if exists
  if [ -f "/usr/local/etc/xray/config.json" ]; then
    cfg="/usr/local/etc/xray/config.json"
  else
    cfg="$BASE_CONFIG"
  fi
  editor="${EDITOR:-vi}"
  sudo $editor "$cfg"
}

# -----------------------
# 测试配置（xray -test -confdir /etc/xray 或 xray -test -c config.json）
# -----------------------
test_config(){
  ensure_dirs
  if command -v xray >/dev/null 2>&1; then
    if [ -d "$XDIR" ]; then
      info "使用 xray 测试 confdir ${XDIR}"
      sudo xray test -confdir "$XDIR" || warn "配置测试失败"
    else
      warn "未找到 ${XDIR}"
    fi
  else
    warn "未安装 xray，无法测试"
  fi
}

# -----------------------
# 打印 VLESS URI（从 /etc/proxym/vless.json）
# -----------------------
print_vless_uris(){
  ensure_dirs
  if [ ! -f "$VLESS_JSON" ]; then
    echo "[]"
    return
  fi
  jq -r '.[] | "\(.tag) \(.domain // .ip):\(.port) \n\(.uri)\n"' "$VLESS_JSON"
}

# -----------------------
# 更新脚本（self update）
# -----------------------
self_update(){
  info "更新主脚本（从 GitHub raw）"
  url="${SCRIPTS_REPO_BASE}/vless-manager.sh"
  if curl -fsSL "$url" -o "/tmp/vless-manager.sh.new"; then
    sudo mv /tmp/vless-manager.sh.new "$(realpath "$0")"
    sudo chmod +x "$(realpath "$0")"
    info "主脚本已更新"
  else
    warn "更新失败"
  fi
}

# -----------------------
# 卸载（删除脚本或脚本+xray）
# -----------------------
uninstall(){
  echo "[1] 仅删除脚本（包括子脚本）"
  echo "[2] 删除脚本并尝试卸载 xray"
  read -p "选择 [1]/[2] (默认 1): " choice
  choice=${choice:-1}
  if [ "$choice" = "1" ]; then
    sudo rm -f "$(realpath "$0")"
    remove_children
    info "已删除主脚本与子脚本"
  else
    sudo rm -f "$(realpath "$0")"
    remove_children
    if command -v apt >/dev/null 2>&1; then
      sudo apt remove -y xray || warn "apt remove xray 失败"
    elif command -v yum >/dev/null 2>&1; then
      sudo yum remove -y xray || warn "yum remove xray 失败"
    else
      warn "未识别包管理器，请手动卸载 xray"
    fi
    info "已删除脚本并尝试卸载 xray"
  fi
}

# -----------------------
# 管理推送设置（uris_tokens.json）
# -----------------------
list_push_settings(){
  ensure_dirs
  jq -r 'to_entries[] | "[\(.key)] uri: \(.value.uri) endpoint: \(.value.upload_endpoint // "") token: \(.value.upload_token // "")"' "$URIS_TOKENS" 2>/dev/null || echo "{}"
}

add_push_setting(){
  ensure_dirs
  read -p "输入协议_端口 (例如 reality_443): " key
  read -p "输入对应 URI: " uri
  read -p "输入 upload endpoint (例如 https://worker.example/upload): " ep
  read -p "输入 upload token (留空无 token): " tok
  tmp=$(mktemp)
  jq --arg k "$key" --arg uri "$uri" --arg ep "$ep" --arg tok "$tok" '. + {($k): {uri:$uri, upload_endpoint:$ep, upload_token:$tok}}' "$URIS_TOKENS" > "$tmp" && sudo mv "$tmp" "$URIS_TOKENS"
  info "已保存映射 [$key]"
}

modify_push_setting(){
  ensure_dirs
  read -p "输入要修改的协议_端口: " key
  if ! jq -e --arg k "$key" '.[$k]' "$URIS_TOKENS" >/dev/null 2>&1; then err "未找到 $key"; return; fi
  cur_uri=$(jq -r --arg k "$key" '.[$k].uri' "$URIS_TOKENS")
  cur_ep=$(jq -r --arg k "$key" '.[$k].upload_endpoint // ""' "$URIS_TOKENS")
  cur_tok=$(jq -r --arg k "$key" '.[$k].upload_token // ""' "$URIS_TOKENS")
  read -p "新的 upload endpoint (留空保持不变) [${cur_ep}]: " ep
  read -p "新的 upload token (留空保持不变) [${cur_tok}]: " tok
  ep=${ep:-$cur_ep}
  tok=${tok:-$cur_tok}
  tmp=$(mktemp)
  jq --arg k "$key" --arg uri "$cur_uri" --arg ep "$ep" --arg tok "$tok" '. + {($k): {uri:$uri, upload_endpoint:$ep, upload_token:$tok}}' "$URIS_TOKENS" > "$tmp" && sudo mv "$tmp" "$URIS_TOKENS"
  info "已更新映射 [$key]"
}

delete_push_setting(){
  ensure_dirs
  read -p "输入要删除的协议_端口: " key
  tmp=$(mktemp)
  jq "del(.\"$key\")" "$URIS_TOKENS" > "$tmp" && sudo mv "$tmp" "$URIS_TOKENS"
  info "已删除映射 [$key]"
}

# -----------------------
# 菜单（按用户要求显示指定项）
# -----------------------
main_menu(){
  ensure_dirs
  while true; do
    cat <<'MENU'

[1] 🔧 安装 Xray
[2] ⚙️ 生成新配置
[3] ▶️ 启动 Xray
[4] ⏹️ 停止 Xray
[5] 🔄 重启 Xray
[6] 📊 查看状态
[7] 📝 查看日志
[8] 🚀 更新 Xray
[9] ⏰ 设置 Cron 重启
[10] 👁️ 查看 Cron 任务 (重启)
[11] 🗑️ 删除 Cron (重启)
[12] 🖨️ 打印 VLESS URI
[13] 🔄 更新脚本
[14] 🗑️ 卸载
[15] 📝 编辑配置
[16] 🧪 测试配置
[17] 🔄 设置 Cron 重置 UUID/密码
[18] 👁️ 查看 Cron 任务 (重置)
[19] 🗑️ 删除 Cron (重置)
[20] 📤 管理推送设置
[21] 📁 子脚本安装/更新/删除
[22] 📂 列出 inbounds 文件
[23] 🔼 上传单个/全部（由推送设置决定）
[24] 🔽 删除已上传单个/全部
[0] 退出

MENU
    read -p "选择 [0-24]: " opt
    case "$opt" in
      1) install_xray ;;
      2) generate_new_config ;;
      3) start_xray ;;
      4) stop_xray ;;
      5) restart_xray ;;
      6) status_xray ;;
      7) logs_xray ;;
      8) update_xray ;;
      9) set_cron_restart ;;
      10) list_cron_restart ;;
      11) delete_cron_restart ;;
      12) print_vless_uris ;;
      13) self_update ;;
      14) uninstall ;;
      15) edit_config ;;
      16) test_config ;;
      17) set_cron_reset ;;
      18) list_cron_reset ;;
      19) delete_cron_reset ;;
      20)
         # push settings submenu
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
             1) list_push_settings ;;
             2) add_push_setting ;;
             3) modify_push_setting ;;
             4) delete_push_setting ;;
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
      0) info "退出"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
    echo
    read -p "按 Enter 返回菜单..." _ || true
  done
}

# -----------------------
# 上传/删除 实现（使用 URIS_TOKENS）
# -----------------------
upload_single_impl(){
  ensure_dirs
  read -p "输入要上传的协议_端口: " key
  uri=$(jq -r --arg k "$key" '.[$k].uri // empty' "$URIS_TOKENS")
  endpoint=$(jq -r --arg k "$key" '.[$k].upload_endpoint // empty' "$URIS_TOKENS")
  token=$(jq -r --arg k "$key" '.[$k].upload_token // empty' "$URIS_TOKENS")
  if [ -z "$uri" ] || [ -z "$endpoint" ]; then err "[$key] 未配置 uri 或 endpoint"; return 1; fi
  info "上传 [$key] -> $endpoint"
  if [ -n "$token" ]; then
    curl -s -X POST "$endpoint" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "{\"uri\":\"$uri\"}" | sed -n '1,200p'
  else
    curl -s -X POST "$endpoint" -H "Content-Type: application/json" -d "{\"uri\":\"$uri\"}" | sed -n '1,200p'
  fi
}

upload_all_impl(){
  ensure_dirs
  keys=$(jq -r 'keys[]' "$URIS_TOKENS")
  for k in $keys; do
    echo "---- [$k] ----"
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
  info "批量上传完成"
}

delete_uploaded_single_impl(){
  ensure_dirs
  read -p "输入要删除已上传的协议_端口: " key
  uri=$(jq -r --arg k "$key" '.[$k].uri // empty' "$URIS_TOKENS")
  endpoint=$(jq -r --arg k "$key" '.[$k].upload_endpoint // empty' "$URIS_TOKENS")
  token=$(jq -r --arg k "$key" '.[$k].upload_token // empty' "$URIS_TOKENS")
  if [ -z "$uri" ] || [ -z "$endpoint" ]; then err "[$key] 未配置 uri 或 endpoint"; return 1; fi
  enc_uri=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$uri" 2>/dev/null || printf '%s' "$uri")
  info "删除已上传 [$key] -> ${endpoint}?uri=${enc_uri}"
  if [ -n "$token" ]; then
    curl -s -X DELETE "${endpoint}?uri=${enc_uri}" -H "Authorization: Bearer $token" | sed -n '1,200p'
  else
    curl -s -X DELETE "${endpoint}?uri=${enc_uri}" | sed -n '1,200p'
  fi
}

delete_all_uploaded_impl(){
  ensure_dirs
  keys=$(jq -r 'keys[]' "$URIS_TOKENS")
  for k in $keys; do
    echo "---- [$k] ----"
    uri=$(jq -r --arg k "$k" '.[$k].uri' "$URIS_TOKENS")
    endpoint=$(jq -r --arg k "$k" '.[$k].upload_endpoint // empty' "$URIS_TOKENS")
    token=$(jq -r --arg k "$k" '.[$k].upload_token // empty' "$URIS_TOKENS")
    if [ -z "$endpoint" ]; then warn "[$k] 未配置 endpoint"; continue; fi
    enc_uri=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$uri" 2>/dev/null || printf '%s' "$uri")
    if [ -n "$token" ]; then
      curl -s -X DELETE "${endpoint}?uri=${enc_uri}" -H "Authorization: Bearer $token" >/dev/null || warn "删除失败 [$k]"
    else
      curl -s -X DELETE "${endpoint}?uri=${enc_uri}" >/dev/null || warn "删除失败 [$k]"
    fi
  done
  info "批量删除已上传完成"
}

# -----------------------
# 启动
# -----------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_menu
fi