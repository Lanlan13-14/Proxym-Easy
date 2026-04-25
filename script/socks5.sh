#!/bin/bash

CONF_DIR="/etc/xray/conf.d"
mkdir -p "$CONF_DIR"

# =========================
# 依赖检测与自动安装
# =========================
PKGS_COMMON=(jq curl openssl vim)
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

install_with_pkgmgr() {
    local mgr="$1"; shift
    local pkgs=("$@")
    case "$mgr" in
        apt)
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
            ;;
        yum)
            yum install -y "${pkgs[@]}"
            ;;
        dnf)
            dnf install -y "${pkgs[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm "${pkgs[@]}"
            ;;
        apk)
            apk add --no-cache "${pkgs[@]}"
            ;;
        zypper)
            zypper --non-interactive install -y "${pkgs[@]}"
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_command() {
    local cmd="$1"
    local pkg_hint="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    mgr=$(detect_pkg_manager)
    if [[ "$mgr" == "unknown" ]]; then
        echo "无法检测到受支持的包管理器，请手动安装: $pkg_hint 或 命令 $cmd" >&2
        return 1
    fi

    declare -a to_install=()
    case "$cmd" in
        jq) to_install=(jq) ;;
        curl) to_install=(curl) ;;
        openssl) to_install=(openssl) ;;
        vim) to_install=(vim) ;;
        *)
            if [[ -n "$pkg_hint" ]]; then
                to_install=("$pkg_hint")
            else
                echo "未知命令 $cmd，无法自动安装" >&2
                return 1
            fi
            ;;
    esac

    echo "检测到缺少命令: $cmd，尝试使用 $mgr 自动安装: ${to_install[*]}"
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            echo "当前非 root 且系统无 sudo，无法自动安装 $cmd，请以 root 身份运行脚本或安装依赖" >&2
            return 1
        fi
    else
        SUDO=""
    fi

    if ! $SUDO bash -c "install_with_pkgmgr \"$mgr\" ${to_install[*]}" 2>/dev/null; then
        echo "自动安装失败，请手动安装: ${to_install[*]}" >&2
        return 1
    fi

    if command -v "$cmd" >/dev/null 2>&1; then
        echo "安装成功: $cmd"
        return 0
    else
        echo "安装后仍未找到 $cmd，请手动检查" >&2
        return 1
    fi
}

auto_install_deps() {
    local cmds=(jq curl openssl vim)
    for c in "${cmds[@]}"; do
        ensure_command "$c" || exit 1
    done
}

auto_install_deps

# =========================
# 获取编号 100-110
# =========================
get_next_number() {
    for i in {100..110}; do
        if ! ls "$CONF_DIR" 2>/dev/null | grep -q "^$i-inbound-socks_"; then
            echo $i
            return
        fi
    done
    echo "No available number (100-110)"
    exit 1
}

# =========================
# 获取IP
# =========================
get_ip() {
    local version="$1"
    if [[ "$version" == "4" ]]; then
        curl -s -4 ip.sb 2>/dev/null || true
    else
        curl -s -6 ip.sb 2>/dev/null || true
    fi
}

# =========================
# URL 编码（使用 jq 的 @uri）
# =========================
urlencode() {
    local raw="$1"
    jq -nr --arg v "$raw" '$v|@uri'
}

# =========================
# 随机用户名/密码生成
# 用户名使用 /etc/xray/bin/xray uuid 命令
# 密码 50 位，包含大小写字母、数字和特殊字符
# =========================
gen_user() {
    /etc/xray/bin/xray uuid 2>/dev/null
}

gen_pass() {
    local pass
    if command -v openssl >/dev/null 2>&1; then
        pass=$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9!@#$%^&*()_+=\-\[\]{}|;:,.<>?/' | head -c 50 2>/dev/null || true)
    fi
    if [[ -z "${pass:-}" ]]; then
        pass=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+=\-\[\]{}|;:,.<>?/' </dev/urandom | head -c 50 2>/dev/null || true)
    fi
    if [[ -z "${pass:-}" ]]; then
        pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 50)
    fi
    echo "$pass"
}

# =========================
# 打印 URI（会对用户名、密码、备注进行 URL 编码）
# =========================
print_uri() {
    local file="$1"

    port=$(jq -r '.inbounds[0].port' "$file")
    auth=$(jq -r '.inbounds[0].settings.auth' "$file")
    user=$(jq -r '.inbounds[0].settings.accounts[0].user // empty' "$file")
    pass=$(jq -r '.inbounds[0].settings.accounts[0].pass // empty' "$file")

    ipv4=$(get_ip 4)
    ipv6=$(get_ip 6)

    remark="$port"
    read -rp "请输入节点备注（默认 $remark）: " user_remark
    [[ -n "$user_remark" ]] && remark="$user_remark"

    if [[ "$auth" == "password" && -n "$user" ]]; then
        enc_user=$(urlencode "$user")
        enc_pass=$(urlencode "$pass")
        auth_part="${enc_user}:${enc_pass}@"
    else
        auth_part=""
    fi

    enc_remark=$(urlencode "$remark")

    if [[ -n "$ipv4" ]]; then
        echo "socks5://${auth_part}${ipv4}:${port}#${enc_remark}"
    elif [[ -n "$ipv6" ]]; then
        echo "socks5://${auth_part}[${ipv6}]:${port}#${enc_remark}"
    else
        echo "No IP found"
    fi
}

