#!/bin/bash

# proxym-easy - Xray VLESS Encryption一键脚本
# 版本: 3.0
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
SCRIPT_PATH="/usr/local/bin/proxym-easy"
UPDATE_URL="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/vless-encryption.sh"  # 更新 URL
CRON_FILE="/tmp/proxym_cron.tmp"

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
        python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''), end='')" <<< "$1"
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
    # 添加超时机制：10 秒超时，避免 curl 卡住
    local location_info=$(curl -s --max-time 10 "http://ip-api.com/json/$ip?fields=status,message,countryCode,city" 2>/dev/null)
    if echo "$location_info" | grep -q '"status":"fail"'; then
        echo "Unknown"
        return
    fi

    local country=$(echo "$location_info" | grep -o '"countryCode":"[^"]*"' | sed 's/.*"countryCode":"\([^"]*\)".*/\1/')
    local city=$(echo "$location_info" | grep -o '"city":"[^"]*"' | sed 's/.*"city":"\([^"]*\)".*/\1/')

    if [ -z "$country" ] || [ -z "$city" ]; then
        echo "Unknown"
        return
    fi

    local flag="${FLAGS[$country]:-🌍}"
    echo "${flag} ${city}"
}

function update_script() {
    log "检查更新..."
    if [ ! -f "$SCRIPT_PATH" ]; then
        error "脚本未在 $SCRIPT_PATH 找到"
    fi

    # 备份当前脚本
    cp "$SCRIPT_PATH" "${SCRIPT_PATH}.bak"
    log "备份已创建: ${SCRIPT_PATH}.bak"

    # 下载新版本
    if ! curl -s -o "${SCRIPT_PATH}.new" "$UPDATE_URL"; then
        error "从 $UPDATE_URL 下载更新失败"
    fi

    # 检查语法
    if bash -n "${SCRIPT_PATH}.new" 2>/dev/null; then
        mv "${SCRIPT_PATH}.new" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        log "更新成功！"
        rm -f "${SCRIPT_PATH}.bak"
        # 直接 exec 新脚本
        exec bash "$SCRIPT_PATH"
    else
        rm -f "${SCRIPT_PATH}.new"
        mv "${SCRIPT_PATH}.bak" "$SCRIPT_PATH"
        error "更新语法错误！已回滚到备份。"
    fi
}

