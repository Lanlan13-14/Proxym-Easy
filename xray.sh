#!/bin/bash
# Xray 极简管理脚本 (最终版)
# 版本: 3.0

# ========== 颜色定义 ==========
red='\e[31m'; yellow='\e[33m'; green='\e[92m'; blue='\e[94m'; cyan='\e[96m'; none='\e[0m'
_red() { echo -e "${red}$*${none}"; }
_green() { echo -e "${green}$*${none}"; }
_yellow() { echo -e "${yellow}$*${none}"; }
_blue() { echo -e "${blue}$*${none}"; }
_cyan() { echo -e "${cyan}$*${none}"; }

# ========== 基础变量 ==========
is_core="xray"
is_core_dir="/etc/$is_core"
is_core_bin="$is_core_dir/bin/$is_core"
is_core_repo="XTLS/$is_core-core"
is_conf_dir="/etc/$is_core/conf.d"
is_log_dir="/var/log/$is_core"
is_config_json="/etc/$is_core/config.json"
is_sh_bin="/usr/local/bin/proxym-easy"
SCRIPT_URL="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/xray.sh"

# GitHub 脚本基础 URL
SCRIPT_BASE_URL="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/script"

# ========== 工具函数 ==========
err() { _red "\n错误: $*\n" && exit 1; }
_wget() { wget --no-check-certificate -q --show-progress "$@"; }
check_root() { [[ $EUID != 0 ]] && err "请使用 root 用户执行"; }

get_arch() {
    case $(uname -m) in
        amd64 | x86_64) echo "64" ;;
        *aarch64* | *armv8*) echo "arm64-v8a" ;;
        *) err "仅支持 64 位系统 (amd64 或 arm64)" ;;
    esac
}

# ========== 安装依赖 ==========
install_deps() {
    local cmd
    cmd=$(type -P apt-get || type -P yum)
    [[ ! $cmd ]] && err "仅支持 apt-get 或 yum 包管理器"
    
    local pkgs="wget unzip curl"
    local to_install=""
    local pkg
    
    for pkg in $pkgs; do
        if [[ ! $(type -P "$pkg") ]]; then
            to_install="$to_install $pkg"
        fi
    done

    if [[ -n $to_install ]]; then
        _yellow "安装依赖: $to_install"
        $cmd update -y &>/dev/null
        $cmd install -y $to_install &>/dev/null || err "依赖安装失败"
    fi
}

# ========== 安装 jq ==========
install_jq() {
    if [[ ! $(type -P jq) ]]; then
        _yellow "安装 jq..."
        local arch
        arch=$(uname -m)
        local jq_arch="amd64"
        [[ $arch == *aarch64* || $arch == *armv8* ]] && jq_arch="arm64"
        _wget "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$jq_arch" -O /usr/bin/jq
        chmod +x /usr/bin/jq
    fi
}