# =========================
# 添加入站
# =========================
add_inbound() {

    read -rp "设置端口（默认随机 10000-60000）: " port
    [[ -z "$port" ]] && port=$((RANDOM%50000+10000))

    read -rp "监听地址 (默认 0.0.0.0): " listen
    [[ -z "$listen" ]] && listen="0.0.0.0"

    echo "[1] 无认证 (noauth)"
    echo "[2] 用户名密码 (password)"
    read -rp "选择认证方式 [1-2]: " auth_choice

    case $auth_choice in
        1)
            auth="noauth"
            accounts_block=""
            ;;
        2)
            auth="password"

            read -rp "用户名（留空自动生成 UUID）: " user
            if [[ -z "$user" ]]; then
                user=$(gen_user)
                echo "已生成用户名: $user"
            fi

            read -rp "密码（留空自动生成 50 位复杂密码）: " pass
            if [[ -z "$pass" ]]; then
                pass=$(gen_pass)
                echo "已生成密码: $pass"
            fi

            accounts_block=$(cat <<EOF
        "accounts": [
          {
            "user": "$user",
            "pass": "$pass"
          }
        ],
EOF
)
            ;;
        *)
            echo "无效选择"
            return
            ;;
    esac

    read -rp "是否开启 UDP (y/n，默认 n): " udp_input
    if [[ "$udp_input" == "y" ]]; then
        udp=true
    else
        udp=false
    fi

    number=$(get_next_number)
    tag="socks-$port-in"
    file="$CONF_DIR/$number-inbound-socks_$port.json"

    cat > "$file" <<EOF
{
  "inbounds": [
    {
      "tag": "$tag",
      "port": $port,
      "listen": "$listen",
      "protocol": "socks",
      "settings": {
        "auth": "$auth",
${accounts_block}        "udp": $udp
      }
    }
  ]
}
EOF

    echo "生成成功: $file"
    print_uri "$file"
}

# =========================
# 文件选择器
# =========================
select_file_with_exit() {
    mapfile -t files < <(ls "$CONF_DIR"/*socks*.json 2>/dev/null || true)

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "没有 socks 配置文件" >&2
        return 1
    fi

    echo "请选择文件 (输入 0 退出)：" >&2
    for i in "${!files[@]}"; do
        echo "[$((i+1))] ${files[$i]}" >&2
    done

    while true; do
        read -rp "选择 [0-${#files[@]}]: " sel
        if [[ "$sel" =~ ^[0-9]+$ ]]; then
            if [[ "$sel" -eq 0 ]]; then
                return 1
            elif [[ "$sel" -ge 1 && "$sel" -le "${#files[@]}" ]]; then
                printf "%s" "${files[$((sel-1))]}"
                return 0
            fi
        fi
        echo "无效选择，请重新输入" >&2
    done
}

# =========================
# 删除
# =========================
delete_inbound() {
    file=$(select_file_with_exit) || return
    rm -f "$file"
    echo "已删除 $file"
}

# =========================
# 修改（使用 vim 打开）
# =========================
modify_inbound() {
    file=$(select_file_with_exit) || return
    vim "$file"
}

# =========================
# 打印单个文件的 URI（交互）
# =========================
print_uris() {
    file=$(select_file_with_exit) || return
    print_uri "$file"
}

# =========================
# 重置密码（修改 UUID 和密码）
# 会在 settings.accounts[0] 中写入新的 user/pass；若 accounts 不存在则创建
# =========================
reset_credentials() {
    file=$(select_file_with_exit) || return

    new_user=$(gen_user)
    new_pass=$(gen_pass)

    tmpfile="${file}.tmp"
    jq --arg u "$new_user" --arg p "$new_pass" '
      if .inbounds[0].settings.accounts == null then
        .inbounds[0].settings.accounts = [ {user:$u, pass:$p} ]
      else
        .inbounds[0].settings.accounts[0].user = $u |
        .inbounds[0].settings.accounts[0].pass = $p
      end
    ' "$file" > "$tmpfile" && mv "$tmpfile" "$file"

    echo "已重置用户名和密码: $file"
    print_uri "$file"
}

# =========================
# 主菜单
# =========================
while true; do
    echo
    echo "==== Socks5 入站管理 ===="
    echo "[1] 添加入站"
    echo "[2] 删除入站"
    echo "[3] 修改入站配置"
    echo "[4] 重置密码 (修改 UUID 和密码)"
    echo "[5] 打印 URI"
    echo "[0] 退出"
    read -rp "选择操作 [0-5]: " opt

    case $opt in
        1) add_inbound ;;
        2) delete_inbound ;;
        3) modify_inbound ;;
        4) reset_credentials ;;
        5) print_uris ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
done