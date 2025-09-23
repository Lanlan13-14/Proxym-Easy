#!/bin/bash

# proxym-easy - Xray VLESS 加密管理器一键脚本
# 版本: 1.9
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
    [BF]="🇧🇫" [BG]="🇧🇬" [BH]="🇧🇭" [BI]="🇧🇮" [BJ]="🇧🇯"
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
    [VA]="🇻🇦" [VC]="🇻🇨" [VE]="🇻🇪" [VG]="🇻🇬" [VI]="🇻🇮"
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
    local location_info=$(curl -s "https://ipinfo.io/$ip/json" 2>/dev/null)
    if [ -z "$location_info" ]; then
        echo "Unknown"
        return
    fi

    local country=$(echo "$location_info" | grep -o '"country":"[^"]*"' | sed 's/.*"country":"\([^"]*\)".*/\1/')
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
        log "更新成功！已重新加载新脚本。"
        rm -f "${SCRIPT_PATH}.bak"
    else
        rm -f "${SCRIPT_PATH}.new"
        mv "${SCRIPT_PATH}.bak" "$SCRIPT_PATH"
        error "更新语法错误！已回滚到备份。"
    fi
    read -p "按 Enter 返回菜单..."
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
    read -p "端口 (默认: 443): " port_input
    port=${port_input:-443}

    # KEX 选择 (二选一)
    read -p "KEX (x25519/mlkem768x25519plus, 默认: mlkem768x25519plus): " kex_input
    kex_input=${kex_input:-mlkem768x25519plus}
    if [ "$kex_input" = "x25519" ]; then
        kex="x25519"
    else
        kex="mlkem768x25519plus"
    fi

    read -p "方法 (native/xorpub/random, 默认: native): " method_input
    method=${method_input:-native}

    read -p "RTT (0rtt/1rtt, 默认: 0rtt): " rtt_input
    rtt=${rtt_input:-0rtt}

    read -p "时间 (0s/300-600s/600s, 默认: 0s): " time_input
    time=${time_input:-0s}

    # 根据 RTT 调整时间（服务端更新机制：1rtt 为 0s）
    if [ "$rtt" = "1rtt" ]; then
        time="0s"
        log "对于 1-RTT，票据时间设置为 0s。"
    fi

    # 生成密钥
    log "生成密钥..."
    x25519_output=$(xray x25519)
    private=$(echo "$x25519_output" | grep "PrivateKey:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)

    if [ -z "$private" ]; then
        error "X25519 密钥生成失败。请确保 Xray 已安装。"
    fi

    seed=""
    if [ "$kex" = "mlkem768x25519plus" ]; then
        mlkem_output=$(xray mlkem768 2>/dev/null)
        seed=$(echo "$mlkem_output" | grep "Seed:" | cut -d ':' -f2- | sed 's/^ *//;s/ *$//' | xargs)
        if [ -z "$seed" ]; then
            echo -e "${WARN} ML-KEM-768 不支持，回退到 X25519。建议更新 Xray 到 v25.5.16+。${NC}"
            kex="x25519"
        fi
    fi

    if [ "$kex" = "x25519" ]; then
        encryption="${kex}.${method}.${rtt}.${time}.${private}"
    else
        encryption="${kex}.${method}.${rtt}.${time}.${private}.${seed}"
    fi

    # IP
    read -p "服务器 IP (默认: 自动检测): " ip_input
    if [ -z "$ip_input" ]; then
        ip=$(curl -s ifconfig.me)
        if [ -z "$ip" ]; then
            error "IP 检测失败。请手动输入。"
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

    # 保存 URI 信息
    cat > "$VLESS_INFO" << EOF
UUID=$uuid
PORT=$port
ENCRYPTION=$encryption
IP=$ip
TAG=$tag
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
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
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

    source "$VLESS_INFO"
    uri="vless://${UUID}@${IP}:${PORT}?type=tcp&encryption=${ENCRYPTION}&security=none#${TAG}"
    echo -e "${GREEN}$uri${NC}"
    echo -e "${YELLOW}复制此 URI 用于客户端。${NC}"
    read -p "按 Enter 返回菜单..."
}

function set_cron() {
    read -p "Cron 调度 (例如 '0 2 * * *' 表示每天凌晨 2 点): " schedule
    if [ -z "$schedule" ]; then
        error "无效调度。"
    fi
    cron_cmd="$schedule /usr/bin/systemctl restart xray"
    (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
    log "Cron 已设置: $cron_cmd"
    read -p "按 Enter 返回菜单..."
}

function delete_cron() {
    crontab -l | grep -v "systemctl restart xray" | crontab -
    log "Xray 重启 Cron 已删除。"
    read -p "按 Enter 返回菜单..."
}

function uninstall() {
    read -p "确定吗？这将移除 Xray 和配置 (y/N): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        sudo systemctl stop xray
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove -u root
        sudo rm -f "$CONFIG" "$VLESS_INFO"
        sudo rm -rf /etc/proxym
        log "已卸载。"
    fi
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