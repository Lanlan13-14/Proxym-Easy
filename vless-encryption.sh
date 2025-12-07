#!/bin/bash
# proxym-easy - Xray VLESS Encryption一键脚本
# 版本: 4.3
# 将此脚本放置在 /usr/local/bin/proxym-easy 并使其可执行: sudo chmod +x /usr/local/bin/proxym-easy
# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色
# 表情符号
CHECK="${GREEN}✅${NC}"
ERROR="${RED}❌${NC}"
INFO="${BLUE}ℹ️${NC}"
WARN="${YELLOW}⚠️${NC}"
# 路径
CONFIG="/usr/local/etc/xray/config.json"
VLESS_JSON="/etc/proxym/vless.json"
GLOBAL_JSON="/etc/proxym/global.json"
SCRIPT_PATH="/usr/local/bin/proxym-easy"
UPDATE_URL="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/vless-encryption.sh"
CRON_FILE="/tmp/proxym_cron.tmp"
# 非交互模式标志（用于cron等自动化场景）
NON_INTERACTIVE=false
# 确保 UTF-8 编码
export LC_ALL=C.UTF-8
# 国家代码到国旗的完整映射（基于 ISO 3166-1 alpha-2）
declare -A FLAGS=(
    [AD]="🇦🇩" [AE]="🇦🇪" [AF]="🇦🇫" [AG]="🇦🇬" [AI]="🇦🇮"
    [AL]="🇦🇱" [AM]="🇦🇲" [AO]="🇦🇴" [AQ]="🇦🇶" [AR]="🇦🇷"
    [AS]="🇦🇸" [AT]="🇦🇹" [AU]="🇦🇺" [AW]="🇦🇼" [AX]="🇦🇽"
    [AZ]="🇦🇿" [BA]="🇧🇦" [BB]="🇧🇭" [BD]="🇧🇩" [BE]="🇧🇪"
    [BF]="🇧🇫" [BG]="🇬🇬" [BH]="🇧🇭" [BI]="🇧🇮" [BJ]="🇧🇯"
    [BL]="🇧🇱" [BM]="🇧🇲" [BN]="🇧🇳" [BO]="🇧🇴" [BQ]="🇧🇶"
    [BR]="🇧🇷" [BS]="🇧🇸" [BT]="🇧🇹" [BV]="🇧🇻" [BW]="🇧🇼"
    [BY]="🇧🇾" [BZ]="🇧🇿" [CA]="🇨🇦" [CC]="🇨🇨" [CD]="🇨🇩"
    [CF]="🇨🇫" [CG]="🇨🇬" [CH]="🇨🇭" [CI]="🇨🇮" [CK]="🇨🇰"
    [CL]="🇨🇱" [CM]="🇨🇲" [CN]="🇨🇳" [CO]="🇨🇴" [CR]="🇨🇷"
    [CU]="🇨🇺" [CV]="🇨🇻" [CW]="🇨🇼" [CX]="🇨🇽" [CY]="🇨🇾"
    [CZ]="🇨🇿" [DE]="🇩🇪" [DJ]="🇩🇯" [DK]="🇩🇰" [DM]="🇩🇲"
    [DO]="🇩🇴" [DZ]="🇩🇿" [EC]="🇪🇨" [EE]="🇪🇪" [EG]="🇪🇬"
    [EH]="🇪🇭" [ER]="🇪🇷" [ES]="🇪🇸" [ET]="🇪🇹" [FI]="🇫🇮"
    [FJ]="🇫🇯" [FK]="🇫🇰" [FM]="🇫🇲" [FO]="🇫🇴" [FR]="🇫🇷"
    [GA]="🇬🇦" [GB]="🇬🇧" [GD]="🇬🇩" [GE]="🇬🇪" [GF]="🇬🇫"
    [GG]="🇬🇬" [GH]="🇬🇭" [GI]="🇬🇮" [GL]="🇬🇱" [GM]="🇬🇲"
    [GN]="🇬🇳" [GP]="🇬🇵" [GQ]="🇬🇶" [GR]="🇬🇷" [GS]="🇬🇸"
    [GT]="🇬🇹" [GU]="🇬🇺" [GW]="🇬🇼" [GY]="🇬🇾" [HK]="🇭🇰"
    [HM]="🇭🇲" [HN]="🇭🇳" [HR]="🇭🇷" [HT]="🇭🇹" [HU]="🇭🇺"
    [ID]="🇮🇩" [IE]="🇮🇪" [IL]="🇮🇱" [IM]="🇮🇲" [IN]="🇮🇳"
    [IO]="🇮🇴" [IQ]="🇮🇶" [IR]="🇮🇷" [IS]="🇮🇸" [IT]="🇮🇹"
    [JE]="🇯🇪" [JM]="🇯🇲" [JO]="🇯🇴" [JP]="🇯🇵" [KE]="🇰🇪"
    [KG]="🇰🇬" [KH]="🇰🇭" [KI]="🇰🇮" [KM]="🇰🇲" [KN]="🇰🇳"
    [KP]="🇰🇵" [KR]="🇰🇷" [KW]="🇰🇼" [KY]="🇰🇾" [KZ]="🇰🇿"
    [LA]="🇱🇦" [LB]="🇱🇧" [LC]="🇱🇨" [LI]="🇱🇮" [LK]="🇱🇰"
    [LR]="🇱🇷" [LS]="🇱🇸" [LT]="🇱🇹" [LU]="🇱🇺" [LV]="🇱🇻"
    [LY]="🇱🇾" [MA]="🇲🇦" [MC]="🇲🇨" [MD]="🇲🇩" [ME]="🇲🇪"
    [MF]="🇲🇫" [MG]="🇲🇬" [MH]="🇲🇭" [MK]="🇲🇰" [ML]="🇲🇱"
    [MM]="🇲🇲" [MN]="🇲🇳" [MO]="🇲🇴" [MP]="🇲🇵" [MQ]="🇲🇶"
    [MR]="🇲🇷" [MS]="🇲🇸" [MT]="🇲🇹" [MU]="🇲🇺" [MV]="🇲🇻"
    [MW]="🇲🇼" [MX]="🇲🇽" [MY]="🇲🇾" [MZ]="🇲🇿" [NA]="🇳🇦"
    [NC]="🇳🇨" [NE]="🇳🇪" [NF]="🇳🇫" [NG]="🇳🇬" [NI]="🇳🇮"
    [NL]="🇳🇱" [NO]="🇳🇴" [NP]="🇳🇵" [NR]="🇳🇷" [NU]="🇳🇺"
    [NZ]="🇳🇿" [OM]="🇴🇲" [PA]="🇵🇦" [PE]="🇵🇪" [PF]="🇵🇫"
    [PG]="🇵🇬" [PH]="🇵🇭" [PK]="🇵🇰" [PL]="🇵🇱" [PM]="🇵🇲"
    [PN]="🇵🇳" [PR]="🇵🇷" [PS]="🇵🇸" [PT]="🇵🇹" [PW]="🇵🇼"
    [PY]="🇵🇾" [QA]="🇶🇦" [RE]="🇷🇪" [RO]="🇷🇴" [RS]="🇷🇸"
    [RU]="🇷🇺" [RW]="🇷🇼" [SA]="🇸🇦" [SB]="🇸🇧" [SC]="🇸🇨"
    [SD]="🇸🇩" [SE]="🇸🇪" [SG]="🇸🇬" [SH]="🇸🇭" [SI]="🇸🇮"
    [SJ]="🇸🇯" [SK]="🇸🇰" [SL]="🇸🇱" [SM]="🇸🇲" [SN]="🇸🇳"
    [SO]="🇸🇴" [SR]="🇸🇷" [SS]="🇸🇸" [ST]="🇸🇹" [SV]="🇸🇻"
    [SX]="🇸🇽" [SY]="🇸🇾" [SZ]="🇸🇿" [TC]="🇹🇨" [TD]="🇹🇩"
    [TF]="🇹🇫" [TG]="🇹🇬" [TH]="🇹🇭" [TJ]="🇹🇯" [TK]="🇹🇰"
    [TL]="🇹🇱" [TM]="🇹🇲" [TN]="🇹🇳" [TO]="🇹🇴" [TR]="🇹🇷"
    [TT]="🇹🇹" [TV]="🇹🇻" [TW]="🇹🇼" [TZ]="🇹🇿" [UA]="🇺🇦"
    [UG]="🇺🇬" [UM]="🇺🇲" [US]="🇺🇸" [UY]="🇺🇾" [UZ]="🇺🇿"
    [VA]="🇻🇦" [VC]="🇻🇨" [VE]="🇻🇪" [VG]="🇬🇬" [VI]="🇻🇮"
    [VN]="🇻🇳" [VU]="🇻🇺" [WF]="🇼🇫" [WS]="🇼🇸" [YE]="🇾🇪"
    [YT]="🇾🇹" [ZA]="🇿🇦" [ZM]="🇿🇲" [ZW]="🇿🇼"
)
# URL 编码函数（使用 Python3 进行 URL 编码，支持 Unicode 如 emoji）
url_encode() {
    if command -v python3 &> /dev/null; then
        python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.buffer.read().decode('utf-8').strip(), safe=''), end='')" <<< "$1"
    else
        echo -e "${WARN} Python3 未找到，无法 URL 编码标签。使用原始标签。${NC}"
        echo "$1"
    fi
}
# 随机生成10位字符串
generate_random_path() {
    openssl rand -hex 5 2>/dev/null || echo "defaultpath$(date +%s | cut -c1-5)"
}
# 确保 proxym 目录存在
sudo mkdir -p /etc/proxym
function log() {
    echo -e "${INFO} $1${NC}"
}
function error() {
    echo -e "${ERROR} $1${NC}"
    exit 1
}
function get_location_from_ip() {
    local ip=$1
    local location_info=$(curl -s --max-time 10 "http://ip-api.com/json/$ip?fields=status,message,countryCode,city" 2>/dev/null)
    if echo "$location_info" | grep -q '"status":"fail"'; then
        echo "Unknown" "Unknown"
        return
    fi
    local country=$(echo "$location_info" | grep -o '"countryCode":"[^"]*"' | sed 's/.*"countryCode":"\([^"]*\)".*/\1/')
    local city=$(echo "$location_info" | grep -o '"city":"[^"]*"' | sed 's/.*"city":"\([^"]*\)".*/\1/')
    if [ -z "$country" ] || [ -z "$city" ]; then
        echo "Unknown" "Unknown"
        return
    fi
    echo "$country" "$city"
}
function load_global_config() {
    if [ -f "$GLOBAL_JSON" ]; then
        dns_server=$(jq -r '.dns_server // "8.8.8.8"' "$GLOBAL_JSON")
        strategy=$(jq -r '.strategy // "UseIPv4"' "$GLOBAL_JSON")
        domain_strategy=$(jq -r '.domain_strategy // "UseIPv4v6"' "$GLOBAL_JSON")
    else
        dns_server="8.8.8.8"
        strategy="UseIPv4"
        domain_strategy="UseIPv4v6"
    fi
}
function save_global_config() {
    cat > "$GLOBAL_JSON" << EOF
{
  "dns_server": "$dns_server",
  "strategy": "$strategy",
  "domain_strategy": "$domain_strategy"
}
EOF
    log "全局配置已保存到 $GLOBAL_JSON"
}
function update_script() {
    log "检查更新..."
    if [ ! -f "$SCRIPT_PATH" ]; then
        error "脚本未在 $SCRIPT_PATH 找到"
    fi
    cp "$SCRIPT_PATH" "${SCRIPT_PATH}.bak"
    log "备份已创建: ${SCRIPT_PATH}.bak"
    if ! curl -s -o "${SCRIPT_PATH}.new" "$UPDATE_URL"; then
        error "从 $UPDATE_URL 下载更新失败"
    fi
    if bash -n "${SCRIPT_PATH}.new" 2>/dev/null; then
        mv "${SCRIPT_PATH}.new" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        log "更新成功！"
        rm -f "${SCRIPT_PATH}.bak"
        exec bash "$SCRIPT_PATH"
    else
        rm -f "${SCRIPT_PATH}.new"
        mv "${SCRIPT_PATH}.bak" "$SCRIPT_PATH"
        error "更新语法错误！已回滚到备份。"
    fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function detect_package_manager() {
    if command -v apt &> /dev/null; then
        echo "apt"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v apk &> /dev/null; then
        echo "apk"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    else
        echo "none"
    fi
}
function install_dependencies() {
    local force_update=${1:-false}
    local pkg_manager=$(detect_package_manager)
    local deps=("curl" "unzip" "ca-certificates" "wget" "gnupg" "python3" "jq")
    local cron_pkg="cron"
    if [ "$pkg_manager" = "apk" ]; then
        cron_pkg="dcron"
    elif [ "$pkg_manager" = "pacman" ] || [ "$pkg_manager" = "yum" ] || [ "$pkg_manager" = "dnf" ]; then
        cron_pkg="cronie"
    fi
    deps+=("$cron_pkg")
    if [ "$force_update" = true ]; then
        log "安装 Xray 依赖..."
        case "$pkg_manager" in
            apt)
                sudo apt update
                sudo apt install -y "${deps[@]}"
                log "Debian/Ubuntu 依赖安装完成。"
                ;;
            yum)
                sudo yum update -y
                sudo yum install -y "${deps[@]}"
                log "CentOS/RHEL 依赖安装完成。"
                ;;
            dnf)
                sudo dnf update -y
                sudo dnf install -y "${deps[@]}"
                log "Fedora 依赖安装完成。"
                ;;
            apk)
                sudo apk update
                sudo apk add --no-cache "${deps[@]}"
                log "Alpine 依赖安装完成。"
                ;;
            pacman)
                sudo pacman -Syu --noconfirm "${deps[@]}"
                log "Arch 依赖安装完成。"
                ;;
            *)
                echo -e "${WARN} 未检测到包管理器，请手动安装 curl、unzip、ca-certificates、python3、cron、jq。${NC}"
                ;;
        esac
    else
        local missing_deps=()
        for dep in "${deps[@]}"; do
            if ! command -v "${dep% *}" &> /dev/null; then
                missing_deps+=("$dep")
            fi
        done
        if [ ${#missing_deps[@]} -gt 0 ]; then
            log "检测到缺少依赖: ${missing_deps[*]}，正在安装..."
            case "$pkg_manager" in
                apt)
                    sudo apt update
                    sudo apt install -y "${missing_deps[@]}"
                    log "Debian/Ubuntu 依赖安装完成。"
                    ;;
                yum)
                    sudo yum install -y "${missing_deps[@]}"
                    log "CentOS/RHEL 依赖安装完成。"
                    ;;
                dnf)
                    sudo dnf install -y "${missing_deps[@]}"
                    log "Fedora 依赖安装完成。"
                    ;;
                apk)
                    sudo apk update
                    sudo apk add --no-cache "${missing_deps[@]}"
                    log "Alpine 依赖安装完成。"
                    ;;
                pacman)
                    sudo pacman -S --noconfirm "${missing_deps[@]}"
                    log "Arch 依赖安装完成。"
                    ;;
                *)
                    echo -e "${WARN} 未检测到包管理器，请手动安装缺少的依赖: ${missing_deps[*]}。${NC}"
                    ;;
            esac
        fi
    fi
}
function detect_init_system() {
    if command -v systemctl &> /dev/null; then
        echo "systemd"
    elif command -v rc-service &> /dev/null; then
        echo "openrc"
    else
        echo "none"
    fi
}
function install_xray() {
    local pause=${1:-1}
    local force_deps=${2:-false}
    local is_update=${3:-false}
    local init_system=$(detect_init_system)
    
    if command -v xray &> /dev/null && [ "$is_update" = false ]; then
        log "Xray 已安装。"
        if [ $pause -eq 1 ] && [ "$NON_INTERACTIVE" != "true" ]; then
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
            # 仅在初次安装时询问降级权限
            if [ "$is_update" = false ] && [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "是否为 Xray 节点降低网络特权（仅保留 cap_net_bind_service）？(y/N): " reduce_priv
                if [[ $reduce_priv =~ ^[Yy]$ ]]; then
                    sudo sed -i 's/^capabilities="^cap_net_bind_service,^cap_net_admin,^cap_net_raw"$/capabilities="^cap_net_bind_service"/g' /etc/init.d/xray
                    log "已调整 Xray 网络特权，仅保留 cap_net_bind_service。"
                fi
            fi
        else
            bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
        fi
        
        if [ $? -eq 0 ]; then
            log "Xray 安装/更新成功。"
        else
            error "Xray 安装/更新失败。"
        fi
        
        # 无论更新还是安装，都尝试重启 Xray 以应用新版本或新配置
        if command -v xray &> /dev/null; then
            restart_xray 0
        fi
        
        if [ $pause -eq 1 ] && [ "$NON_INTERACTIVE" != "true" ]; then
            read -p "按 Enter 返回菜单..."
        fi
    fi
}
function update_xray_core() {
    log "检查 Xray Core 更新..."
    
    if ! command -v xray &> /dev/null; then
        log "Xray 尚未安装，将转到安装程序。"
        install_xray 1 true
        return
    fi
    
    # 1. 获取当前版本
    local current_version
    current_version=$(xray -version 2>/dev/null | grep Xray | head -n 1 | awk '{print $2}')
    
    # 2. 获取最新版本
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | \
    grep tag_name | cut -d '"' -f4 | sed 's/^v//')
     
    if [ -z "$current_version" ]; then
        echo -e "${WARN} 无法获取当前 Xray 版本。${NC}"
        current_version="未知"
    fi
    
    if [ -z "$latest_version" ]; then
        error "无法获取 Xray 最新版本，请检查网络连接。"
        return
    fi
    
    log "当前 Xray 版本: ${YELLOW}$current_version${NC}"
    log "最新 Xray 版本: ${GREEN}$latest_version${NC}"
    
    # 3. 版本对比 (简单字符串比较)
    if [ "$current_version" = "$latest_version" ]; then
        log "您的 Xray 版本已是最新，无需更新。${CHECK}"
    else
        echo -e "${YELLOW}检测到新版本。是否立即更新 Xray Core？ (y/N): ${NC}"
        if [ "$NON_INTERACTIVE" != "true" ]; then
            read -p "请输入选项 (y/N, 默认 N): " update_choice
        else
            update_choice="n" # 非交互模式下默认不更新
        fi
        
        if [[ $update_choice =~ ^[Yy]$ ]]; then
            install_xray 1 true true # 运行安装脚本即为更新
            return
        else
            log "取消更新，返回主菜单。"
        fi
    fi
    
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function fix_xray_service() {
    local service_file="/lib/systemd/system/xray.service"
    if [ ! -f "$service_file" ]; then
        service_file="/etc/systemd/system/xray.service"
        if [ ! -f "$service_file" ]; then
            error "Xray 服务文件未找到 ($service_file)。请确保 Xray 已安装。"
        fi
    fi
    local backup_file="${service_file}.bak.$(date +%Y%m%d_%H%M%S)"
    sudo cp "$service_file" "$backup_file"
    log "备份创建: $backup_file"
    sudo sed -i '/^LimitNOFILE=/c\LimitNOFILE=500000' "$service_file"
    sudo sed -i '/^AmbientCapabilities=/!{/^User=/a AmbientCapabilities=CAP_SYS_RESOURCE' "$service_file"
    sudo systemctl daemon-reload
    sudo systemctl reset-failed xray
    sudo systemctl restart xray
    log "Xray 服务修复完成，已重启。"
    status_xray
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function start_xray() {
    local init_system=$(detect_init_system)
    if [ "$init_system" = "systemd" ]; then
        sudo systemctl start xray
    elif [ "$init_system" = "openrc" ]; then
        sudo rc-service xray start
    else
        error "不支持的 init 系统。"
    fi
    log "Xray 已启动。"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function stop_xray() {
    local init_system=$(detect_init_system)
    if [ "$init_system" = "systemd" ]; then
        sudo systemctl stop xray
    elif [ "$init_system" = "openrc" ]; then
        sudo rc-service xray stop
    else
        error "不支持的 init 系统。"
    fi
    log "Xray 已停止。"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function restart_xray() {
    local pause=${1:-1}
    local init_system=$(detect_init_system)
    if [ "$init_system" = "systemd" ]; then
        sudo systemctl restart xray
    elif [ "$init_system" = "openrc" ]; then
        sudo rc-service xray restart
    else
        error "不支持的 init 系统。"
    fi
    log "Xray 已重启。"
    if [ $pause -eq 1 ] && [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function status_xray() {
    local init_system=$(detect_init_system)
    if [ "$init_system" = "systemd" ]; then
        sudo systemctl status xray --no-pager
    elif [ "$init_system" = "openrc" ]; then
        sudo rc-service xray status
    else
        error "不支持的 init 系统。"
    fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function view_logs() {
    local init_system=$(detect_init_system)
    if [ "$init_system" = "systemd" ]; then
        sudo journalctl -u xray -f --no-pager
    elif [ "$init_system" = "openrc" ]; then
        if [ -f /var/log/xray.log ]; then
            tail -f /var/log/xray.log
        else
            error "Xray 日志文件未找到（/var/log/xray.log）。请检查配置。"
        fi
    else
        error "不支持的 init 系统。"
    fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function edit_config() {
    if [ ! -f "$CONFIG" ]; then
        error "配置文件不存在。请先生成配置。"
    fi
    sudo vim "$CONFIG"
    log "编辑完成。"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function test_config() {
    if [ ! -f "$CONFIG" ]; then
        error "配置文件不存在。请先生成配置。"
    fi
    if xray -test -config "$CONFIG" &> /dev/null; then
        log "配置测试通过！"
    else
        error "配置测试失败！请检查配置文件。"
    fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function generate_node_info() {
    local uuid=$1
    local port=$2
    local decryption=$3
    local encryption=$4
    local ip=$5
    local tag=$6
    local uri=$7
    local domain=$8
    local network=$9
    local path=${10}
    local host=${11}
    local fingerprint=${12}
    local is_custom=${13}
    local use_reality=${14}
    local dest=${15}
    local sni=${16}
    local shortids_json=${17}
    local public_key_base64=${18}
    local flow=${19}
    local push_enabled=${20}
    local push_url=${21}
    local push_token=${22}
    local servernames_json=${23}
    local private_key=${24:-""}
    local kex=${25}
    local method=${26}
    local rtt=${27}
    local use_mlkem=${28}
    if [ "$use_reality" = true ]; then
        cat << EOF
{
  "uuid": "$uuid",
  "port": $port,
  "decryption": "$decryption",
  "encryption": "$encryption",
  "ip": "$ip",
  "tag": "$tag",
  "uri": "$uri",
  "domain": "$domain",
  "network": "$network",
  "path": "$path",
  "use_reality": true,
  "dest": "$dest",
  "sni": "$sni",
  "shortIds": $shortids_json,
  "public_key": "$public_key_base64",
  "flow": "$flow",
  "fingerprint": "$fingerprint",
  "is_custom_tag": $is_custom,
  "push_enabled": $push_enabled,
  "push_url": "$push_url",
  "push_token": "$push_token",
  "serverNames": $servernames_json,
  "privateKey": "$private_key",
  "kex": "$kex",
  "method": "$method",
  "rtt": "$rtt",
  "use_mlkem": $use_mlkem
}
EOF
    else
        cat << EOF
{
  "uuid": "$uuid",
  "port": $port,
  "decryption": "$decryption",
  "encryption": "$encryption",
  "ip": "$ip",
  "tag": "$tag",
  "uri": "$uri",
  "domain": "$domain",
  "network": "$network",
  "path": "$path",
  "host": "$host",
  "fingerprint": "$fingerprint",
  "is_custom_tag": $is_custom,
  "push_enabled": $push_enabled,
  "push_url": "$push_url",
  "push_token": "$push_token",
  "kex": "$kex",
  "method": "$method",
  "rtt": "$rtt",
  "use_mlkem": $use_mlkem
}
EOF
    fi
}
function push_to_remote() {
    local uri=$1
    local push_url=$2
    local push_token=$3
    if [ -z "$push_url" ] || [ -z "$push_token" ]; then
        log "Push 配置不完整，跳过。"
        return
    fi
    local payload='{"token":"'"$push_token"'","uri":"'"$uri"'"}'
    local response=$(curl -s -X POST "$push_url" -H "Content-Type: application/json" -d "$payload")
    if [ $? -eq 0 ]; then
        log "成功推送 URI 到 $push_url"
    else
        error "推送失败: $response"
    fi
}
function reset_all() {
    if [ ! -f "$VLESS_JSON" ]; then
        error "未找到配置信息。请先生成配置。"
    fi
    log "重置所有节点的 UUID 和密码..."
    local nodes=$(jq -c '.[]' "$VLESS_JSON")
    local new_nodes=()
    while IFS= read -r node; do
        local uuid=$(xray uuid)
        local port=$(echo "$node" | jq -r '.port')
        local ip=$(echo "$node" | jq -r '.ip')
        local domain=$(echo "$node" | jq -r '.domain')
        local network=$(echo "$node" | jq -r '.network')
        local path=$(echo "$node" | jq -r '.path')
        local host=$(echo "$node" | jq -r '.host')
        local fingerprint=$(echo "$node" | jq -r '.fingerprint')
        local is_custom=$(echo "$node" | jq -r '.is_custom_tag')
        local use_reality=$(echo "$node" | jq -r '.use_reality // false')
        local dest=$(echo "$node" | jq -r '.dest // ""')
        local sni=$(echo "$node" | jq -r '.sni // ""')
        local shortids_json=$(echo "$node" | jq -r '.shortIds // []')
        local flow=$(echo "$node" | jq -r '.flow // ""')
        local push_enabled=$(echo "$node" | jq -r '.push_enabled // false')
        local push_url=$(echo "$node" | jq -r '.push_url // ""')
        local push_token=$(echo "$node" | jq -r '.push_token // ""')
        local servernames_json=$(echo "$node" | jq -r '.serverNames // []')
        local private_key=$(echo "$node" | jq -r '.privateKey // ""')
        local kex=$(echo "$node" | jq -r '.kex // ""')
        local method=$(echo "$node" | jq -r '.method // ""')
        local rtt=$(echo "$node" | jq -r '.rtt // ""')
        local use_mlkem=$(echo "$node" | jq -r '.use_mlkem // false')
        local decryption
        local encryption
        local public_key_base64
        if [ "$use_reality" = false ]; then
            if [ "$rtt" = "0rtt" ]; then
                time_server="600s"
            else
                time_server="0s"
            fi
            x25519_output=$(xray x25519)
            private=$(echo "$x25519_output" | grep "PrivateKey:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
            password=$(echo "$x25519_output" | grep "Password:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
            local seed=""
            local client_param=""
            if [ "$use_mlkem" = true ]; then
                mlkem_output=$(xray mlkem768 2>/dev/null)
                seed=$(echo "$mlkem_output" | grep "Seed:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
                client_param=$(echo "$mlkem_output" | grep "Client:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
            fi
            decryption="${kex}.${method}.${time_server}.${private}"
            if [ "$use_mlkem" = true ]; then
                decryption="${decryption}.${seed}"
            fi
            encryption="${kex}.${method}.${rtt}.${password}"
            if [ "$use_mlkem" = true ]; then
                encryption="${encryption}.${client_param}"
            fi
        else
            x25519_output=$(xray x25519)
            private=$(echo "$x25519_output" | grep "PrivateKey:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
            password=$(echo "$x25519_output" | grep "Password:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
            public_key_base64="$password"
            private_key="$private"
            decryption="none"
            encryption="none"
        fi
        # 处理标签
        local tag=$(echo "$node" | jq -r '.tag')
        if [ "$is_custom" = false ]; then
            read country city <<< $(get_location_from_ip "$ip")
            local flag="${FLAGS[$country]:-🌍}"
            tag="${flag} ${city}"
        fi
        # 重新生成 URI
        local server_address
        if [ -n "$domain" ]; then
            server_address="$domain"
        else
            server_address="$ip"
            if [[ "$server_address" =~ : ]] && ! [[ "$server_address" =~ \[.*\] ]]; then
                server_address="[$server_address]"
            fi
        fi
        local uri_params="type=${network}&encryption=${encryption}&packetEncoding=xudp"
        if [ "$network" = "ws" ]; then
            encoded_path=$(url_encode "$path")
            encoded_host=$(url_encode "$host")
            uri_params="${uri_params}&host=${encoded_host}&path=${encoded_path}"
        fi
        if [ "$domain" ]; then
            uri_params="${uri_params}&security=tls&sni=${domain}&fp=${fingerprint}"
        else
            uri_params="${uri_params}&security=none"
        fi
        if [ "$use_reality" = true ]; then
            local shortids_array
            IFS=',' read -ra shortids_array <<< "$(echo "$shortids_json" | jq -r '.[0]')"
            local shortId="${shortids_array[0]:-}"
            uri_params="type=tcp&encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=${fingerprint}&sid=${shortId}&pbk=${public_key_base64}&packetEncoding=xudp"
        fi
        encoded_tag=$(url_encode "$tag")
        local uri="vless://${uuid}@${server_address}:${port}?${uri_params}#${encoded_tag}"
        new_nodes+=("$(generate_node_info "$uuid" "$port" "$decryption" "$encryption" "$ip" "$tag" "$uri" "$domain" "$network" "$path" "$host" "$fingerprint" "$is_custom" "$use_reality" "$dest" "$sni" "$shortids_json" "$public_key_base64" "$flow" "$push_enabled" "$push_url" "$push_token" "$servernames_json" "$private_key" "$kex" "$method" "$rtt" "$use_mlkem")")
    done <<< "$nodes"
    # 保存新节点
    printf '%s\n' "${new_nodes[@]}" | jq -s '.' > "$VLESS_JSON"
    # 重新生成 config.json（使用保存的全局配置）
    regenerate_full_config
    restart_xray 0
    log "所有节点已重置，Xray 已重启。"
    # 自动推送
    nodes=$(jq -c '.[]' "$VLESS_JSON")
    while IFS= read -r node; do
        local push_enabled=$(echo "$node" | jq -r '.push_enabled // false')
        if [ "$push_enabled" = true ]; then
            local uri=$(echo "$node" | jq -r '.uri')
            local push_url=$(echo "$node" | jq -r '.push_url')
            local push_token=$(echo "$node" | jq -r '.push_token')
            push_to_remote "$uri" "$push_url" "$push_token"
        fi
    done <<< "$nodes"
    # 在非交互模式下，打印完成消息并直接退出
    if [ "$NON_INTERACTIVE" = "true" ]; then
        echo -e "${GREEN}重置完成！所有节点 UUID/密码已更新，Xray 已重启。${NC}"
        echo -e "${YELLOW}新 URI:${NC}"
        jq -r '.[] | .uri' "$VLESS_JSON" | while read uri; do
            echo "$uri"
        done
    fi
}
function regenerate_full_config() {
    load_global_config # 从 global.json 加载 DNS 和策略
    local nodes=$(jq -c '.[]' "$VLESS_JSON")
    local inbounds=()
    while IFS= read -r node; do
        local port=$(echo "$node" | jq -r '.port')
        local uuid=$(echo "$node" | jq -r '.uuid')
        local decryption=$(echo "$node" | jq -r '.decryption')
        local network=$(echo "$node" | jq -r '.network')
        local path=$(echo "$node" | jq -r '.path')
        local host=$(echo "$node" | jq -r '.host')
        local fingerprint=$(echo "$node" | jq -r '.fingerprint')
        local use_reality=$(echo "$node" | jq -r '.use_reality // false')
        local dest=$(echo "$node" | jq -r '.dest // ""')
        local servernames_json=$(echo "$node" | jq -r '.serverNames // []')
        local private_key=$(echo "$node" | jq -r '.privateKey // ""')
        local shortids_json=$(echo "$node" | jq -r '.shortIds // []')
        local flow=$(echo "$node" | jq -r '.flow // ""')
        local domain=$(echo "$node" | jq -r '.domain')
        if [ "$use_reality" = true ]; then
            stream_settings='{
              "network": "tcp",
              "security": "reality",
              "realitySettings": {
                "dest": "'"$dest"'",
                "serverNames": '"$servernames_json"',
                "privateKey": "'"$private_key"'",
                "shortIds": '"$shortids_json"',
                "fingerprint": "'"$fingerprint"'"
              }
            }'
            client_flow='{"id":"'"$uuid"'","flow":"'"$flow"'"}'
        else
            ws_settings='{
              "path": "'"$path"'",
              "headers": {
                "Host": "'"$host"'"
              }
            }'
            if [ -n "$domain" ]; then
                # 假设证书路径基于域名
                cert_path="/etc/ssl/acme/$domain/fullchain.pem"
                key_path="/etc/ssl/acme/$domain/privkey.key"
                tls_settings='{
                  "certificates": [
                    {
                      "certificateFile": "'"$cert_path"'",
                      "keyFile": "'"$key_path"'"
                    }
                  ],
                  "fingerprint": "'"$fingerprint"'"
                }'
                stream_settings='{
                  "network": "'"$network"'",
                  "security": "tls",
                  "tlsSettings": '"$tls_settings"',
                  "wsSettings": '"$ws_settings"'
                }'
            else
                if [ "$network" = "ws" ]; then
                    stream_settings='{
                      "network": "'"$network"'",
                      "wsSettings": '"$ws_settings"'
                    }'
                else
                    stream_settings='{"network": "'"$network"'"}'
                fi
            fi
            client_flow='{"id":"'"$uuid"'"}'
        fi
        inbounds+=('{
          "port": '"$port"',
          "protocol": "vless",
          "settings": {
            "clients": [
              '"$client_flow"'
            ],
            "decryption": "'"$decryption"'"
          },
          "streamSettings": '"$stream_settings"'
        }')
    done <<< "$nodes"
    inbounds_json=$(printf '%s\n' "${inbounds[@]}" | jq -s '.')
    cat > "$CONFIG" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      {
        "address": "$dns_server"
      }
    ],
    "queryStrategy": "$strategy"
  },
  "inbounds": $inbounds_json,
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "$domain_strategy"
      },
      "tag": "direct"
    }
  ]
}
EOF
    if xray -test -config "$CONFIG" &> /dev/null; then
        log "配置已重新生成。"
    else
        error "配置测试失败！"
    fi
}
function generate_config() {
    install_xray 0 false
    sudo mkdir -p /usr/local/etc/xray
    log "生成新的 VLESS 配置..."
    echo -e "${YELLOW}按 Enter 使用默认值。${NC}"
    if [ ! -f "$CONFIG" ]; then
        overwrite=true
    else
        if [ "$NON_INTERACTIVE" != "true" ]; then
            read -p "配置文件已存在。覆盖 (Y) 还是附加节点 (N)? (默认 Y): " overwrite_choice
            if [[ ! "$overwrite_choice" =~ ^[Nn]$ ]]; then
                overwrite=true
            else
                overwrite=false
                log "附加模式：仅更新节点相关内容。"
            fi
        else
            overwrite=true # 非交互模式下默认覆盖
        fi
    fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "UUID (默认: 新生成): " uuid_input
        if [ -z "$uuid_input" ]; then
            uuid=$(xray uuid)
        else
            uuid="$uuid_input"
        fi
    else
        uuid=$(xray uuid)
    fi
    log "UUID: $uuid"
    echo "请选择 KEX:"
    echo "[1] x25519"
    echo "[2] mlkem768x25519plus (默认)"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "请输入选项 (1-2, 默认: 2): " kex_choice_input
        if [ -z "$kex_choice_input" ]; then
            kex_choice_input="2"
        fi
    else
        kex_choice_input="2"
    fi
    case "$kex_choice_input" in
        1) kex="x25519"; use_mlkem=false ;;
        2) kex="mlkem768x25519plus"; use_mlkem=true ;;
        *) kex="mlkem768x25519plus"; use_mlkem=true ;;
    esac
    log "KEX: $kex"
    echo "请选择方法:"
    echo "[1] native"
    echo "[2] xorpub"
    echo "[3] random (默认)"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "请输入选项 (1-3, 默认: 3): " method_choice_input
        if [ -z "$method_choice_input" ]; then
            method_choice_input="3"
        fi
    else
        method_choice_input="3"
    fi
    case "$method_choice_input" in
        1) method="native" ;;
        2) method="xorpub" ;;
        3) method="random" ;;
        *) method="random" ;;
    esac
    log "方法: $method"
    echo "请选择 RTT:"
    echo "[1] 0rtt (默认)"
    echo "[2] 1rtt"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "请输入选项 (1-2, 默认: 1): " rtt_choice_input
        if [ -z "$rtt_choice_input" ]; then
            rtt_choice_input="1"
        fi
    else
        rtt_choice_input="1"
    fi
    case "$rtt_choice_input" in
        1) rtt="0rtt" ;;
        2) rtt="1rtt" ;;
        *) rtt="0rtt" ;;
    esac
    log "RTT: $rtt"
    if [ "$rtt" = "0rtt" ]; then
        time_server="600s"
    else
        time_server="0s"
    fi
    echo "是否启用 REALITY (Xray 官方推荐用于 TCP):"
    echo "[1] 是 (仅支持 TCP)"
    echo "[2] 否 (支持 TCP 或 WebSocket + TLS 或 WebSocket 无 TLS)"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "请输入选项 (1-2, 默认: 2): " reality_choice_input
        if [ -z "$reality_choice_input" ]; then
            reality_choice_input="2"
        fi
    else
        reality_choice_input="2"
    fi
    case "$reality_choice_input" in
        1) use_reality=true ;;
        *) use_reality=false ;;
    esac
    log "启用 REALITY: $( [ "$use_reality" = true ] && echo "是" || echo "否" )"
    local decryption
    local encryption
    local private
    local public_key_base64
    local seed=""
    local client_param=""
    if [ "$use_reality" = false ]; then
        log "生成 X25519 密钥..."
        x25519_output=$(xray x25519)
        private=$(echo "$x25519_output" | grep "PrivateKey:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
        password=$(echo "$x25519_output" | grep "Password:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
        if [ -z "$private" ] || [ -z "$password" ]; then
            error "X25519 密钥生成失败。请确保 Xray 已安装。"
        fi
        if [ "$use_mlkem" = true ]; then
            log "生成 ML-KEM-768 密钥..."
            mlkem_output=$(xray mlkem768 2>/dev/null)
            seed=$(echo "$mlkem_output" | grep "Seed:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
            client_param=$(echo "$mlkem_output" | grep "Client:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
            if [ -z "$seed" ] || [ -z "$client_param" ]; then
                echo -e "${WARN} ML-KEM-768 不支持，回退到 X25519。建议更新 Xray 到 v25.5.16+。${NC}"
                kex="x25519"
                use_mlkem=false
            fi
        fi
        decryption="${kex}.${method}.${time_server}.${private}"
        if [ "$use_mlkem" = true ]; then
            decryption="${decryption}.${seed}"
        fi
        encryption="${kex}.${method}.${rtt}.${password}"
        if [ "$use_mlkem" = true ]; then
            encryption="${encryption}.${client_param}"
        fi
    else
        log "REALITY 模式下生成专用 X25519 密钥..."
        x25519_output=$(xray x25519)
        private=$(echo "$x25519_output" | grep "PrivateKey:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
        password=$(echo "$x25519_output" | grep "Password:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
        if [ -z "$private" ] || [ -z "$password" ]; then
            error "X25519 密钥生成失败。请确保 Xray 已安装。"
        fi
        public_key_base64="$password"
        decryption="none"
        encryption="none"
        flow="xtls-rprx-vision"
        kex=""
        method=""
        rtt=""
        use_mlkem=false
        log "REALITY 模式下 VLESS Encryption 设置为 none"
        if [ "$NON_INTERACTIVE" != "true" ]; then
            read -p "REALITY 伪装目标 dest (默认: swdist.apple.com:443): " dest_input
            dest=${dest_input:-"swdist.apple.com:443"}
            read -p "serverNames (逗号分隔 SNI 列表, 默认: swdist.apple.com): " servernames_input
            if [ -z "$servernames_input" ]; then
                servernames_input="swdist.apple.com"
            fi
            IFS=',' read -ra servernames_array <<< "$servernames_input"
            servernames_json=$(IFS=','; echo "[\"${servernames_array[*]}\"]")
            sni="${servernames_array[0]}"
            read -p "shortIds (逗号分隔, 每个 0-16 hex 字符, 默认随机生成一个): " shortids_input
            if [ -z "$shortids_input" ]; then
                shortid=$(openssl rand -hex 4 2>/dev/null || echo "a1b2c3d4")
                shortids_input="$shortid"
            fi
            IFS=',' read -ra shortids <<< "$shortids_input"
            shortids_json=$(IFS=','; echo "[\"${shortids[*]}\"]")
            shortId="${shortids[0]}"
            echo "请选择 uTLS Fingerprint (用于伪装):"
            echo "[1] chrome (默认)"
            echo "[2] firefox"
            echo "[3] safari"
            echo "[4] ios"
            read -p "请输入选项 (1-4, 默认: 1): " fp_choice_input
            if [ -z "$fp_choice_input" ]; then
                fp_choice_input="1"
            fi
            case "$fp_choice_input" in
                1) fingerprint="chrome" ;;
                2) fingerprint="firefox" ;;
                3) fingerprint="safari" ;;
                4) fingerprint="ios" ;;
                *) fingerprint="chrome" ;;
            esac
            log "REALITY 配置: dest=$dest, sni=$sni, shortId=$shortId, fingerprint=$fingerprint"
        else
            dest="swdist.apple.com:443"
            servernames_input="swdist.apple.com"
            IFS=',' read -ra servernames_array <<< "$servernames_input"
            servernames_json=$(IFS=','; echo "[\"${servernames_array[*]}\"]")
            sni="${servernames_array[0]}"
            shortid=$(openssl rand -hex 4 2>/dev/null || echo "a1b2c3d4")
            shortids_json="[\"$shortid\"]"
            shortId="$shortid"
            fingerprint="chrome"
        fi
    fi
    echo "vless reality推荐端口为443"
    default_port=8443
    if [ "$use_reality" = true ]; then
        default_port=443
    fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "端口 (默认: $default_port): " port_input
        port=${port_input:-$default_port}
    else
        port=$default_port
    fi
    log "端口: $port"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "服务器 IP (默认: 自动检测): " ip_input
        if [ -z "$ip_input" ]; then
            ip=$(curl -s -4 ifconfig.me 2>/dev/null)
            if [ -z "$ip" ] || [ "$ip" = "0.0.0.0" ]; then
                log "IPv4 检测失败，尝试 IPv6..."
                ip=$(curl -s -6 ifconfig.me 2>/dev/null)
                if [ -z "$ip" ]; then
                    error "IP 检测失败。请手动输入。"
                fi
                log "使用 IPv6: $ip"
            else
                log "使用 IPv4: $ip"
            fi
        else
            ip="$ip_input"
        fi
    else
        ip=$(curl -s -4 ifconfig.me 2>/dev/null)
        if [ -z "$ip" ] || [ "$ip" = "0.0.0.0" ]; then
            ip=$(curl -s -6 ifconfig.me 2>/dev/null)
            if [ -z "$ip" ]; then
                error "IP 检测失败。"
            fi
        fi
    fi
    log "根据 IP $ip 获取地理位置..."
    read country city <<< $(get_location_from_ip "$ip")
    local flag="${FLAGS[$country]:-🌍}"
    auto_tag="${flag} ${city}"
    if [ "$auto_tag" = "🌍 Unknown" ]; then
        auto_tag="Unknown"
    fi
    echo "节点备注 (标签):"
    echo "[1] 使用自动获取: $auto_tag"
    echo "[2] 自定义"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "请选择 (1-2, 默认: 1): " tag_choice
        if [ -z "$tag_choice" ] || [ "$tag_choice" = "1" ]; then
            tag="$auto_tag"
            is_custom=false
        else
            read -p "输入自定义名称: " custom_name
            read -p "是否添加旗帜 ($flag)？ (y/N): " add_flag
            if [[ $add_flag =~ ^[Yy]$ ]]; then
                tag="$flag $custom_name"
            else
                tag="$custom_name"
            fi
            is_custom=true
        fi
    else
        tag="$auto_tag"
        is_custom=false
    fi
    log "标签: $tag"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "DNS 服务器 (默认: 8.8.8.8): " dns_server_input
        dns_server=${dns_server_input:-8.8.8.8}
        echo "请选择查询策略:"
        echo "[1] UseIPv4 (默认)"
        echo "[2] UseIPv6"
        echo "[3] UseIP"
        echo "[4] AsIs"
        read -p "请输入选项 (1-4, 默认: 1): " strategy_choice_input
        if [ -z "$strategy_choice_input" ]; then
            strategy_choice_input="1"
        fi
        case "$strategy_choice_input" in
            1) strategy="UseIPv4" ;;
            2) strategy="UseIPv6" ;;
            3) strategy="UseIP" ;;
            4) strategy="AsIs" ;;
            *) strategy="UseIPv4" ;;
        esac
        log "查询策略: $strategy"
        echo "请选择出站域名策略:"
        echo "[1] UseIPv4v6 (默认)"
        echo "[2] UseIPv6v4"
        echo "[3] ForceIPv4"
        echo "[4] ForceIPv6"
        read -p "请输入选项 (1-4, 默认: 1): " domain_strategy_choice_input
        if [ -z "$domain_strategy_choice_input" ]; then
            domain_strategy_choice_input="1"
        fi
        case "$domain_strategy_choice_input" in
            1) domain_strategy="UseIPv4v6" ;;
            2) domain_strategy="UseIPv6v4" ;;
            3) domain_strategy="ForceIPv4" ;;
            4) domain_strategy="ForceIPv6" ;;
            *) domain_strategy="UseIPv4v6" ;;
        esac
        log "出站域名策略: $domain_strategy"
    else
        dns_server="8.8.8.8"
        strategy="UseIPv4"
        domain_strategy="UseIPv4v6"
    fi
    # 保存全局配置
    save_global_config
    dest=${dest:-""}
    sni=${sni:-""}
    shortids_json=${shortids_json:-"[]"}
    flow=${flow:-""}
    servernames_json=${servernames_json:-"[]"}
    public_key_base64=${public_key_base64:-""}
    local private_key=""
    if [ "$use_reality" = true ]; then
        private_key="$private"
    fi
    if [ "$use_reality" = true ]; then
        network="tcp"
        type_uri="tcp"
        security_uri="reality"
        path=""
        host=""
        server_address="${ip}"
        if [[ "$ip" =~ : ]] && ! [[ "$ip" =~ \[ || "$ip" =~ \] ]]; then
            server_address="[${ip}]"
        fi
        local shortids_array
        IFS=',' read -ra shortids_array <<< "$(echo "$shortids_json" | tr -d '[]"' | sed 's/,/ /g')"
        shortId="${shortids_array[0]:-}"
        uri_params="type=${type_uri}&encryption=${encryption}&flow=${flow}&security=${security_uri}&sni=${sni}&fp=${fingerprint}&sid=${shortId}&pbk=${public_key_base64}&packetEncoding=xudp"
        domain=""
    else
        echo "请选择传输层:"
        echo "[1] TCP (默认)"
        echo "[2] WebSocket + TLS"
        echo "[3] WebSocket (无 TLS)"
        if [ "$NON_INTERACTIVE" != "true" ]; then
            read -p "请输入选项 (1-3, 默认: 1): " transport_choice_input
            if [ -z "$transport_choice_input" ]; then
                transport_choice_input="1"
            fi
        else
            transport_choice_input="1"
        fi
        case "$transport_choice_input" in
            1)
                use_tls=false
                network="tcp"
                type_uri="tcp"
                security_uri="none"
                path=""
                host=""
                server_address="${ip}"
                if [[ "$ip" =~ : ]] && ! [[ "$ip" =~ \[ || "$ip" =~ \] ]]; then
                    server_address="[${ip}]"
                fi
                ;;
            2)
                use_tls=true
                network="ws"
                type_uri="ws"
                security_uri="tls"
                if [ "$NON_INTERACTIVE" != "true" ]; then
                    read -p "输入域名: " domain
                    if [ -z "$domain" ]; then
                        error "域名不能为空。"
                    fi
                    host="$domain"
                    server_address="$domain"
                    log "[?] 输入域名以显示证书路径: $domain"
                    echo "请选择 uTLS Fingerprint (用于伪装):"
                    echo "[1] chrome (默认)"
                    echo "[2] firefox"
                    echo "[3] safari"
                    echo "[4] ios"
                    read -p "请输入选项 (1-4, 默认: 1): " fp_choice_input
                    if [ -z "$fp_choice_input" ]; then
                        fp_choice_input="1"
                    fi
                    case "$fp_choice_input" in
                        1) fingerprint="chrome" ;;
                        2) fingerprint="firefox" ;;
                        3) fingerprint="safari" ;;
                        4) fingerprint="ios" ;;
                        *) fingerprint="chrome" ;;
                    esac
                    log "Fingerprint: $fingerprint"
                    acme_dir="/etc/ssl/acme/$domain"
                    if [ -d "$acme_dir" ]; then
                        log "[✔] 证书路径：$acme_dir"
                        ls -la "$acme_dir" | head -n 5
                        cert_path="$acme_dir/fullchain.pem"
                        key_path="$acme_dir/privkey.key"
                        if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
                            echo -e "${WARN} 证书文件不存在，请手动输入。${NC}"
                            cert_path=""
                        fi
                    else
                        log "未找到 /etc/ssl/acme/$domain"
                        if [ -d "/etc/ssl/acme" ]; then
                            echo "可用证书文件夹："
                            ls -1 /etc/ssl/acme/ | nl -w1 -s') '
                            read -p "选择文件夹编号 (或 0 手动输入): " folder_choice
                            if [[ "$folder_choice" =~ ^[0-9]+$ ]] && [ "$folder_choice" -gt 0 ]; then
                                selected_folder=$(ls -1 /etc/ssl/acme/ | sed -n "${folder_choice}p")
                                if [ -n "$selected_folder" ]; then
                                    acme_dir="/etc/ssl/acme/$selected_folder"
                                    cert_path="$acme_dir/fullchain.pem"
                                    key_path="$acme_dir/privkey.key"
                                    log "[✔] 选择: $acme_dir"
                                fi
                            fi
                        fi
                    fi
                    if [ -z "$cert_path" ] || [ ! -f "$cert_path" ]; then
                        read -p "输入证书路径 (fullchain.pem): " cert_path
                    fi
                    if [ -z "$key_path" ] || [ ! -f "$key_path" ]; then
                        read -p "输入私钥路径 (privkey.key): " key_path
                    fi
                    read -p "WebSocket Path (默认随机生成): " ws_path_input
                    if [ -z "$ws_path_input" ]; then
                        path="/$(generate_random_path)"
                    else
                        path="/$ws_path_input"
                    fi
                    log "Path: $path"
                else
                    error "非交互模式下 WebSocket + TLS 需要域名输入，请手动运行生成配置。"
                fi
                ;;
            3)
                use_tls=false
                network="ws"
                type_uri="ws"
                security_uri="none"
                if [ "$NON_INTERACTIVE" != "true" ]; then
                    read -p "输入 Host (可为域名或 IP, 默认: $ip): " host_input
                    host=${host_input:-$ip}
                    server_address="${ip}"
                    if [[ "$ip" =~ : ]] && ! [[ "$ip" =~ \[ || "$ip" =~ \] ]]; then
                        server_address="[${ip}]"
                    fi
                    read -p "WebSocket Path (默认随机生成): " ws_path_input
                    if [ -z "$ws_path_input" ]; then
                        path="/$(generate_random_path)"
                    else
                        path="/$ws_path_input"
                    fi
                    log "Host: $host"
                    log "Path: $path"
                    domain=""
                else
                    host="$ip"
                    path="/$(generate_random_path)"
                    server_address="${ip}"
                    if [[ "$ip" =~ : ]] && ! [[ "$ip" =~ \[ || "$ip" =~ \] ]]; then
                        server_address="[${ip}]"
                    fi
                    domain=""
                fi
                ;;
            *)
                use_tls=false
                network="tcp"
                type_uri="tcp"
                security_uri="none"
                path=""
                host=""
                server_address="${ip}"
                if [[ "$ip" =~ : ]] && ! [[ "$ip" =~ \[ || "$ip" =~ \] ]]; then
                    server_address="[${ip}]"
                fi
                ;;
        esac
        encoded_tag=$(url_encode "$tag")
        uri_params="type=${type_uri}&encryption=${encryption}&packetEncoding=xudp"
        if [ "$network" = "ws" ]; then
            encoded_path=$(url_encode "$path")
            encoded_host=$(url_encode "$host")
            uri_params="${uri_params}&host=${encoded_host}&path=${encoded_path}"
        fi
        if [ "$use_tls" = true ]; then
            uri_params="${uri_params}&security=${security_uri}&sni=${domain}&fp=${fingerprint}"
        else
            uri_params="${uri_params}&security=none"
        fi
    fi
    encoded_tag=$(url_encode "$tag")
    uri="vless://${uuid}@${server_address}:${port}?${uri_params}#${encoded_tag}"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "是否启用自动推送至远端？ (y/N): " enable_push
        push_enabled=false
        push_url=""
        push_token=""
        if [[ $enable_push =~ ^[Yy]$ ]]; then
            read -p "输入推送 URL (e.g. https://example.workers.dev/push): " push_url
            read -p "输入 token: " push_token
            push_enabled=true
        fi
    else
        push_enabled=false
    fi
    new_node_info=$(generate_node_info "$uuid" "$port" "$decryption" "$encryption" "$ip" "$tag" "$uri" "$domain" "$network" "$path" "$host" "$fingerprint" "$is_custom" "$use_reality" "$dest" "$sni" "$shortids_json" "$public_key_base64" "$flow" "$push_enabled" "$push_url" "$push_token" "$servernames_json" "$private_key" "$kex" "$method" "$rtt" "$use_mlkem")
    if [ "$overwrite" = true ]; then
        echo "[$new_node_info]" > "$VLESS_JSON"
    else
        if [ -f "$VLESS_JSON" ]; then
            temp_json=$(mktemp)
            jq --argjson new "$new_node_info" '. += [$new]' "$VLESS_JSON" > "$temp_json"
            mv "$temp_json" "$VLESS_JSON"
        else
            echo "[$new_node_info]" > "$VLESS_JSON"
        fi
    fi
    regenerate_full_config
    restart_xray 0
    log "配置已应用，Xray 已重启。"
    log "节点信息已保存在 /etc/proxym/vless.json"
    if [ "$push_enabled" = true ]; then
        push_to_remote "$uri" "$push_url" "$push_token"
    fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function print_uri() {
    if [ ! -f "$VLESS_JSON" ]; then
        error "未找到配置信息。请先生成配置。"
    fi
    echo -e "${GREEN}VLESS URIs:${NC}"
    echo -e "${YELLOW}============================${NC}"
    jq -r '.[] | .uri' "$VLESS_JSON" | while read uri; do
        echo "$uri"
    done
    echo -e "${YELLOW}============================${NC}"
    echo -e "${YELLOW}复制以上 URI 用于客户端配置。${NC}"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function check_cron_installed() {
    if ! command -v crontab &> /dev/null; then
        log "Cron 未安装，正在安装..."
        install_dependencies false
        if ! command -v crontab &> /dev/null; then
            error "Cron 安装失败。"
        fi
        log "Cron 已安装。"
    fi
}
function view_cron() {
    check_cron_installed
    echo -e "${YELLOW}当前 Xray 重启 Cron 任务:${NC}"
    if crontab -l 2>/dev/null | grep -q "rc-service xray restart\|systemctl restart xray"; then
        echo -e "${GREEN}已设置自动重启任务:${NC}"
        crontab -l 2>/dev/null | grep "rc-service xray restart\|systemctl restart xray"
    else
        echo -e "${RED}未设置自动重启任务。${NC}"
    fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function set_cron() {
    check_cron_installed
    view_cron
    echo "请选择定时重启方式："
    echo "1. 运行 X 小时后重启 ⏳"
    echo "2. 每天某时间重启 🌞"
    echo "3. 每周某天某时间重启 📅"
    echo "4. 每月某天某时间重启 📆"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "请输入选项 (1-4): " choice
    else
        choice="1" # 默认
        hours=6
    fi
    local init_system=$(detect_init_system)
    local restart_cmd=""
    if [ "$init_system" = "systemd" ]; then
        restart_cmd="/usr/bin/systemctl restart xray"
    elif [ "$init_system" = "openrc" ]; then
        restart_cmd="/sbin/rc-service xray restart"
    else
        error "不支持的 init 系统。"
    fi
    case "$choice" in
        1)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "请输入间隔小时数 (例如 6 表示每 6 小时重启一次): " hours
                if [[ "$hours" =~ ^[0-9]+$ ]] && [ "$hours" -gt 0 ]; then
                    cron_cmd="0 */$hours * * * $restart_cmd"
                else
                    error "无效的小时数。"
                    return
                fi
            else
                cron_cmd="0 */$hours * * * $restart_cmd"
            fi
            ;;
        2)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "请输入每天的小时 (0-23): " h
                read -p "请输入每天的分钟 (0-59): " m
                cron_cmd="$m $h * * * $restart_cmd"
            else
                cron_cmd="0 2 * * * $restart_cmd" # 默认每天2:00
            fi
            ;;
        3)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                echo "周几 (0=周日,1=周一,...,6=周六)"
                read -p "请输入周几: " w
                read -p "请输入小时 (0-23): " h
                read -p "请输入分钟 (0-59): " m
                cron_cmd="$m $h * * $w $restart_cmd"
            else
                cron_cmd="0 2 * * 0 $restart_cmd" # 默认周日2:00
            fi
            ;;
        4)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "请输入每月的日期 (1-31): " d
                read -p "请输入小时 (0-23): " h
                read -p "请输入分钟 (0-59): " m
                cron_cmd="$m $h $d * * $restart_cmd"
            else
                cron_cmd="0 2 1 * * $restart_cmd" # 默认每月1号2:00
            fi
            ;;
        *)
            error "无效选择。"
            return
            ;;
    esac
    (crontab -l 2>/dev/null | grep -v "systemctl restart xray\|rc-service xray restart"; echo "$cron_cmd") | crontab -
    log "Cron 已设置: $cron_cmd"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function delete_cron() {
    check_cron_installed
    (crontab -l 2>/dev/null | grep -v "systemctl restart xray\|rc-service xray restart") | crontab -
    log "Xray 重启 Cron 已删除。"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function view_reset_cron() {
    check_cron_installed
    echo -e "${YELLOW}当前 UUID/密码重置 Cron 任务:${NC}"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH reset"; then
        echo -e "${GREEN}已设置自动重置任务:${NC}"
        crontab -l 2>/dev/null | grep "$SCRIPT_PATH reset"
    else
        echo -e "${RED}未设置自动重置任务。${NC}"
    fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function set_reset_cron() {
    check_cron_installed
    view_reset_cron
    echo "请选择定时重置方式："
    echo "1. 运行 X 小时后重置 ⏳"
    echo "2. 每天某时间重置 🌞"
    echo "3. 每周某天某时间重置 📅"
    echo "4. 每月某天某时间重置 📆"
    echo "5. 每几个月某天某时间重置 📆"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "请输入选项 (1-5): " choice
    else
        choice="1"
        hours=6
    fi
    local reset_cmd="$SCRIPT_PATH reset"
    case "$choice" in
        1)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "请输入间隔小时数 (例如 6 表示每 6 小时重置一次): " hours
                if [[ "$hours" =~ ^[0-9]+$ ]] && [ "$hours" -gt 0 ]; then
                    cron_cmd="0 */$hours * * * $reset_cmd"
                else
                    error "无效的小时数。"
                    return
                fi
            else
                cron_cmd="0 */$hours * * * $reset_cmd"
            fi
            ;;
        2)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "请输入每天的小时 (0-23): " h
                read -p "请输入每天的分钟 (0-59): " m
                cron_cmd="$m $h * * * $reset_cmd"
            else
                cron_cmd="0 3 * * * $reset_cmd"
            fi
            ;;
        3)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                echo "周几 (0=周日,1=周一,...,6=周六)"
                read -p "请输入周几: " w
                read -p "请输入小时 (0-23): " h
                read -p "请输入分钟 (0-59): " m
                cron_cmd="$m $h * * $w $reset_cmd"
            else
                cron_cmd="0 3 * * 0 $reset_cmd"
            fi
            ;;
        4)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "请输入每月的日期 (1-31): " d
                read -p "请输入小时 (0-23): " h
                read -p "请输入分钟 (0-59): " m
                cron_cmd="$m $h $d * * $reset_cmd"
            else
                cron_cmd="0 3 1 * * $reset_cmd"
            fi
            ;;
        5)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "请输入几个月间隔 (例如 3 表示每 3 个月): " months
                read -p "请输入每月的日期 (1-31): " d
                read -p "请输入小时 (0-23): " h
                read -p "请输入分钟 (0-59): " m
                cron_cmd="$m $h $d */$months * $reset_cmd"
            else
                cron_cmd="0 3 1 */3 * $reset_cmd"
            fi
            ;;
        *)
            error "无效选择。"
            return
            ;;
    esac
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH reset") | crontab -
    log "重置 Cron 已设置: $cron_cmd"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function delete_reset_cron() {
    check_cron_installed
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH reset") | crontab -
    log "UUID/密码重置 Cron 已删除。"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function manage_push() {
    if [ ! -f "$VLESS_JSON" ]; then
        error "未找到配置信息。请先生成配置。"
    fi
    echo "节点列表:"
    jq -r '.[] | "端口: \(.port) 标签: \(.tag)"' "$VLESS_JSON" | nl -w1 -s') '
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "选择节点编号 (或 0 取消): " node_choice
        if [ "$node_choice" = "0" ]; then
            return
        fi
    else
        node_choice=1 # 默认第一个
    fi
    local selected_port=$(jq -r ".[$((node_choice-1))].port" "$VLESS_JSON")
    if [ -z "$selected_port" ]; then
        error "无效选择。"
    fi
    local current_enabled=$(jq -r ".[$((node_choice-1))].push_enabled // false" "$VLESS_JSON")
    local current_url=$(jq -r ".[$((node_choice-1))].push_url // \"\"" "$VLESS_JSON")
    local current_token=$(jq -r ".[$((node_choice-1))].push_token // \"\"" "$VLESS_JSON")
    echo "当前推送设置: 启用=$current_enabled, URL=$current_url, Token=$current_token"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "是否启用推送 (y/n, 当前 $current_enabled): " new_enabled
        if [ -n "$new_enabled" ]; then
            if [[ $new_enabled =~ ^[Yy]$ ]]; then
                push_enabled=true
            else
                push_enabled=false
            fi
        else
            push_enabled=$current_enabled
        fi
        if [ "$push_enabled" = true ]; then
            read -p "输入推送 URL (当前 $current_url): " new_url
            push_url=${new_url:-$current_url}
            read -p "输入 token (当前 $current_token): " new_token
            push_token=${new_token:-$current_token}
        else
            push_url=""
            push_token=""
        fi
    else
        push_enabled=$current_enabled
        push_url=$current_url
        push_token=$current_token
    fi
    temp_json=$(mktemp)
    jq ".[$((node_choice-1))].push_enabled = $push_enabled | .[$((node_choice-1))].push_url = \"$push_url\" | .[$((node_choice-1))].push_token = \"$push_token\"" "$VLESS_JSON" > "$temp_json"
    mv "$temp_json" "$VLESS_JSON"
    log "推送设置已更新。"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function manual_push() {
    if [ ! -f "$VLESS_JSON" ]; then
        error "未找到配置信息。请先生成配置。"
    fi
    echo "[1] 推送所有启用节点"
    echo "[2] 推送特定节点"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "选择 (1-2): " push_choice
    else
        push_choice=1
    fi
    case "$push_choice" in
        1)
            local nodes=$(jq -c '.[] | select(.push_enabled == true)' "$VLESS_JSON")
            while IFS= read -r node; do
                local uri=$(echo "$node" | jq -r '.uri')
                local push_url=$(echo "$node" | jq -r '.push_url')
                local push_token=$(echo "$node" | jq -r '.push_token')
                push_to_remote "$uri" "$push_url" "$push_token"
            done <<< "$nodes"
            ;;
        2)
            echo "节点列表:"
            jq -r '.[] | "端口: \(.port) 标签: \(.tag)"' "$VLESS_JSON" | nl -w1 -s') '
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "选择节点编号: " node_choice
            else
                node_choice=1
            fi
            local node=$(jq -c ".[$((node_choice-1))]" "$VLESS_JSON")
            local push_enabled=$(echo "$node" | jq -r '.push_enabled // false')
            if [ "$push_enabled" = false ]; then
                error "该节点未启用推送。"
            fi
            local uri=$(echo "$node" | jq -r '.uri')
            local push_url=$(echo "$node" | jq -r '.push_url')
            local push_token=$(echo "$node" | jq -r '.push_token')
            push_to_remote "$uri" "$push_url" "$push_token"
            ;;
        *)
            error "无效选择。"
            ;;
    esac
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function uninstall() {
    local init_system=$(detect_init_system)
    echo -e "${YELLOW}卸载选项:${NC}"
    echo "[1] 只卸载脚本和配置 (保留 Xray)"
    echo "[2] 卸载 Xray 但保留脚本和配置"
    echo "[3] 卸载全部 (包括 Xray)"
    echo "[0] 取消返回菜单"
    echo -e "${YELLOW}请选择 (0-3): ${NC}"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read uninstall_choice
    else
        uninstall_choice=0 # 默认取消
    fi
    case $uninstall_choice in
        1)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "确定只卸载脚本和配置吗？ (y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    if [ -f "$SCRIPT_PATH" ]; then
                        sudo cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
                        log "脚本备份已创建: ${SCRIPT_PATH}.backup"
                    fi
                    sudo rm -f "$CONFIG" "$VLESS_JSON" "$GLOBAL_JSON"
                    sudo rm -rf /etc/proxym
                    sudo rm -f "$SCRIPT_PATH"
                    log "脚本和配置已卸载（Xray 保留）。"
                    echo -e "${GREEN}如需恢复脚本，从备份复制: sudo cp ${SCRIPT_PATH}.backup $SCRIPT_PATH && sudo chmod +x $SCRIPT_PATH${NC}"
                fi
            fi
            ;;
        2)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "确定卸载 Xray 但保留脚本和配置吗？ (y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    if [ "$init_system" = "systemd" ]; then
                        sudo systemctl stop xray 2>/dev/null || true
                        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove -u root
                    elif [ "$init_system" = "openrc" ]; then
                        sudo rc-service xray stop 2>/dev/null || true
                        curl -L https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh -o /tmp/install-release.sh
                        ash /tmp/install-release.sh remove
                        rm -f /tmp/install-release.sh
                    fi
                    log "Xray 已卸载（脚本和配置保留）。"
                    echo -e "${YELLOW}Xray 已移除。如需重新安装 Xray，请运行 [1] 安装 Xray 选项。${NC}"
                fi
            fi
            ;;
        3)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                read -p "确定卸载全部吗？这将移除 Xray 和所有配置 (y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    if [ "$init_system" = "systemd" ]; then
                        sudo systemctl stop xray 2>/dev/null || true
                        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove -u root
                    elif [ "$init_system" = "openrc" ]; then
                        sudo rc-service xray stop 2>/dev/null || true
                        curl -L https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh -o /tmp/install-release.sh
                        ash /tmp/install-release.sh remove
                        rm -f /tmp/install-release.sh
                    fi
                    sudo rm -f "$CONFIG" "$VLESS_JSON" "$GLOBAL_JSON"
                    sudo rm -rf /etc/proxym
                    sudo rm -f "$SCRIPT_PATH"
                    log "全部已卸载。"
                    echo -e "${YELLOW}Xray 已移除。如需重新安装 Xray，请运行安装脚本。${NC}"
                fi
            fi
            ;;
        0)
            log "取消卸载。"
            ;;
        *)
            echo -e "${RED}无效选项，请重试。${NC}"
            sleep 1
            uninstall
            return
            ;;
    esac
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -p "按 Enter 返回菜单..."
    fi
}
function show_menu() {
    clear
    echo -e "${BLUE}🚀 proxym-easy - VLESS 加密管理器${NC}"
    echo -e "================================"
    echo "[1] 🔧 安装 Xray"
    echo "[2] ⚙️ 生成新配置"
    echo "[3] ▶️ 启动 Xray"
    echo "[4] ⏹️ 停止 Xray"
    echo "[5] 🔄 重启 Xray"
    echo "[6] 📊 查看状态"
    echo "[7] 📝 查看日志"
    echo "[8] 🚀 更新 Xray"
    echo "[9] ⏰ 设置 Cron 重启"
    echo "[10] 👁️ 查看 Cron 任务 (重启)"
    echo "[11] 🗑️ 删除 Cron (重启)"
    echo "[12] 🖨️ 打印 VLESS URI"
    echo "[13] 🔄 更新脚本"
    echo "[14] 🗑️ 卸载"
    echo "[15] 📝 编辑配置"
    echo "[16] 🧪 测试配置"
    echo "[17] 🔄 设置 Cron 重置 UUID/密码"
    echo "[18] 👁️ 查看 Cron 任务 (重置)"
    echo "[19] 🗑️ 删除 Cron (重置)"
    echo "[20] 📤 管理推送设置"
    echo "[21] 📤 手动推送 URI"
    echo "[22] 🔧 修复 Xray 服务限制 (RLIMIT_NOFILE)"
    echo "[23] ❌ 退出"
    echo -e "${YELLOW}请选择选项 (1-23): ${NC}"
    if [ "$NON_INTERACTIVE" != "true" ]; then
        read choice
    else
        choice=23 # 非交互下退出
    fi
    case $choice in
        1) install_xray 1 true ;;
        2) generate_config ;;
        3) start_xray ;;
        4) stop_xray ;;
        5) restart_xray ;;
        6) status_xray ;;
        7) view_logs ;;
        8) update_xray_core ;; # 新增选项
        9) set_cron ;;
        10) view_cron ;;
        11) delete_cron ;;
        12) print_uri ;;
        13) update_script ;;
        14) uninstall ;;
        15) edit_config ;;
        16) test_config ;;
        17) set_reset_cron ;;
        18) view_reset_cron ;;
        19) delete_reset_cron ;;
        20) manage_push ;;
        21) manual_push ;;
        22) fix_xray_service ;;
        23) echo -e "${YELLOW}感谢使用！下次运行: sudo proxym-easy${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重试。${NC}"; sleep 1 ;;
    esac
}
if [ "$EUID" -ne 0 ]; then
    error "请使用 sudo 运行: sudo proxym-easy"
fi
if [ "$1" = "reset" ]; then
    NON_INTERACTIVE=true
    reset_all
    exit 0
fi
while true; do
    show_menu
done
