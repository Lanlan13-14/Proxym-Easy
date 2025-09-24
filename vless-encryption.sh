#!/bin/bash

# proxym-easy - Xray VLESS Encryption一键脚本
# 版本: 2.7
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
VLESS_INFO="/etc/proxym/vless.info"
SCRIPT_PATH="/usr/local/bin/proxym-easy"
UPDATE_URL="https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/vless-encryption.sh"  # 更新 URL
CRON_FILE="/tmp/proxym_cron.tmp"

# 国家代码到国旗的完整映射（基于 ISO 3166-1 alpha-2）
declare -A FLAGS=(
    [AD]="🇦🇩" [AE]="🇦🇪" [AF]="🇦🇫" [AG]="🇦🇬" [AI]="🇦🇮"
    [AL]="🇦🇱" [AM]="🇦🇲" [AO]="🇦🇴" [AQ]="🇦🇶" [AR]="🇦🇷"
    [AS]="🇦🇸" [AT]="🇦🇹" [AU]="🇦🇺" [AW]="🇦🇼" [AX]="🇦🇽"
    [AZ]="🇦🇿" [BA]="🇧🇦" [BB]="🇧🇧" [BD]="🇧🇩" [BE]="🇧🇪"
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
    log "安装 Xray 依赖..."
    if command -v apt &> /dev/null; then
        # Debian/Ubuntu
        sudo apt update
        sudo apt install -y curl unzip ca-certificates wget gnupg lsb-release
        log "Debian/Ubuntu 依赖安装完成。"
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL
        sudo yum update -y
        sudo yum install -y curl unzip ca-certificates wget gnupg
        log "CentOS/RHEL 依赖安装完成。"
    elif command -v dnf &> /dev/null; then
        # Fedora
        sudo dnf update -y
        sudo dnf install -y curl unzip ca-certificates wget gnupg
        log "Fedora 依赖安装完成。"
    else
        echo -e "${WARN} 未检测到包管理器，请手动安装 curl、unzip、ca-certificates。${NC}"
    fi
}

function install_xray() {
    local pause=${1:-1}
    if command -v xray &> /dev/null; then
        log "Xray 已安装。"
        if [ $pause -eq 1 ]; then
            read -p "按 Enter 返回菜单..."
        fi
        return 0
    else
        install_dependencies  # 安装依赖
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
    install_xray 0  # 确保已安装，但不暂停

    log "生成新的 VLESS 配置..."
    echo -e "${YELLOW}按 Enter 使用默认值。${NC}"

    # UUID
    read -p "UUID (默认: 新生成): " uuid_input
    if [ -z "$uuid_input" ]; then
        uuid=$(xray uuid)
    else
        uuid="$uuid_input"
    fi
    log "UUID: $uuid"

    # 端口
    read -p "端口 (默认: 8443): " port_input
    port=${port_input:-8443}

    # KEX 选择 (二选一)
    read -p "KEX (x25519/mlkem768x25519plus, 默认: mlkem768x25519plus): " kex_choice
    kex_choice=${kex_choice:-mlkem768x25519plus}
    if [ "$kex_choice" = "x25519" ]; then
        kex="x25519"
        use_mlkem=false
    else
        kex="mlkem768x25519plus"
        use_mlkem=true
    fi

    read -p "方法 (native/xorpub/random, 默认: native): " method_input
    method=${method_input:-native}

    read -p "RTT (0rtt/1rtt, 默认: 0rtt): " rtt_input
    rtt=${rtt_input:-0rtt}

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

    # 构建服务端 decryption
    decryption="${kex}.${method}.${time_server}.${private}"
    if [ "$use_mlkem" = true ]; then
        decryption="${decryption}.${seed}"
    fi

    # 构建客户端 encryption
    encryption="${kex}.${method}.${rtt}.${password}"
    if [ "$use_mlkem" = true ]; then
        encryption="${encryption}.${client_param}"
    fi

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

    read -p "查询策略 (UseIPv4/UseIPv6/UseIP/AsIs, 默认: UseIPv4): " strategy_input
    strategy=${strategy_input:-UseIPv4}

    # 出站域名策略
    read -p "出站域名策略 (UseIPv4v6/UseIPv6v4/ForceIPv4/ForceIPv6, 默认: UseIPv4v6): " domain_strategy_input
    domain_strategy=${domain_strategy_input:-UseIPv4v6}

    # URI 构建 - 修改：IPv6 加 []
    host="${ip}"
    if [[ "$ip" =~ : ]] && ! [[ "$ip" =~ \[ || "$ip" =~ \] ]]; then  # 检测 IPv6 (含: 且无 [])，包围
        host="[${ip}]"
        log "IPv6 检测到，已在 URI 中添加 [] 包围。"
    fi
    uri="vless://${uuid}@${host}:${port}?type=tcp&encryption=${encryption}&packetEncoding=xudp&security=none#${tag}"

    # 保存所有信息，包括URI
    cat > "$VLESS_INFO" << EOF
UUID="$uuid"
PORT="$port"
DECRYPTION="$decryption"
ENCRYPTION="$encryption"
IP="$ip"
TAG="$tag"
URI="$uri"
EOF

    # 生成 config.json
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
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid"
          }
        ],
        "decryption": "$decryption"
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
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

    # 测试配置
    if xray -test -config "$CONFIG" &> /dev/null; then
        log "配置有效！"
        restart_xray
        log "配置已应用，Xray 已重启。"
        log "VLESS URI 已生成并保存。"
    else
        error "配置测试失败！"
    fi
    read -p "按 Enter 返回菜单..."
}

function print_uri() {
    if [ ! -f "$VLESS_INFO" ]; then
        error "未找到配置信息。请先生成配置。"
    fi

    # 安全 source，确保变量正确加载
    URI=""
    source "$VLESS_INFO" 2>/dev/null || error "加载配置信息失败，请重新生成配置。"

    echo -e "${GREEN}VLESS URI:${NC}"
    echo -e "${YELLOW}============================${NC}"
    echo "$URI"
    echo -e "${YELLOW}============================${NC}"
    echo -e "${YELLOW}复制以上 URI 用于客户端配置。${NC}"
    read -p "按 Enter 返回菜单..."
}

function set_cron() {
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
                sudo rm -f "$CONFIG" "$VLESS_INFO"
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
                sudo rm -f "$CONFIG" "$VLESS_INFO"
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
    echo "[9] 🗑️ 删除 Cron"
    echo "[10] 🖨️ 打印 VLESS URI"
    echo "[11] 🔄 更新脚本"
    echo "[12] 🗑️ 卸载"
    echo "[13] 📝 编辑配置"
    echo "[14] 🧪 测试配置"
    echo "[15] ❌ 退出"
    echo -e "${YELLOW}请选择选项 (1-15): ${NC}"
    read choice
    case $choice in
        1) install_xray 1 ;;
        2) generate_config ;;
        3) start_xray ;;
        4) stop_xray ;;
        5) restart_xray ;;
        6) status_xray ;;
        7) view_logs ;;
        8) set_cron ;;
        9) delete_cron ;;
        10) print_uri ;;
        11) update_script ;;
        12) uninstall ;;
        13) edit_config ;;
        14) test_config ;;
        15) echo -e "${YELLOW}感谢使用！下次运行: sudo proxym-easy${NC}"; exit 0 ;;
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