# ========== 下载 Xray ==========
download_xray() {
    local version="$1"
    local arch
    arch=$(get_arch)
    local url="https://github.com/${is_core_repo}/releases/latest/download/${is_core}-linux-${arch}.zip"
    [[ -n $version ]] && url="https://github.com/${is_core_repo}/releases/download/${version}/${is_core}-linux-${arch}.zip"
    
    local tmpdir
    tmpdir=$(mktemp -d)
    _yellow "下载 Xray: ${url}"
    _wget "$url" -O "$tmpdir/xray.zip" || { rm -rf "$tmpdir"; err "下载失败"; }
    
    unzip -qo "$tmpdir/xray.zip" -d "$tmpdir" || { rm -rf "$tmpdir"; err "解压失败"; }
    
    mkdir -p "$is_core_dir/bin"
    cp -rf "$tmpdir"/* "$is_core_dir/bin/" 2>/dev/null
    chmod +x "$is_core_bin"
    rm -rf "$tmpdir"
    _green "Xray 核心安装成功"
}

# ========== 生成基础配置 ==========
gen_base_config() {
    mkdir -p "$is_conf_dir"
    
    # 01-dns.json
    cat > "$is_conf_dir/01-dns.json" <<EOF
{
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8"
    ],
    "queryStrategy": "UseIPv4"
  }
}
EOF
    
    # 02-base.json
    cat > "$is_conf_dir/02-base.json" <<EOF
{
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

    # 生成主配置
    cat > "$is_config_json" <<EOF
{
  "log": {
    "access": "$is_log_dir/access.log",
    "error": "$is_log_dir/error.log",
    "loglevel": "warning"
  },
  "inbounds": [],
  "dns": null,
  "outbounds": null,
  "routing": null
}
EOF
    _green "基础配置文件已生成"
}

# ========== 创建 systemd 服务 ==========
create_service() {
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$is_core_bin run -confdir $is_conf_dir
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    _green "Systemd 服务创建成功"
}

# ========== 安装主函数 ==========
install_xray() {
    [[ -f $is_core_bin ]] && _yellow "Xray 已安装，正在重新安装..." && systemctl stop xray
    
    _green "开始安装 Xray..."
    install_deps
    install_jq
    download_xray "$1"
    mkdir -p "$is_log_dir" "$is_conf_dir"
    gen_base_config
    create_service
    systemctl enable xray &>/dev/null
    systemctl start xray
    _green "Xray 安装完成！"
    _green "状态: $(systemctl is-active xray)"
}

# ========== 更新 Xray ==========
update_xray() {
    [[ ! -f $is_core_bin ]] && err "Xray 未安装"
    _yellow "正在更新 Xray..."
    systemctl stop xray
    
    local old_version
    old_version=$($is_core_bin version | head -n1)
    
    # 安全删除
    rm -rf "${is_core_dir:?}/bin/"*
    
    download_xray
    systemctl start xray
    
    local new_version
    new_version=$($is_core_bin version | head -n1)
    _green "更新完成: $old_version -> $new_version"
}

# ========== 更新脚本自身 ==========
update_script() {
    _yellow "正在检查脚本更新..."
    
    local tmp_script="/tmp/proxym-easy.tmp"
    
    # 下载新脚本
    if ! _wget "$SCRIPT_URL" -O "$tmp_script"; then
        _red "下载新脚本失败"
        rm -f "$tmp_script"
        return 1
    fi
    
    # 验证语法
    _yellow "验证脚本语法..."
    if ! bash -n "$tmp_script"; then
        _red "新脚本语法错误，取消更新"
        rm -f "$tmp_script"
        return 1
    fi
    
    # 备份当前脚本
    local backup_script="/tmp/proxym-easy.backup.$(date +%Y%m%d%H%M%S)"
    cp "$is_sh_bin" "$backup_script"
    _yellow "已备份当前脚本到: $backup_script"
    
    # 替换脚本
    cp "$tmp_script" "$is_sh_bin"
    chmod +x "$is_sh_bin"
    rm -f "$tmp_script"
    
    _green "脚本更新成功！"
    _green "将在3秒后重新启动新版本..."
    sleep 3
    exec "$is_sh_bin"  # 用新脚本替换当前进程
}

# ========== 卸载菜单 ==========
uninstall_menu() {
    while true; do
        clear
        echo "========== 卸载选项 =========="
        echo "[1] 仅删除本脚本 (保留 Xray)"
        echo "[2] 仅删除 Xray (保留本脚本)"
        echo "[3] 全部删除 (Xray + 本脚本)"
        echo "[4] 返回主菜单"
        echo "================================"
        echo
        read -r -p "请选择 [1-4]: " uninstall_choice
        
        case $uninstall_choice in
            1)
                _yellow "正在删除本脚本..."
                rm -f "$is_sh_bin"
                _green "脚本已删除，Xray 服务保留"
                _green "退出..."
                exit 0
                ;;
            2)
                if [[ ! -f $is_core_bin ]]; then
                    _red "Xray 未安装"
                else
                    read -r -p "确定仅删除 Xray？[y/N]: " confirm
                    if [[ $confirm == [yY] ]]; then
                        _yellow "正在卸载 Xray..."
                        systemctl stop xray 2>/dev/null
                        systemctl disable xray 2>/dev/null
                        rm -rf /etc/systemd/system/xray.service
                        systemctl daemon-reload
                        rm -rf "$is_core_dir"
                        rm -rf "$is_log_dir"
                        _green "Xray 卸载完成，本脚本已保留"
                    fi
                fi
                read -r -p "按回车键继续..."
                ;;
            3)
                read -r -p "确定卸载 Xray 并删除本脚本？[y/N]: " confirm
                if [[ $confirm == [yY] ]]; then
                    _yellow "正在卸载 Xray..."
                    systemctl stop xray 2>/dev/null
                    systemctl disable xray 2>/dev/null
                    rm -rf /etc/systemd/system/xray.service
                    systemctl daemon-reload
                    rm -rf "$is_core_dir"
                    rm -rf "$is_log_dir"
                    _green "Xray 卸载完成"
                    
                    _yellow "正在删除本脚本..."
                    rm -f "$is_sh_bin"
                    _green "脚本已删除"
                    _green "退出..."
                    exit 0
                fi
                read -r -p "按回车键继续..."
                ;;
            4)
                break
                ;;
            *)
                _red "无效选择"
                sleep 1
                ;;
        esac
    done
}

# ========== 修改 DNS 配置 ==========
modify_dns() {
    [[ ! -f $is_conf_dir/01-dns.json ]] && err "DNS 配置文件不存在，请先安装 Xray"
    
    _blue "当前 DNS 配置:"
    cat "$is_conf_dir/01-dns.json" | jq '.'
    echo
    
    local dns1 dns2 strategy
    
    read -r -p "请输入首选 DNS (默认: 1.1.1.1): " dns1
    read -r -p "请输入备选 DNS (默认: 8.8.8.8): " dns2
    
    echo
    echo "请选择 DNS 查询策略:"
    echo "[1] UseIPv4 - 强制只返回 IPv4 地址"
    echo "[2] UseIPv6 - 强制只返回 IPv6 地址"
    echo "[3] UseIP - 返回所有 IP (默认策略)"
    echo "[4] IPIfNonMatch - 优先匹配，找不到再用其他类型"
    echo
    read -r -p "请选择 [1-4] (默认: 1): " strategy
    
    dns1=${dns1:-1.1.1.1}
    dns2=${dns2:-8.8.8.8}
    
    case $strategy in
        2) strategy="UseIPv6" ;;
        3) strategy="UseIP" ;;
        4) strategy="IPIfNonMatch" ;;
        *) strategy="UseIPv4" ;;
    esac
    
    cat > "$is_conf_dir/01-dns.json" <<EOF
{
  "dns": {
    "servers": [
      "$dns1",
      "$dns2"
    ],
    "queryStrategy": "$strategy"
  }
}
EOF
    _green "DNS 配置已更新"
    _green "当前策略: $strategy"
    systemctl restart xray
    _green "Xray 已重启"
}

# ========== 服务控制 ==========
control_service() {
    local action=$1
    local action_cn
    case $action in
        start) action_cn="启动" ;;
        stop) action_cn="停止" ;;
        restart) action_cn="重启" ;;
        *) return ;;
    esac
    
    if [[ ! -f $is_core_bin ]]; then
        _red "Xray 未安装，无法执行此操作"
        return
    fi
    
    _yellow "正在${action_cn} Xray 服务..."
    systemctl $action xray
    sleep 2
    _green "当前状态: $(systemctl is-active xray)"
}

# ========== 查看日志 ==========
view_logs() {
    if [[ ! -f $is_core_bin ]]; then
        _red "Xray 未安装，无法查看日志"
        return
    fi
    
    echo -e "\n${cyan}══════ Xray 最新 50 条日志 ══════${none}"
    journalctl -u xray -n 50 --no-pager -q
    echo -e "${cyan}══════════════════════════════════${none}\n"
}

# ========== 查看状态详情 ==========
view_status() {
    if [[ ! -f $is_core_bin ]]; then
        _red "Xray 未安装，无法查看状态"
        return
    fi
    systemctl status xray --no-pager
}

# ========== 显示当前状态 ==========
show_status() {
    echo -e "\n${cyan}══════════ Xray 状态 ══════════${none}"
    if [[ -f $is_core_bin ]]; then
        _green "● 安装状态: 已安装"
        _green "● 运行状态: $(systemctl is-active xray)"
        _green "● 启用状态: $(systemctl is-enabled xray 2>/dev/null || echo '未启用')"
        _green "● 核心版本: $($is_core_bin version 2>/dev/null | head -n1)"
    else
        _yellow "○ 安装状态: 未安装"
    fi
    echo -e "${cyan}═══════════════════════════════${none}\n"
}

# ========== 入站管理菜单 ==========
inbound_menu() {
    while true; do
        clear
        echo "========== 入站管理 =========="
        echo "[1] SS2022"
        echo "[2] Vless-Reality"
        echo "[3] Vless-ENC"
        echo "[4] 返回主菜单"
        echo "================================"
        echo
        read -r -p "请选择 [1-4]: " inbound_choice  
        
        case $inbound_choice in
            1)
                _yellow "正在获取 SS2022 安装脚本..."
                bash <(curl -sL "${SCRIPT_BASE_URL}/ss2022.sh") || _red "脚本执行失败"
                read -r -p "按回车键继续..."
                ;;
            2)
                _yellow "正在获取 Vless-Reality 安装脚本..."
                bash <(curl -sL "${SCRIPT_BASE_URL}/vless_reality.sh") || _red "脚本执行失败"
                read -r -p "按回车键继续..."
                ;;
            3)
                _yellow "正在获取 Vless-ENC 安装脚本..."
                bash <(curl -sL "${SCRIPT_BASE_URL}/vless_encryption.sh") || _red "脚本执行失败"
                read -r -p "按回车键继续..."
                ;;
            4)
                break
                ;;
            *)
                _red "无效选择"
                sleep 1
                ;;
        esac
    done
}

# ========== 主菜单 ==========
show_menu() {
    clear
    echo "========== Xray 极简管理菜单 =========="
    show_status
    echo "[1] 安装 Xray"
    echo "[2] 更新 Xray"
    echo "[3] 卸载 Xray"
    echo "[4] 修改 DNS 配置"
    echo "[5] 入站管理"
    echo "[6] 启动 Xray"
    echo "[7] 停止 Xray"
    echo "[8] 重启 Xray"
    echo "[9] 查看最近 50 条日志"
    echo "[10] 查看 systemctl status"
    echo "[11] 更新本脚本"
    echo "[12] 退出"
    echo "========================================"
    echo
}

# ========== 主程序 ==========
main() {
    check_root
    
    while true; do
        show_menu
        local choice
        read -r -p "请选择 [1-12]: " choice
        case $choice in
            1) 
                local ver
                read -r -p "请输入版本号 (直接回车安装最新版): " ver
                [[ -n $ver ]] && ver="v${ver#v}"
                install_xray "$ver"
                read -r -p "按回车键继续..."
                ;;
            2) 
                update_xray
                read -r -p "按回车键继续..."
                ;;
            3) 
                uninstall_menu
                ;;
            4) 
                modify_dns
                read -r -p "按回车键继续..."
                ;;
            5) inbound_menu ;;
            6) control_service start; read -r -p "按回车键继续..." ;;
            7) control_service stop; read -r -p "按回车键继续..." ;;
            8) control_service restart; read -r -p "按回车键继续..." ;;
            9) view_logs; read -r -p "按回车键继续..." ;;
            10) view_status; read -r -p "按回车键继续..." ;;
            11) 
                update_script
                ;;
            12) 
                _green "退出，下次使用请输入: proxym-easy"
                exit 0
                ;;
            *) _red "无效选择"; sleep 1 ;;
        esac
    done
}

main "$@"