function install_dependencies() {
    local force_update=${1:-false}
    if [ "$force_update" = true ]; then
        log "安装 Xray 依赖..."
        if command -v apt &> /dev/null; then
            # Debian/Ubuntu
            sudo apt update
            sudo apt install -y curl unzip ca-certificates wget gnupg lsb-release python3 cron jq
            log "Debian/Ubuntu 依赖安装完成。"
        elif command -v yum &> /dev/null; then
            # CentOS/RHEL
            sudo yum update -y
            sudo yum install -y curl unzip ca-certificates wget gnupg python3 cronie jq
            log "CentOS/RHEL 依赖安装完成。"
        elif command -v dnf &> /dev/null; then
            # Fedora
            sudo dnf update -y
            sudo dnf install -y curl unzip ca-certificates wget gnupg python3 cronie jq
            log "Fedora 依赖安装完成。"
        else
            echo -e "${WARN} 未检测到包管理器，请手动安装 curl、unzip、ca-certificates、python3、cron、jq。${NC}"
        fi
    else
        # 只检查并安装缺少的依赖，不 update
        local deps=("curl" "unzip" "ca-certificates" "wget" "gnupg" "python3" "cron" "jq")
        local missing_deps=()
        for dep in "${deps[@]}"; do
            if ! command -v "$dep" &> /dev/null; then
                missing_deps+=("$dep")
            fi
        done
        if [ ${#missing_deps[@]} -gt 0 ]; then
            log "检测到缺少依赖: ${missing_deps[*]}，正在安装..."
            if command -v apt &> /dev/null; then
                sudo apt update
                sudo apt install -y "${missing_deps[@]}"
                log "Debian/Ubuntu 依赖安装完成。"
            elif command -v yum &> /dev/null; then
                sudo yum install -y "${missing_deps[@]}"
                log "CentOS/RHEL 依赖安装完成。"
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y "${missing_deps[@]}"
                log "Fedora 依赖安装完成。"
            else
                echo -e "${WARN} 未检测到包管理器，请手动安装缺少的依赖: ${missing_deps[*]}。${NC}"
            fi
        fi
    fi
}

function install_xray() {
    local pause=${1:-1}
    local force_deps=${2:-false}
    if command -v xray &> /dev/null; then
        log "Xray 已安装。"
        if [ $pause -eq 1 ]; then
            read -p "按 Enter 返回菜单..."
        fi
        return 0
    else
        install_dependencies "$force_deps"  # 安装依赖，如果 force_deps=true 则 update
        log "安装 Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
        if [ $? -eq 0 ]; then
            log "Xray 安装成功。"
        else
            error "Xray 安装失败。"
        fi
        if [ $pause -eq 1 ]; then
            read -p "按 Enter 返回菜单..."
        fi
    fi
}

function start_xray() {
    sudo systemctl start xray
    log "Xray 已启动。"
    read -p "按 Enter 返回菜单..."
}

function stop_xray() {
    sudo systemctl stop xray
    log "Xray 已停止。"
    read -p "按 Enter 返回菜单..."
}

function restart_xray() {
    sudo systemctl restart xray
    log "Xray 已重启。"
    read -p "按 Enter 返回菜单..."
}

function status_xray() {
    sudo systemctl status xray --no-pager
    read -p "按 Enter 返回菜单..."
}

function view_logs() {
    sudo journalctl -u xray -f --no-pager
    # 对于跟随日志，按 Ctrl+C 退出后返回
    read -p "按 Enter 返回菜单..."
}

function edit_config() {
    if [ ! -f "$CONFIG" ]; then
        error "配置文件不存在。请先生成配置。"
    fi
    sudo vim "$CONFIG"
    log "编辑完成。"
    read -p "按 Enter 返回菜单..."
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
    read -p "按 Enter 返回菜单..."
}

function generate_config() {
    install_xray 0 false  # 确保已安装，但不暂停，且不 force update 依赖

    # 确保 Xray 配置目录存在
    sudo mkdir -p /usr/local/etc/xray

    log "生成新的 VLESS 配置..."
    echo -e "${YELLOW}按 Enter 使用默认值。${NC}"

    # 检查现有配置
    if [ ! -f "$CONFIG" ]; then
        overwrite=true
    else
        read -p "配置文件已存在。覆盖 (Y) 还是附加节点 (N)? (默认 Y): " overwrite_choice
        if [[ ! "$overwrite_choice" =~ ^[Nn]$ ]]; then
            overwrite=true
        else
            overwrite=false
            log "附加模式：仅更新节点相关内容。"
        fi
    fi

    # UUID
    read -p "UUID (默认: 新生成): " uuid_input
    if [ -z "$uuid_input" ]; then
        uuid=$(xray uuid)
    else
        uuid="$uuid_input"
    fi
    log "UUID: $uuid"

    # KEX 选择 (菜单) - 先 VLESS Encryption
    echo "请选择 KEX:"
    echo "[1] x25519"
    echo "[2] mlkem768x25519plus (默认)"
    read -p "请输入选项 (1-2, 默认: 2): " kex_choice_input
    if [ -z "$kex_choice_input" ]; then
        kex_choice_input="2"
    fi
    case "$kex_choice_input" in
        1) kex="x25519"; use_mlkem=false ;;
        2) kex="mlkem768x25519plus"; use_mlkem=true ;;
        *) kex="mlkem768x25519plus"; use_mlkem=true ;;
    esac
    log "KEX: $kex"

    # 方法选择 (菜单，默认 random)
    echo "请选择方法:"
    echo "[1] native"
    echo "[2] xorpub"
    echo "[3] random (默认)"
    read -p "请输入选项 (1-3, 默认: 3): " method_choice_input
    if [ -z "$method_choice_input" ]; then
        method_choice_input="3"
    fi
    case "$method_choice_input" in
        1) method="native" ;;
        2) method="xorpub" ;;
        3) method="random" ;;
        *) method="random" ;;
    esac
    log "方法: $method"

    # RTT 选择 (菜单)
    echo "请选择 RTT:"
    echo "[1] 0rtt (默认)"
    echo "[2] 1rtt"
    read -p "请输入选项 (1-2, 默认: 1): " rtt_choice_input
    if [ -z "$rtt_choice_input" ]; then
        rtt_choice_input="1"
    fi
    case "$rtt_choice_input" in
        1) rtt="0rtt" ;;
        2) rtt="1rtt" ;;
        *) rtt="0rtt" ;;
    esac
    log "RTT: $rtt"

    # 根据 RTT 设置服务端 time
    if [ "$rtt" = "0rtt" ]; then
        time_server="600s"
    else
        time_server="0s"
    fi

    # 生成 x25519 密钥
    log "生成 X25519 密钥..."
    x25519_output=$(xray x25519)
    private=$(echo "$x25519_output" | grep "PrivateKey:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
    password=$(echo "$x25519_output" | grep "Password:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)

    if [ -z "$private" ] || [ -z "$password" ]; then
        error "X25519 密钥生成失败。请确保 Xray 已安装。"
    fi

    # 生成 MLKEM 如果选择
    seed=""
    client_param=""
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

    # 构建服务端 decryption 和客户端 encryption (默认)
    decryption="${kex}.${method}.${time_server}.${private}"
    if [ "$use_mlkem" = true ]; then
        decryption="${decryption}.${seed}"
    fi

    encryption="${kex}.${method}.${rtt}.${password}"
    if [ "$use_mlkem" = true ]; then
        encryption="${encryption}.${client_param}"
    fi

    # REALITY 选择 - 后 VLESS Encryption
    echo "是否启用 REALITY (Xray 官方推荐用于 TCP):"
    echo "[1] 是 (仅支持 TCP)"
    echo "[2] 否 (支持 TCP 或 WebSocket + TLS)"
    read -p "请输入选项 (1-2, 默认: 2): " reality_choice_input
    if [ -z "$reality_choice_input" ]; then
        reality_choice_input="2"
    fi
    case "$reality_choice_input" in
        1) use_reality=true ;;
        *) use_reality=false ;;
    esac
    log "启用 REALITY: $( [ "$use_reality" = true ] && echo "是" || echo "否" )"

    if [ "$use_reality" = true ]; then
        # 对于 REALITY，重设 decryption 和 encryption 为 none
        decryption="none"
        encryption="none"
        flow="xtls-rprx-vision"
        log "REALITY 模式下 VLESS Encryption 设置为 none"
        read -p "REALITY 伪装目标 dest (默认: www.cloudflare.com:443): " dest_input
        dest=${dest_input:-"www.cloudflare.com:443"}
        read -p "serverNames (逗号分隔 SNI 列表, 默认: www.cloudflare.com): " servernames_input
        if [ -z "$servernames_input" ]; then
            servernames_input="www.cloudflare.com"
        fi
        IFS=',' read -ra servernames_array <<< "$servernames_input"
        sni="${servernames_array[0]}"
        read -p "shortIds (逗号分隔, 每个 0-16 hex 字符, 默认随机生成一个): " shortids_input
        if [ -z "$shortids_input" ]; then
            shortid=$(openssl rand -hex 4 2>/dev/null || echo "a1b2c3d4")
            shortids_input="$shortid"
        fi
        IFS=',' read -ra shortids <<< "$shortids_input"
        shortId="${shortids[0]}"

        # uTLS fingerprint for REALITY
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
        public_key_base64="$password"  # 使用 x25519 的 password 作为 pbk
    else
        fingerprint="chrome"  # 默认
    fi

    echo "vless reality推荐端口为443"
    # 端口
    default_port=8443
    if [ "$use_reality" = true ]; then
        default_port=443
    fi
    read -p "端口 (默认: $default_port): " port_input
    port=${port_input:-$default_port}
    log "端口: $port"

    # IP - 修改：优先 IPv4，fallback IPv6
    read -p "服务器 IP (默认: 自动检测): " ip_input
    if [ -z "$ip_input" ]; then
        # 优先尝试 IPv4
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

    # 自动获取标签基于IP
    log "根据 IP $ip 获取地理位置..."
    tag=$(get_location_from_ip "$ip")
    if [ "$tag" = "Unknown" ]; then
        read -p "无法获取位置，请手动输入标签 (默认: Unknown): " tag_input
        tag=${tag_input:-Unknown}
    fi
    log "标签: $tag"

    # DNS
    read -p "DNS 服务器 (默认: 8.8.8.8): " dns_server_input
    dns_server=${dns_server_input:-8.8.8.8}

    # 查询策略选择 (菜单)
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

    # 出站域名策略选择 (菜单)
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

    # 传输层选择
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
        uri_params="type=${type_uri}&encryption=${encryption}&flow=${flow}&security=${security_uri}&sni=${sni}&fp=${fingerprint}&sid=${shortId}&pbk=${public_key_base64}&packetEncoding=xudp"
        domain=""
    else
        echo "请选择传输层:"
        echo "[1] TCP (默认)"
        echo "[2] WebSocket + TLS"
        read -p "请输入选项 (1-2, 默认: 1): " transport_choice_input
        if [ -z "$transport_choice_input" ]; then
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
                read -p "输入域名: " domain
                if [ -z "$domain" ]; then
                    error "域名不能为空。"
                fi
                host="$domain"
                server_address="$domain"
                log "[?] 输入域名以显示证书路径: $domain"

                # uTLS fingerprint for TLS
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
        # URL 编码标签
        encoded_tag=$(url_encode "$tag")

        # 构建 URI 参数
        uri_params="type=${type_uri}&encryption=${encryption}&packetEncoding=xudp"
        if [ "$use_tls" = true ]; then
            uri_params="${uri_params}&security=${security_uri}&sni=${domain}&fp=${fingerprint}"
            if [ "$network" = "ws" ]; then
                encoded_path=$(url_encode "$path")
                uri_params="${uri_params}&host=${host}&path=${encoded_path}"
            fi
        else
            uri_params="${uri_params}&security=none"
        fi
    fi
    encoded_tag=$(url_encode "$tag")
    uri="vless://${uuid}@${server_address}:${port}?${uri_params}#${encoded_tag}"

    # 准备新节点信息 JSON
    if [ "$use_reality" = true ]; then
        servernames_json=$(IFS=','; echo "[\"${servernames_array[*]}\"]")
        shortids_json=$(IFS=','; echo "[\"${shortids[*]}\"]")
        new_node_info=$(cat << EOF
{
  "uuid": "$uuid",
  "port": $port,
  "decryption": "$decryption",
  "encryption": "$encryption",
  "ip": "$ip",
  "tag": "$tag",
  "uri": "$uri",
  "domain": "",
  "network": "$network",
  "path": "$path",
  "use_reality": true,
  "dest": "$dest",
  "sni": "$sni",
  "shortIds": $shortids_json,
  "public_key": "$public_key_base64",
  "flow": "$flow",
  "fingerprint": "$fingerprint"
}
EOF
)
    else
        new_node_info=$(cat << EOF
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
  "fingerprint": "$fingerprint"
}
EOF
)
    fi

    # 更新 vless.json
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

    # 准备 streamSettings JSON
    if [ "$use_reality" = true ]; then
        servernames_json=$(IFS=','; echo "[\"${servernames_array[*]}\"]")
        shortids_json=$(IFS=','; echo "[\"${shortids[*]}\"]")
        stream_settings='{
          "network": "tcp",
          "security": "reality",
          "realitySettings": {
            "dest": "'"$dest"'",
            "serverNames": '"$servernames_json"',
            "privateKey": "'"$private"'",
            "shortIds": '"$shortids_json"',
            "fingerprint": "'"$fingerprint"'"
          }
        }'
        client_flow='{"id":"'"$uuid"'","flow":"'"$flow"'"}'
    else
        if [ "$use_tls" = true ]; then
            tls_settings='{
              "certificates": [
                {
                  "certificateFile": "'"$cert_path"'",
                  "keyFile": "'"$key_path"'"
                }
              ],
              "fingerprint": "'"$fingerprint"'"
            }'
            ws_settings='{
              "path": "'"$path"'",
              "headers": {
                "Host": "'"$host"'"
              }
            }'
            stream_settings='{
              "network": "'"$network"'",
              "security": "tls",
              "tlsSettings": '"$tls_settings"',
              "wsSettings": '"$ws_settings"'
            }'
        else
            stream_settings='{"network": "'"$network"'"}'
        fi
        client_flow='{"id":"'"$uuid"'"}'
    fi

    new_inbounds='[
      {
        "port": '"$port"',
        "protocol": "vless",
        "settings": {
          "clients": [
            '"$client_flow"'
          ],
          "decryption": "'"$decryption"'"
        },
        "streamSettings": '"$stream_settings"'
      }
    ]'

    if [ "$overwrite" = true ]; then
        # 覆盖整个配置
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
  "inbounds": $new_inbounds,
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
    else
        # 附加：使用 jq 追加到 inbounds
        if ! jq . "$CONFIG" > /dev/null 2>&1; then
            error "现有配置不是有效 JSON，无法附加。"
        fi
        temp_config=$(mktemp)
        jq --argjson inbounds "$new_inbounds" '.inbounds += $inbounds' "$CONFIG" > "$temp_config"
        mv "$temp_config" "$CONFIG"
        log "节点配置已附加到现有配置文件。"
    fi

    # 测试配置
    if xray -test -config "$CONFIG" &> /dev/null; then
        log "配置有效！"
        restart_xray
        log "配置已应用，Xray 已重启。"
        log "VLESS URI 已生成并保存。"
        log "节点信息已保存在 /etc/proxym/vless.json"
    else
        error "配置测试失败！"
    fi
    read -p "按 Enter 返回菜单..."
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
    read -p "按 Enter 返回菜单..."
}

