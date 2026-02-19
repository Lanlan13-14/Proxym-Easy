#!/bin/bash
# Xray 极简安装管理脚本
# 版本: 1.0

# ========== 颜色定义 ==========
red='\e[31m'; yellow='\e[33m'; green='\e[92m'; blue='\e[94m'; none='\e[0m'
_red() { echo -e ${red}$@${none}; }
_green() { echo -e ${green}$@${none}; }
_yellow() { echo -e ${yellow}$@${none}; }
_blue() { echo -e ${blue}$@${none}; }

# ========== 基础变量 ==========
is_core="xray"
is_core_name="Xray"
is_core_dir="/etc/$is_core"
is_core_bin="$is_core_dir/bin/$is_core"
is_core_repo="XTLS/$is_core-core"
is_conf_dir="/etc/$is_core/conf.d"
is_log_dir="/var/log/$is_core"
is_config_json="/etc/$is_core/config.json"
is_sh_bin="/usr/local/bin/proxym-easy"

# ========== 工具函数 ==========
err() { _red "\n错误: $@\n" && exit 1; }

_wget() { wget --no-check-certificate -q --show-progress $*; }

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
    local cmd=$(type -P apt-get || type -P yum)
    [[ ! $cmd ]] && err "仅支持 apt-get 或 yum 包管理器"
    
    local pkgs="wget unzip curl"
    local to_install=""
    for pkg in $pkgs; do
        [[ ! $(type -P $pkg) ]] && to_install="$to_install $pkg"
    done

    if [[ $to_install ]]; then
        _yellow "安装依赖: $to_install"
        $cmd update -y &>/dev/null
        $cmd install -y $to_install &>/dev/null || err "依赖安装失败"
    fi
}

# ========== 安装 jq ==========
install_jq() {
    if [[ ! $(type -P jq) ]]; then
        _yellow "安装 jq..."
        local arch=$(uname -m)
        local jq_arch="amd64"
        [[ $arch == *aarch64* || $arch == *armv8* ]] && jq_arch="arm64"
        _wget "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$jq_arch" -O /usr/bin/jq
        chmod +x /usr/bin/jq
    fi
}

# ========== 下载 Xray ==========
download_xray() {
    local version=$1
    local arch=$(get_arch)
    local url="https://github.com/${is_core_repo}/releases/latest/download/${is_core}-linux-${arch}.zip"
    [[ $version ]] && url="https://github.com/${is_core_repo}/releases/download/${version}/${is_core}-linux-${arch}.zip"
    
    local tmpdir=$(mktemp -d)
    _yellow "下载 Xray: ${url}"
    _wget $url -O $tmpdir/xray.zip || { rm -rf $tmpdir; err "下载失败"; }
    
    unzip -qo $tmpdir/xray.zip -d $tmpdir || { rm -rf $tmpdir; err "解压失败"; }
    
    mkdir -p $is_core_dir/bin
    cp -rf $tmpdir/* $is_core_dir/bin/ 2>/dev/null
    chmod +x $is_core_bin
    rm -rf $tmpdir
    _green "Xray 核心安装成功"
}

# ========== 生成基础配置 ==========
gen_base_config() {
    mkdir -p $is_conf_dir
    
    # 01-dns.json
    cat > $is_conf_dir/01-dns.json <<EOF
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
    cat > $is_conf_dir/02-base.json <<EOF
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
    cat > $is_config_json <<EOF
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
    download_xray $1
    mkdir -p $is_log_dir $is_conf_dir
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
    local old_version=$($is_core_bin version | head -n1)
    rm -rf $is_core_dir/bin/*
    download_xray
    systemctl start xray
    local new_version=$($is_core_bin version | head -n1)
    _green "更新完成: $old_version -> $new_version"
}

# ========== 卸载 Xray ==========
uninstall_xray() {
    [[ ! -f $is_core_bin ]] && err "Xray 未安装"
    _yellow "正在卸载 Xray..."
    systemctl stop xray
    systemctl disable xray &>/dev/null
    rm -rf /etc/systemd/system/xray.service
    systemctl daemon-reload
    rm -rf $is_core_dir
    rm -rf $is_log_dir
    rm -f $is_sh_bin
    _green "Xray 卸载完成"
}

# ========== 修改 DNS 配置 ==========
modify_dns() {
    [[ ! -f $is_conf_dir/01-dns.json ]] && err "DNS 配置文件不存在，请先安装 Xray"
    
    _blue "当前 DNS 配置:"
    cat $is_conf_dir/01-dns.json | jq '.'
    echo
    
    read -p "请输入首选 DNS (默认: 1.1.1.1): " dns1
    read -p "请输入备选 DNS (默认: 8.8.8.8): " dns2
    echo "请选择查询策略:"
    echo "1) UseIPv4 (仅 IPv4)"
    echo "2) UseIPv6 (仅 IPv6)"
    echo "3) UseBoth (同时使用)"
    read -p "请选择 [1-3] (默认: 1): " strategy
    
    dns1=${dns1:-1.1.1.1}
    dns2=${dns2:-8.8.8.8}
    case $strategy in
        2) strategy="UseIPv6" ;;
        3) strategy="UseBoth" ;;
        *) strategy="UseIPv4" ;;
    esac
    
    cat > $is_conf_dir/01-dns.json <<EOF
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
    systemctl restart xray
    _green "Xray 已重启"
}

# ========== 主菜单 ==========
show_menu() {
    clear
    echo "========== Xray 极简管理菜单 =========="
    echo "1. 安装 Xray"
    echo "2. 更新 Xray"
    echo "3. 卸载 Xray"
    echo "4. 修改 DNS 配置"
    echo "5. 入站管理 (待实现)"
    echo "6. 退出"
    echo "========================================"
    echo "提示: 下次使用请输入: proxym-easy"
    echo
}

# ========== 主程序 ==========
main() {
    check_root
    
    # 创建软链接
    if [[ ! -f $is_sh_bin ]]; then
        ln -sf $(realpath $0) $is_sh_bin
    fi
    
    while true; do
        show_menu
        read -p "请选择 [1-6]: " choice
        case $choice in
            1) 
                read -p "请输入版本号 (直接回车安装最新版): " ver
                [[ $ver ]] && ver="v${ver#v}"
                install_xray $ver
                ;;
            2) update_xray ;;
            3) 
                read -p "确定卸载 Xray？[y/N]: " confirm
                [[ $confirm == [yY] ]] && uninstall_xray
                ;;
            4) modify_dns ;;
            5) _yellow "入站管理功能待实现，请稍后..." ;;
            6) 
                _green "退出，下次使用请输入: proxym-easy"
                exit 0
                ;;
            *) _red "无效选择" ;;
        esac
        echo
        read -p "按回车键继续..."
    done
}

main $@