function check_cron_installed() {
    if ! command -v crontab &> /dev/null; then
        log "Cron 未安装，正在安装..."
        install_dependencies false  # 不 force update
        if ! command -v crontab &> /dev/null; then
            error "Cron 安装失败。"
        fi
        log "Cron 已安装。"
    fi
}

function view_cron() {
    check_cron_installed
    echo -e "${YELLOW}当前 Xray 重启 Cron 任务:${NC}"
    if crontab -l 2>/dev/null | grep -q "systemctl restart xray"; then
        echo -e "${GREEN}已设置自动重启任务:${NC}"
        crontab -l 2>/dev/null | grep "systemctl restart xray"
    else
        echo -e "${RED}未设置自动重启任务。${NC}"
    fi
    read -p "按 Enter 返回菜单..."
}

function set_cron() {
    check_cron_installed
    view_cron  # 先显示当前状态
    echo "请选择定时重启方式："
    echo "1. 运行 X 小时后重启 ⏳"
    echo "2. 每天某时间重启 🌞"
    echo "3. 每周某天某时间重启 📅"
    echo "4. 每月某天某时间重启 📆"
    read -p "请输入选项 (1-4): " choice

    case "$choice" in
        1)
            read -p "请输入间隔小时数 (例如 6 表示每 6 小时重启一次): " hours
            if [[ "$hours" =~ ^[0-9]+$ ]] && [ "$hours" -gt 0 ]; then
                cron_cmd="0 */$hours * * * /usr/bin/systemctl restart xray"
            else
                error "无效的小时数。"
                return
            fi
            ;;
        2)
            read -p "请输入每天的小时 (0-23): " h
            read -p "请输入每天的分钟 (0-59): " m
            cron_cmd="$m $h * * * /usr/bin/systemctl restart xray"
            ;;
        3)
            echo "周几 (0=周日,1=周一,...,6=周六)"
            read -p "请输入周几: " w
            read -p "请输入小时 (0-23): " h
            read -p "请输入分钟 (0-59): " m
            cron_cmd="$m $h * * $w /usr/bin/systemctl restart xray"
            ;;
        4)
            read -p "请输入每月的日期 (1-31): " d
            read -p "请输入小时 (0-23): " h
            read -p "请输入分钟 (0-59): " m
            cron_cmd="$m $h $d * * /usr/bin/systemctl restart xray"
            ;;
        *)
            error "无效选择。"
            return
            ;;
    esac

    # 设置 cron
    (crontab -l 2>/dev/null | grep -v "systemctl restart xray"; echo "$cron_cmd") | crontab -
    log "Cron 已设置: $cron_cmd"
    read -p "按 Enter 返回菜单..."
}

function delete_cron() {
    check_cron_installed
    (crontab -l 2>/dev/null | grep -v "systemctl restart xray") | crontab -
    log "Xray 重启 Cron 已删除。"
    read -p "按 Enter 返回菜单..."
}

function uninstall() {
    echo -e "${YELLOW}卸载选项:${NC}"
    echo "[1] 只卸载脚本和配置 (保留 Xray)"
    echo "[2] 卸载 Xray 但保留脚本和配置"
    echo "[3] 卸载全部 (包括 Xray)"
    echo "[0] 取消返回菜单"
    echo -e "${YELLOW}请选择 (0-3): ${NC}"
    read uninstall_choice

    case $uninstall_choice in
        1)
            read -p "确定只卸载脚本和配置吗？ (y/N): " confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                # 备份脚本（可选）
                if [ -f "$SCRIPT_PATH" ]; then
                    sudo cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
                    log "脚本备份已创建: ${SCRIPT_PATH}.backup"
                fi
                # 移除配置和目录
                sudo rm -f "$CONFIG" "$VLESS_JSON"
                sudo rm -rf /etc/proxym
                sudo rm -f "$SCRIPT_PATH"
                log "脚本和配置已卸载（Xray 保留）。"
                echo -e "${GREEN}如需恢复脚本，从备份复制: sudo cp ${SCRIPT_PATH}.backup $SCRIPT_PATH && sudo chmod +x $SCRIPT_PATH${NC}"
            fi
            ;;
        2)
            read -p "确定卸载 Xray 但保留脚本和配置吗？ (y/N): " confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                # 停止 Xray
                sudo systemctl stop xray 2>/dev/null || true
                # 移除 Xray
                bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove -u root
                # 保留配置、目录和脚本
                log "Xray 已卸载（脚本和配置保留）。"
                echo -e "${YELLOW}Xray 已移除。如需重新安装 Xray，请运行 [1] 安装 Xray 选项。${NC}"
            fi
            ;;
        3)
            read -p "确定卸载全部吗？这将移除 Xray 和所有配置 (y/N): " confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                sudo systemctl stop xray 2>/dev/null || true
                bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove -u root
                # 移除配置和目录
                sudo rm -f "$CONFIG" "$VLESS_JSON"
                sudo rm -rf /etc/proxym
                sudo rm -f "$SCRIPT_PATH"
                log "全部已卸载。"
                echo -e "${YELLOW}Xray 已移除。如需重新安装 Xray，请运行安装脚本。${NC}"
            fi
            ;;
        0)
            log "取消卸载。"
            ;;
        *)
            echo -e "${RED}无效选项，请重试。${NC}"
            sleep 1
            uninstall  # 递归调用以重试
            return
            ;;
    esac
    read -p "按 Enter 返回菜单..."
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
    echo "[8] ⏰ 设置 Cron 重启"
    echo "[9] 👁️  查看 Cron 任务"
    echo "[10] 🗑️ 删除 Cron"
    echo "[11] 🖨️ 打印 VLESS URI"
    echo "[12] 🔄 更新脚本"
    echo "[13] 🗑️ 卸载"
    echo "[14] 📝 编辑配置"
    echo "[15] 🧪 测试配置"
    echo "[16] ❌ 退出"
    echo -e "${YELLOW}请选择选项 (1-16): ${NC}"
    read choice
    case $choice in
        1) install_xray 1 true ;;  # 安装 Xray 时 force update 依赖
        2) generate_config ;;
        3) start_xray ;;
        4) stop_xray ;;
        5) restart_xray ;;
        6) status_xray ;;
        7) view_logs ;;
        8) set_cron ;;
        9) view_cron ;;
        10) delete_cron ;;
        11) print_uri ;;
        12) update_script ;;
        13) uninstall ;;
        14) edit_config ;;
        15) test_config ;;
        16) echo -e "${YELLOW}感谢使用！下次运行: sudo proxym-easy${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重试。${NC}"; sleep 1 ;;
    esac
}

# 主程序
if [ "$EUID" -ne 0 ]; then
    error "请使用 sudo 运行: sudo proxym-easy"
fi

while true; do
    show_menu
done