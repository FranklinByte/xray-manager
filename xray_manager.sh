#!/bin/bash
# ==============================================================================
# Xray 本地化管理工具 (基于 Caesar 脚本重构)
# 所有功能合并为单文件，已移除全部远程脚本下载/执行能力
# 仅保留 Xray 官方二进制 + Geo 数据的下载（带 SHA256 校验）
# ==============================================================================

# --- Shell 设置 ---
set -uo pipefail

# --- 颜色 ---
readonly RED='\033[31m'    readonly GREEN='\033[32m'
readonly YELLOW='\033[33m' readonly CYAN='\033[96m'
readonly MAGENTA='\033[95m' readonly PLAIN='\033[0m'

# --- 路径常量 ---
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly GEO_DIR="/usr/local/bin"
readonly GEO_SHARE_DIR="/usr/local/share/xray"
readonly ADDRESS_FILE="/root/inbound_address.txt"
readonly NETWORK_TUNING_CONF="/etc/sysctl.d/99-xray-network-tuning.conf"
readonly SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh"

# --- 全局变量 ---
OS_ID=""
OS_LIKE=""
INIT_SYSTEM=""

# ============================================================
# 第一部分：公共函数（去重后唯一一份）
# ============================================================

die()     { echo -e "${RED}[ERROR] $*${PLAIN}" >&2; exit 1; }
error()   { echo -e "\n${RED}[✖] $1${PLAIN}\n" >&2; }
info()    { echo -e "\n${YELLOW}[!] $1${PLAIN}\n"; }
success() { echo -e "\n${GREEN}[✔] $1${PLAIN}\n"; }
warn()    { echo -e "${YELLOW}[WARN] $*${PLAIN}"; }

pause_return() {
    echo ""
    read -n 1 -s -r -p "按任意键返回..." || true
    echo ""
}

# --- 系统检测 ---
detect_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
    else
        OS_ID="unknown"
        OS_LIKE=""
    fi
    if command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="unknown"
    fi
}

is_rpm_family() {
    case "$OS_ID" in
        centos|rhel|rocky|almalinux|fedora|ol) return 0 ;;
    esac
    [[ "$OS_LIKE" == *"rhel"* || "$OS_LIKE" == *"fedora"* ]]
}

install_packages() {
    local pkgs=("$@")
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ "$OS_ID" == "alpine" ]]; then
        apk update && apk add --no-cache "${pkgs[@]}"
    elif command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkgs[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${pkgs[@]}"
    else
        die "无法检测包管理器，请手动安装: ${pkgs[*]}"
    fi
}

# --- 依赖安装 ---
install_deps() {
    local required=("jq" "curl" "openssl" "unzip")
    local missing=()
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "正在安装缺失依赖: ${missing[*]} ..."
        if [[ "$OS_ID" == "alpine" ]]; then
            install_packages "${missing[@]}" bash iproute2 coreutils
        else
            install_packages "${missing[@]}"
        fi
    fi
}

# --- 权限与环境预检 ---
pre_check() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] && die "请以 root 身份运行此脚本。"
    [[ "$(uname -s)" != "Linux" ]] && die "仅支持 Linux 系统。"
    detect_system
    install_deps
}

# --- 获取公网 IP（IPv4 优先，IPv6 回退）---
get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    error "无法获取公网 IP 地址。" && return 1
}

# --- 获取连接地址（NAT/DDNS 支持）---
get_connection_ip() {
    local ip
    if [[ -f "$ADDRESS_FILE" && -s "$ADDRESS_FILE" ]]; then
        ip=$(cat "$ADDRESS_FILE")
        if [[ -n "$ip" ]]; then echo "$ip"; return; fi
    fi
    get_public_ip
}

# --- 获取链接名称（国家 - ISP）---
get_link_name() {
    local fallback="${1:-xray-node}"
    local ipinfo_json country org
    ipinfo_json=$(curl -sf --max-time 5 https://ipinfo.io 2>/dev/null) || true
    if [[ -n "$ipinfo_json" ]]; then
        country=$(echo "$ipinfo_json" | grep '"country"' | sed 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        org=$(echo "$ipinfo_json" | grep '"org"' | sed 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    if [[ -n "${country:-}" && -n "${org:-}" ]]; then
        echo "${country} - ${org}"
    else
        echo "$fallback"
    fi
}

# --- URL 编码 ---
urlencode() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null \
        || echo "$1" | sed 's/ /%20/g'
}

# --- 验证函数 ---
is_valid_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v lsof &>/dev/null; then
        lsof -i ":$port" &>/dev/null && return 0
    else
        (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && return 0
    fi
    # 同时检查 config.json 中的端口占用
    if [[ -f "$XRAY_CONFIG" ]]; then
        if jq -e --argjson p "$port" '.inbounds[]? | select(.port == $p)' "$XRAY_CONFIG" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

is_valid_uuid() {
    local uuid=$1
    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_valid_domain() {
    local domain=$1
    [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]]
}

# --- Xray 状态检查 ---
is_xray_artifacts_present() {
    [[ -f "/usr/local/sbin/xray-m" || -L "/usr/local/bin/xray-m" || -f "$XRAY_BIN" || -d "/usr/local/etc/xray" || -d "/var/log/xray" ]]
}

is_pfw_artifacts_present() {
    [[ -f "/usr/local/bin/pfw" || -f "/usr/local/bin/pfwd" || -f "/usr/local/bin/pfwd-acct" || -d "/etc/pfwd" || -f "/etc/nftables.d/pfwd.nft" || -f "/etc/nftables.d/pfwd_stat.nft" ]]
}

xray_branch_status_text() {
    local status="${YELLOW}未安装${PLAIN}"
    if is_xray_artifacts_present; then
        status="${GREEN}已安装${PLAIN}"
    fi
    echo -e "$status"
}

pfw_branch_status_text() {
    local status="${YELLOW}未安装${PLAIN}"
    if is_pfw_artifacts_present; then
        status="${GREEN}已安装${PLAIN}"
    fi
    echo -e "$status"
}

require_xray_branch_available() {
    if is_pfw_artifacts_present; then
        error "检测到 PFW 已安装。为避免审查风险，请先在 PFW 分支卸载后再安装/启用 Xray。"
        return 1
    fi
    return 0
}

require_pfw_branch_available() {
    if is_xray_artifacts_present; then
        error "检测到 Xray 相关文件。为避免审查风险，请先清理 Xray 分支后再部署 PFW。"
        return 1
    fi
    return 0
}

check_xray_status() {
    if [[ ! -f "$XRAY_BIN" ]]; then
        echo -e "  Xray 状态: ${RED}未安装${PLAIN}"
        return
    fi
    local ver; ver=$($XRAY_BIN version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未知")
    local status_str
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active --quiet xray && status_str="${GREEN}运行中${PLAIN}" || status_str="${YELLOW}未运行${PLAIN}"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service xray status 2>/dev/null | grep -qi started && status_str="${GREEN}运行中${PLAIN}" || status_str="${YELLOW}未运行${PLAIN}"
    else
        status_str="${YELLOW}未知${PLAIN}"
    fi
    echo -e "  Xray 状态: ${GREEN}已安装${PLAIN} | ${status_str} | 版本: ${CYAN}${ver}${PLAIN}"
}

# ============================================================
# 第二部分：Xray 核心安装（带 SHA256 校验）
# ============================================================

install_xray_core() {
    info "开始安装 Xray 核心..."

    local arch machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)   arch="64" ;;
        aarch64|arm64)  arch="arm64-v8a" ;;
        *) error "不支持的 CPU 架构: $machine"; return 1 ;;
    esac

    local api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    info "获取 Xray 最新版本信息..."
    local tag
    tag="$(curl -fsSL "$api" | grep -oE '"tag_name":\s*"[^"]+"' | head -n1 | cut -d'"' -f4)" || true
    local version_str="${tag:-latest}"
    info "目标版本: $version_str"

    local tmpdir; tmpdir="$(mktemp -d)"
    # 确保退出时清理
    trap "rm -rf '$tmpdir'" RETURN

    local zipname="Xray-linux-${arch}.zip"
    local dgst_name="${zipname}.dgst"
    local base_dl="https://github.com/XTLS/Xray-core/releases"

    # 下载二进制
    local zip_url
    if [[ -n "${tag:-}" ]]; then
        zip_url="${base_dl}/download/${tag}/${zipname}"
    else
        zip_url="${base_dl}/latest/download/${zipname}"
    fi

    info "正在下载 Xray ($zipname)..."
    if ! curl -fL "$zip_url" -o "$tmpdir/xray.zip"; then
        error "下载 Xray 失败"; return 1
    fi

    # 下载校验文件并验证 SHA256
    local dgst_url
    if [[ -n "${tag:-}" ]]; then
        dgst_url="${base_dl}/download/${tag}/${dgst_name}"
    else
        dgst_url="${base_dl}/latest/download/${dgst_name}"
    fi

    info "正在下载并验证 SHA256 校验..."
    if curl -fsSL "$dgst_url" -o "$tmpdir/dgst"; then
        local expected_sha256
        expected_sha256=$(grep -i 'SHA2-256' "$tmpdir/dgst" | head -1 | awk '{print $NF}' | tr '[:upper:]' '[:lower:]')
        if [[ -n "$expected_sha256" ]]; then
            local actual_sha256
            actual_sha256=$(sha256sum "$tmpdir/xray.zip" | awk '{print $1}')
            if [[ "$actual_sha256" != "$expected_sha256" ]]; then
                error "SHA256 校验失败！"
                error "期望: $expected_sha256"
                error "实际: $actual_sha256"
                error "文件可能已被篡改，终止安装。"
                return 1
            fi
            success "SHA256 校验通过: $actual_sha256"
        else
            warn "校验文件格式异常，跳过校验（请手动确认）"
        fi
    else
        warn "无法下载校验文件，跳过 SHA256 校验（请手动确认）"
    fi

    info "解压并安装到 /usr/local/bin ..."
    unzip -qo "$tmpdir/xray.zip" -d "$tmpdir"
    install -m 0755 "$tmpdir/xray" "$XRAY_BIN"
    mkdir -p /usr/local/etc/xray /usr/local/share/xray
    success "Xray 核心安装完成"
}

# --- Geo 数据安装 ---
install_geodata() {
    info "正在安装/更新 GeoIP 和 GeoSite 数据文件..."
    mkdir -p "$GEO_DIR" "$GEO_SHARE_DIR"
    if ! curl -fsSL -o "$GEO_DIR/geoip.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"; then
        error "geoip.dat 下载失败"; return 1
    fi
    if ! curl -fsSL -o "$GEO_DIR/geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"; then
        error "geosite.dat 下载失败"; return 1
    fi
    cp -f "$GEO_DIR/geoip.dat"  "$GEO_SHARE_DIR/"
    cp -f "$GEO_DIR/geosite.dat" "$GEO_SHARE_DIR/"
    success "Geo 数据文件已更新"
}

# ============================================================
# 第三部分：服务管理
# ============================================================

install_service_systemd() {
    info "安装 Systemd 服务..."
    cat >/etc/systemd/system/xray.service <<'SVCEOF'
[Unit]
Description=Xray Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=false
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable --now xray
    success "Systemd 服务已安装并启动"
}

install_service_openrc() {
    info "安装 OpenRC 服务..."
    install -d -m 0755 /var/log/xray || true
    cat >/etc/init.d/xray <<'RCEOF'
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
start_stop_daemon_args="--make-pidfile --background"

depend() {
  need net
  use dns
}
RCEOF
    chmod +x /etc/init.d/xray
    rc-update add xray default
    rc-service xray restart || rc-service xray start
    success "OpenRC 服务已安装并启动"
}

setup_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        install_service_systemd
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        install_service_openrc
    else
        error "无法确定服务管理器，请手动配置自启动。"
    fi
}

restart_xray_service() {
    if [[ ! -f "$XRAY_BIN" ]]; then error "Xray 未安装"; return 1; fi
    info "正在重启 Xray 服务..."
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart xray
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service xray restart
    else
        error "无法确定服务管理器"; return 1
    fi
    sleep 1
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active --quiet xray || { error "Xray 服务启动失败"; return 1; }
    fi
    success "Xray 服务已成功重启"
}

# --- 自定义连接地址管理 ---
set_connection_address() {
    echo ""
    echo "================================================="
    echo "         自定义连接地址 (NAT/DDNS 模式)"
    echo "================================================="
    echo "说明: 如果您使用的是 NAT VPS 或拥有动态 IP 的机器，"
    echo "请在此输入外部可访问的 IP 地址或 DDNS 域名。"
    echo "-------------------------------------------------"
    if [[ -f "$ADDRESS_FILE" ]]; then
        local current_addr; current_addr=$(cat "$ADDRESS_FILE")
        echo -e "当前已设置: ${CYAN}${current_addr}${PLAIN}"
    else
        echo -e "当前状态: ${YELLOW}自动获取公网 IP${PLAIN}"
    fi
    echo ""
    read -rp "请输入新的连接地址 (留空恢复自动获取): " new_addr
    if [[ -z "$new_addr" ]]; then
        rm -f "$ADDRESS_FILE"
        success "已恢复为自动获取公网 IP 模式。"
    else
        echo "$new_addr" > "$ADDRESS_FILE"
        success "连接地址已更新为: $new_addr"
    fi
}

# ============================================================
# 第四部分：Geo 文件更新模块
# ============================================================

module_update_geo() {
    echo "================ Geo 文件更新 ================"
    echo "1. 立即更新 (不设定时任务)"
    echo "2. 立即更新 + 设置每日自动更新 (crontab)"
    echo "0. 返回"
    read -rp "请选择 [0-2]: " geo_choice

    case "$geo_choice" in
        1)
            install_geodata
            restart_xray_service || true
            ;;
        2)
            install_geodata
            restart_xray_service || true
            # 生成本地更新脚本
            cat > /root/update_geo_local.sh <<'GEOEOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
GEO_DIR="/usr/local/bin"
GEO_SHARE_DIR="/usr/local/share/xray"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
log "开始下载 Geo 文件..."
mkdir -p "$GEO_DIR"
curl -fsSL -o "$GEO_DIR/geoip.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" || { log "geoip.dat 下载失败"; exit 1; }
curl -fsSL -o "$GEO_DIR/geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" || { log "geosite.dat 下载失败"; exit 1; }
if [[ -d "$GEO_SHARE_DIR" ]]; then
    cp -f "$GEO_DIR/geoip.dat" "$GEO_SHARE_DIR/"
    cp -f "$GEO_DIR/geosite.dat" "$GEO_SHARE_DIR/"
fi
log "正在重启 Xray 服务..."
if command -v systemctl >/dev/null 2>&1; then systemctl restart xray; elif command -v rc-service >/dev/null 2>&1; then rc-service xray restart; fi
log "更新完成"
GEOEOF
            chmod +x /root/update_geo_local.sh
            # 写入 crontab
            local tmp_cron; tmp_cron=$(mktemp)
            crontab -l 2>/dev/null > "$tmp_cron" || true
            sed -i '/update_geo/d' "$tmp_cron"
            echo "0 3 * * * /root/update_geo_local.sh >> /var/log/update_geo.log 2>&1" >> "$tmp_cron"
            crontab "$tmp_cron"
            rm -f "$tmp_cron"
            success "Geo 文件已更新，每日 3:00 自动更新已配置。"
            ;;
        0) return ;;
        *) error "无效选择" ;;
    esac
}

# ============================================================
# 第五部分：Shadowsocks 2022 模块
# ============================================================

ss_select_method_and_password() {
    echo ""
    echo "请选择 Shadowsocks 加密协议:"
    echo -e "  ${GREEN}1.${PLAIN} 2022-blake3-aes-128-gcm   (推荐, 16字节密钥)"
    echo -e "  ${GREEN}2.${PLAIN} 2022-blake3-aes-256-gcm   (推荐, 32字节密钥)"
    echo -e "  ${GREEN}3.${PLAIN} 2022-blake3-chacha20-poly1305 (推荐, 32字节密钥)"
    echo -e "  ${YELLOW}4.${PLAIN} aes-128-gcm   (传统)"
    echo -e "  ${YELLOW}5.${PLAIN} aes-256-gcm   (传统)"
    echo -e "  ${YELLOW}6.${PLAIN} chacha20-ietf-poly1305 (传统)"
    read -rp "请输入选项 [1-6] (默认 2): " method_choice
    [ -z "$method_choice" ] && method_choice=2
    local key_len=32
    case $method_choice in
        1) SS_METHOD="2022-blake3-aes-128-gcm"; key_len=16 ;;
        2) SS_METHOD="2022-blake3-aes-256-gcm"; key_len=32 ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305"; key_len=32 ;;
        4) SS_METHOD="aes-128-gcm"; key_len=16 ;;
        5) SS_METHOD="aes-256-gcm"; key_len=32 ;;
        6) SS_METHOD="chacha20-ietf-poly1305"; key_len=32 ;;
        *) SS_METHOD="2022-blake3-aes-256-gcm"; key_len=32 ;;
    esac
    echo ""
    read -rp "请输入密码 (留空生成随机 ${key_len} 字节密码): " user_pass
    if [[ -z "$user_pass" ]]; then
        SS_PASSWORD=$(openssl rand -base64 $key_len | tr -d '\n')
        info "已自动生成密码: ${CYAN}${SS_PASSWORD}${PLAIN}"
    else
        SS_PASSWORD="$user_pass"
    fi
}

ss_append_config() {
    local port=$1 method=$2 password=$3
    local tag="ss-in-${port}"
    local inbound_json
    inbound_json=$(jq -n \
        --argjson port "$port" --arg method "$method" --arg pass "$password" --arg tag "$tag" \
        '{ port: $port, protocol: "shadowsocks", settings: { method: $method, password: $pass, network: "tcp,udp" }, tag: $tag }')
    _append_inbound "$inbound_json"
}

ss_install() {
    info "开始配置 Shadowsocks..."
    local port
    while true; do
        read -rp "$(echo -e "请输入端口 [1-65535] (默认: ${CYAN}2022${PLAIN}): ")" port
        [ -z "$port" ] && port=2022
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        if is_port_in_use "$port"; then error "端口 $port 已被占用"; continue; fi
        break
    done
    ss_select_method_and_password
    if ! install_xray_core; then return 1; fi
    install_geodata
    ss_append_config "$port" "$SS_METHOD" "$SS_PASSWORD"
    setup_service
    restart_xray_service || true
    success "安装配置完成！"
    ss_view_info "$port"
}

ss_view_info() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置不存在"; return; fi
    local ports
    ports=$(jq -r '.inbounds[] | select(.protocol=="shadowsocks") | .port' "$XRAY_CONFIG")
    if [[ -z "$ports" ]]; then error "未找到 Shadowsocks 节点配置。"; return; fi

    local target_port=""
    local port_count; port_count=$(echo "$ports" | wc -l)

    if [[ -n "${1:-}" ]]; then
        target_port=$1
    elif [[ "$port_count" -eq 1 ]]; then
        target_port=$(echo "$ports" | tr -d ' \n')
    else
        echo "发现多个 Shadowsocks 节点:"
        for p in $ports; do echo " - 端口: $p"; done
        echo ""
        while true; do
            read -rp "请输入要查看的端口: " input_p
            if echo "$ports" | grep -q "^$input_p$"; then target_port=$input_p; break; fi
            error "无效端口"
        done
    fi

    local node_json; node_json=$(jq -r --argjson p "$target_port" '.inbounds[] | select(.port==$p and .protocol=="shadowsocks")' "$XRAY_CONFIG")
    if [[ -z "$node_json" ]]; then error "读取配置失败"; return; fi
    local method; method=$(echo "$node_json" | jq -r '.settings.method')
    local password; password=$(echo "$node_json" | jq -r '.settings.password')
    local tag; tag=$(echo "$node_json" | jq -r '.tag')
    local ip; ip=$(get_connection_ip) || return 1
    local user_info_b64; user_info_b64=$(echo -n "${method}:${password}" | base64 -w 0)
    local link_name; link_name=$(get_link_name "$tag")
    local link_name_enc; link_name_enc=$(urlencode "$link_name")
    local link="ss://${user_info_b64}@${ip}:${target_port}#${link_name_enc}"
    local save_file="/root/xray_ss_link_${target_port}.txt"
    echo "$link" > "$save_file"

    echo "----------------------------------------------------------------"
    echo -e "${GREEN} --- Shadowsocks 配置信息 --- ${PLAIN}"
    echo -e "${YELLOW} 协议: ${CYAN}${method}${PLAIN}"
    echo -e "${YELLOW} 地址: ${CYAN}${ip}${PLAIN}"
    echo -e "${YELLOW} 端口: ${CYAN}${target_port}${PLAIN}"
    echo -e "${YELLOW} 密码: ${CYAN}${password}${PLAIN}"
    echo "----------------------------------------------------------------"
    echo -e "${GREEN} 分享链接 (已保存到 $save_file):${PLAIN}"
    echo -e "${CYAN}${link}${PLAIN}"
    echo "----------------------------------------------------------------"
}

ss_delete_node() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置不存在"; return; fi
    echo "当前 Shadowsocks 节点:"
    local ports; ports=$(jq -r '.inbounds[] | select(.protocol=="shadowsocks") | .port' "$XRAY_CONFIG")
    if [[ -z "$ports" ]]; then error "未找到 SS 节点"; return; fi
    for p in $ports; do echo " - 端口: $p"; done
    echo ""
    local target_p
    while true; do
        read -rp "请输入要删除的端口: " target_p
        echo "$ports" | grep -q "^$target_p$" && break
        error "端口无效"
    done
    read -rp "确定删除端口 $target_p 的 SS 节点？[y/N]: " confirm
    [[ ! $confirm =~ ^[yY]$ ]] && { info "已取消"; return; }
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.del.$(date +%s)"
    local tmp; tmp=$(mktemp)
    jq --argjson p "$target_p" 'del(.inbounds[] | select(.port == $p and .protocol=="shadowsocks"))' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
    chmod 600 "$XRAY_CONFIG"
    rm -f "/root/xray_ss_link_${target_p}.txt"
    restart_xray_service || true
    success "SS 节点 (端口 $target_p) 已删除。"
}

ss_modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置不存在"; return; fi
    echo "当前 Shadowsocks 节点:"
    local ports; ports=$(jq -r '.inbounds[] | select(.protocol=="shadowsocks") | .port' "$XRAY_CONFIG")
    if [[ -z "$ports" ]]; then error "未找到 SS 节点"; return; fi
    for p in $ports; do echo " - 端口: $p"; done
    echo ""
    local target_p
    while true; do
        read -rp "请输入要修改的端口: " target_p
        echo "$ports" | grep -q "^$target_p$" && break
        error "端口未找到"
    done
    info "请重新配置参数:"
    ss_select_method_and_password
    local tmp; tmp=$(mktemp)
    jq --argjson p "$target_p" 'del(.inbounds[] | select(.port == $p and .protocol=="shadowsocks"))' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
    ss_append_config "$target_p" "$SS_METHOD" "$SS_PASSWORD"
    restart_xray_service || true
    success "修改完成"
    ss_view_info "$target_p"
}

# --- SS 子菜单 ---
module_ss_menu() {
    while true; do
        clear
        echo -e "${CYAN} Shadowsocks 2022 管理${PLAIN}"
        echo "---------------------------------------------"
        check_xray_status
        echo "---------------------------------------------"
        echo -e "  ${GREEN}1.${PLAIN} 新增/安装 SS 节点"
        echo -e "  ${CYAN}2.${PLAIN} 查看节点链接"
        echo -e "  ${YELLOW}3.${PLAIN} 修改 SS 节点配置"
        echo -e "  ${RED}4.${PLAIN} 删除 SS 节点"
        echo -e "  ${MAGENTA}5.${PLAIN} 设置连接地址 (NAT/DDNS)"
        echo -e "  ${YELLOW}0.${PLAIN} 返回主菜单"
        echo "---------------------------------------------"
        read -rp "请输入选项 [0-5]: " choice
        case $choice in
            1) ss_install ;;
            2) ss_view_info ;;
            3) ss_modify_config ;;
            4) ss_delete_node ;;
            5) set_connection_address ;;
            0) return ;;
            *) error "无效选项" ;;
        esac
        pause_return
    done
}

# ============================================================
# 第六部分：VLESS Reality 模块
# ============================================================

reality_write_config() {
    local port=$1 uuid=$2 domain=$3 private_key=$4 public_key=$5
    local shortid="20220701" spiderx="/"
    local tag="vless-reality-in-$port"
    local inbound_json
    inbound_json=$(jq -n \
        --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" \
        --arg private_key "$private_key" --arg public_key "$public_key" \
        --arg shortid "$shortid" --arg spiderx "$spiderx" --arg tag "$tag" \
    '{
        listen: "0.0.0.0", port: $port, protocol: "vless",
        settings: { clients: [{id: $uuid, flow: "xtls-rprx-vision"}], decryption: "none" },
        streamSettings: {
            network: "tcp", security: "reality",
            realitySettings: {
                show: false, dest: ($domain + ":443"), xver: 0,
                serverNames: [$domain], privateKey: $private_key,
                publicKey: $public_key, shortIds: [$shortid], spiderX: $spiderx
            }
        },
        sniffing: { enabled: false }, tag: $tag
    }')
    _append_inbound "$inbound_json"
}

reality_install() {
    info "开始配置 VLESS Reality..."
    local port uuid domain
    while true; do
        read -rp "$(echo -e "请输入端口 [1-65535] (默认: ${CYAN}443${PLAIN}): ")" port
        [ -z "$port" ] && port=443
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        if is_port_in_use "$port"; then error "端口 $port 已被占用"; continue; fi
        break
    done
    while true; do
        read -rp "请输入 UUID (留空随机生成): " uuid
        if [[ -z "$uuid" ]]; then
            uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')
            info "已生成 UUID: ${CYAN}${uuid}${PLAIN}"
            break
        elif is_valid_uuid "$uuid"; then break
        else error "UUID 格式无效"; fi
    done
    while true; do
        read -rp "$(echo -e "请输入 SNI 域名 (默认: ${CYAN}hk.art.museum${PLAIN}): ")" domain
        [ -z "$domain" ] && domain="hk.art.museum"
        if is_valid_domain "$domain"; then break; else error "域名格式无效"; fi
    done

    if ! install_xray_core; then return 1; fi
    install_geodata

    info "正在生成 Reality 密钥对..."
    local key_pair; key_pair=$($XRAY_BIN x25519)
    local private_key; private_key=$(echo "$key_pair" | grep -i 'private' | awk '{print $NF}')
    local public_key; public_key=$(echo "$key_pair" | grep -iE 'public' | awk '{print $NF}')
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败"; return 1
    fi

    reality_write_config "$port" "$uuid" "$domain" "$private_key" "$public_key"
    setup_service
    restart_xray_service || true
    success "安装配置完成！"
    reality_view_info "$port"
}

reality_view_info() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置不存在"; return; fi
    local ports
    ports=$(jq -r '.inbounds[] | select(.streamSettings.security == "reality") | .port' "$XRAY_CONFIG")
    if [[ -z "$ports" ]]; then error "未找到 Reality 节点配置。"; return; fi

    local target_port=""
    local port_count; port_count=$(echo "$ports" | wc -l)

    if [[ -n "${1:-}" ]]; then
        target_port=$1
    elif [[ "$port_count" -eq 1 ]]; then
        target_port=$(echo "$ports" | tr -d ' \n')
    else
        echo "发现多个 Reality 节点:"
        for p in $ports; do echo " - 端口: $p"; done
        echo ""
        while true; do
            read -rp "请输入要查看的端口: " input_p
            echo "$ports" | grep -q "^$input_p$" && { target_port=$input_p; break; }
            error "无效端口"
        done
    fi

    local node_json
    node_json=$(jq --argjson p "$target_port" '.inbounds[] | select(.port == $p and .streamSettings.security == "reality")' "$XRAY_CONFIG")
    if [[ -z "$node_json" ]]; then error "读取配置失败"; return; fi

    local uuid; uuid=$(echo "$node_json" | jq -r '.settings.clients[0].id')
    local domain; domain=$(echo "$node_json" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    local public_key; public_key=$(echo "$node_json" | jq -r '.streamSettings.realitySettings.publicKey')
    local shortid; shortid=$(echo "$node_json" | jq -r '.streamSettings.realitySettings.shortIds[0]')
    local spiderx; spiderx=$(echo "$node_json" | jq -r '.streamSettings.realitySettings.spiderX // "/"')
    local tag; tag=$(echo "$node_json" | jq -r '.tag')

    if [[ -z "$public_key" || "$public_key" == "null" ]]; then error "配置缺少公钥"; return; fi

    local ip; ip=$(get_connection_ip) || return 1
    local display_ip=$ip; [[ $ip =~ ":" ]] && display_ip="[$ip]"
    local spiderx_enc; spiderx_enc=$(urlencode "$spiderx")
    local link_name; link_name=$(get_link_name "${tag}")
    local link_name_enc; link_name_enc=$(urlencode "$link_name")
    local vless_url="vless://${uuid}@${display_ip}:${target_port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}&spx=${spiderx_enc}#${link_name_enc}"
    local save_file="/root/xray_vless_reality_link_${target_port}.txt"
    echo "$vless_url" > "$save_file"

    echo "----------------------------------------------------------------"
    echo -e "${GREEN} --- VLESS Reality 配置信息 --- ${PLAIN}"
    echo -e "${YELLOW} 地址: ${CYAN}${ip}${PLAIN}"
    echo -e "${YELLOW} 端口: ${CYAN}${target_port}${PLAIN}"
    echo -e "${YELLOW} UUID: ${CYAN}${uuid}${PLAIN}"
    echo -e "${YELLOW} SNI:  ${CYAN}${domain}${PLAIN}"
    echo -e "${YELLOW} SpiderX: ${CYAN}${spiderx}${PLAIN}"
    echo "----------------------------------------------------------------"
    echo -e "${GREEN} 分享链接 (已保存到 $save_file):${PLAIN}"
    echo -e "${CYAN}${vless_url}${PLAIN}"
    echo "----------------------------------------------------------------"
}

reality_delete_node() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置不存在"; return; fi
    echo "当前 VLESS-Reality 节点:"
    local ports; ports=$(jq -r '.inbounds[] | select(.streamSettings.security == "reality") | .port' "$XRAY_CONFIG")
    if [[ -z "$ports" ]]; then error "未找到 Reality 节点"; return; fi
    for p in $ports; do echo " - 端口: $p"; done
    echo ""
    local target_p
    while true; do
        read -rp "请输入要删除的端口: " target_p
        echo "$ports" | grep -q "^$target_p$" && break
        error "端口无效"
    done
    read -rp "确定删除端口 $target_p 的 Reality 节点？[y/N]: " confirm
    [[ ! $confirm =~ ^[yY]$ ]] && { info "已取消"; return; }
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.del.$(date +%s)"
    local tmp; tmp=$(mktemp)
    jq --argjson p "$target_p" 'del(.inbounds[] | select(.port == $p and .streamSettings.security == "reality"))' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
    chmod 600 "$XRAY_CONFIG"
    rm -f "/root/xray_vless_reality_link_${target_p}.txt"
    restart_xray_service || true
    success "Reality 节点 (端口 $target_p) 已删除。"
}

reality_modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置不存在"; return; fi
    echo "当前 VLESS-Reality 节点:"
    local ports; ports=$(jq -r '.inbounds[] | select(.streamSettings.security == "reality") | .port' "$XRAY_CONFIG")
    if [[ -z "$ports" ]]; then error "未找到 Reality 节点"; return; fi
    for p in $ports; do echo " - 端口: $p"; done
    echo ""
    local target_port
    while true; do
        read -rp "请输入要修改的端口: " target_port
        echo "$ports" | grep -q "^$target_port$" && break
        error "端口未找到"
    done
    local node_json; node_json=$(jq --argjson p "$target_port" '.inbounds[] | select(.port == $p and .streamSettings.security == "reality")' "$XRAY_CONFIG")
    local current_uuid; current_uuid=$(echo "$node_json" | jq -r '.settings.clients[0].id')
    local current_domain; current_domain=$(echo "$node_json" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    local private_key; private_key=$(echo "$node_json" | jq -r '.streamSettings.realitySettings.privateKey')
    local public_key; public_key=$(echo "$node_json" | jq -r '.streamSettings.realitySettings.publicKey')

    info "请输入新配置，直接回车保留当前值。"
    local port uuid domain
    while true; do
        read -rp "$(echo -e "端口 (当前: ${CYAN}${target_port}${PLAIN}): ")" port
        [ -z "$port" ] && port=$target_port
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        if [[ "$port" != "$target_port" ]] && is_port_in_use "$port"; then error "端口已被占用"; continue; fi
        break
    done
    while true; do
        read -rp "$(echo -e "UUID (当前: ${CYAN}${current_uuid}${PLAIN}): ")" uuid
        [ -z "$uuid" ] && uuid=$current_uuid
        is_valid_uuid "$uuid" && break; error "UUID 格式无效"
    done
    while true; do
        read -rp "$(echo -e "SNI 域名 (当前: ${CYAN}${current_domain}${PLAIN}): ")" domain
        [ -z "$domain" ] && domain=$current_domain
        is_valid_domain "$domain" && break; error "域名格式无效"
    done

    local tmp; tmp=$(mktemp)
    jq --argjson p "$target_port" 'del(.inbounds[] | select(.port == $p and .streamSettings.security == "reality"))' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
    reality_write_config "$port" "$uuid" "$domain" "$private_key" "$public_key"
    restart_xray_service || true
    success "配置修改成功！"
    reality_view_info "$port"
}

# --- Reality 子菜单 ---
module_reality_menu() {
    while true; do
        clear
        echo -e "${CYAN} VLESS Reality 管理${PLAIN}"
        echo "---------------------------------------------"
        check_xray_status
        echo "---------------------------------------------"
        echo -e "  ${GREEN}1.${PLAIN} 新增/安装 Reality 节点"
        echo -e "  ${CYAN}2.${PLAIN} 查看节点链接"
        echo -e "  ${YELLOW}3.${PLAIN} 修改节点配置"
        echo -e "  ${RED}4.${PLAIN} 删除 Reality 节点"
        echo -e "  ${MAGENTA}5.${PLAIN} 设置连接地址 (NAT/DDNS)"
        echo -e "  ${YELLOW}0.${PLAIN} 返回主菜单"
        echo "---------------------------------------------"
        read -rp "请输入选项 [0-5]: " choice
        case $choice in
            1) reality_install ;;
            2) reality_view_info ;;
            3) reality_modify_config ;;
            4) reality_delete_node ;;
            5) set_connection_address ;;
            0) return ;;
            *) error "无效选项" ;;
        esac
        pause_return
    done
}

# ============================================================
# 第七部分：VLESS Encryption (Post-Quantum) 模块
# ============================================================

pq_generate_tokens() {
    info "生成 VLESS Encryption (ML-KEM-768) 密钥..."
    if ! command -v "$XRAY_BIN" >/dev/null 2>&1; then
        error "未找到 Xray，请先安装。"; return 1
    fi
    local out; out="$($XRAY_BIN vlessenc 2>&1 || true)"
    local dec; dec="$(printf '%s\n' "$out" | awk '/Authentication: ML-KEM-768/ {p=1; next} p && /"decryption":/ {gsub(/^.*"decryption": *"/,""); gsub(/".*/,""); print; exit}')"
    local enc; enc="$(printf '%s\n' "$out" | awk '/Authentication: ML-KEM-768/ {p=1; next} p && /"encryption":/ {gsub(/^.*"encryption": *"/,""); gsub(/".*/,""); print; exit}')"
    if [[ -z "$dec" || -z "$enc" ]]; then
        error "密钥生成失败"; return 1
    fi
    VLESS_DECRYPTION="${dec/.native./.random.}"
    VLESS_ENCRYPTION="${enc/.native./.random.}"
    info "密钥生成成功 (native -> random 已转换)。"
}

pq_append_config() {
    local port=$1 uuid=$2
    local tag="vless-pq-in-${port}"
    local inbound_json
    inbound_json=$(jq -n \
        --argjson port "$port" --arg uuid "$uuid" --arg dec "$VLESS_DECRYPTION" \
        --arg enc "$VLESS_ENCRYPTION" --arg tag "$tag" \
        '{ port: $port, protocol: "vless",
           settings: { clients: [{id: $uuid}], decryption: $dec, encryption: $enc, selectedAuth: "ML-KEM-768, Post-Quantum" },
           streamSettings: { network: "tcp" }, tag: $tag }')
    _append_inbound "$inbound_json"
}

pq_install() {
    info "开始配置 VLESS Encryption (Post-Quantum)..."
    local port uuid
    while true; do
        read -rp "$(echo -e "请输入端口 [1-65535] (默认: ${CYAN}40000${PLAIN}): ")" port
        [ -z "$port" ] && port=40000
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        if is_port_in_use "$port"; then error "端口 $port 已被占用"; continue; fi
        break
    done
    while true; do
        read -rp "请输入 UUID (留空随机生成): " uuid
        if [[ -z "$uuid" ]]; then
            uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')
            info "已生成 UUID: ${CYAN}${uuid}${PLAIN}"
            break
        elif is_valid_uuid "$uuid"; then break
        else error "UUID 格式无效"; fi
    done
    if ! install_xray_core; then return 1; fi
    install_geodata
    if ! pq_generate_tokens; then return 1; fi
    pq_append_config "$port" "$uuid"
    setup_service
    restart_xray_service || true
    success "安装配置完成！"
    pq_view_info "$port"
}

pq_view_info() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置不存在"; return; fi
    local ports
    ports=$(jq -r '.inbounds[] | select(.protocol=="vless" and (.settings.selectedAuth | tostring | contains("Post-Quantum"))) | .port' "$XRAY_CONFIG")
    if [[ -z "$ports" ]]; then error "未找到 VLESS Encryption 节点。"; return; fi

    local target_port=""
    local port_count; port_count=$(echo "$ports" | wc -l)
    if [[ -n "${1:-}" ]]; then
        target_port=$1
    elif [[ "$port_count" -eq 1 ]]; then
        target_port=$(echo "$ports" | tr -d ' \n')
    else
        echo "发现多个 VLESS Encryption 节点:"
        for p in $ports; do echo " - 端口: $p"; done
        echo ""
        while true; do
            read -rp "请输入要查看的端口: " input_p
            echo "$ports" | grep -q "^$input_p$" && { target_port=$input_p; break; }
            error "无效端口"
        done
    fi

    local node_json; node_json=$(jq -r --argjson p "$target_port" '.inbounds[] | select(.port==$p and .protocol=="vless" and (.settings.selectedAuth | tostring | contains("Post-Quantum")))' "$XRAY_CONFIG")
    if [[ -z "$node_json" ]]; then error "读取配置失败"; return; fi
    local uuid; uuid=$(echo "$node_json" | jq -r '.settings.clients[0].id')
    local enc_key; enc_key=$(echo "$node_json" | jq -r '.settings.encryption')
    local tag; tag=$(echo "$node_json" | jq -r '.tag')
    local ip; ip=$(get_connection_ip) || return 1
    local display_ip=$ip; [[ $ip =~ ":" ]] && display_ip="[$ip]"
    local link_name; link_name=$(get_link_name "$tag")
    local link_name_enc; link_name_enc=$(urlencode "$link_name")
    local link="vless://${uuid}@${display_ip}:${target_port}?encryption=${enc_key}&type=tcp&security=none#${link_name_enc}"
    local save_file="/root/xray_vless_encryption_link_${target_port}.txt"
    echo "$link" > "$save_file"

    echo "----------------------------------------------------------------"
    echo -e "${GREEN} --- VLESS Encryption (Post-Quantum) 配置信息 --- ${PLAIN}"
    echo -e "${YELLOW} 端口: ${CYAN}${target_port}${PLAIN}"
    echo -e "${YELLOW} UUID: ${CYAN}${uuid}${PLAIN}"
    echo -e "${YELLOW} 地址: ${CYAN}${ip}${PLAIN}"
    echo -e "${YELLOW} Encryption: ${CYAN}${enc_key}${PLAIN}"
    echo "----------------------------------------------------------------"
    echo -e "${GREEN} 分享链接 (已保存到 $save_file):${PLAIN}"
    echo -e "${CYAN}${link}${PLAIN}"
    echo "----------------------------------------------------------------"
}

pq_delete_node() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置不存在"; return; fi
    echo "当前 VLESS Encryption 节点:"
    local ports; ports=$(jq -r '.inbounds[] | select(.protocol=="vless" and (.settings.selectedAuth | tostring | contains("Post-Quantum"))) | .port' "$XRAY_CONFIG")
    if [[ -z "$ports" ]]; then error "未找到 PQ 节点"; return; fi
    for p in $ports; do echo " - 端口: $p"; done
    echo ""
    local target_p
    while true; do
        read -rp "请输入要删除的端口: " target_p
        echo "$ports" | grep -q "^$target_p$" && break
        error "端口无效"
    done
    read -rp "确定删除端口 $target_p 的 PQ 节点？[y/N]: " confirm
    [[ ! $confirm =~ ^[yY]$ ]] && { info "已取消"; return; }
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.del.$(date +%s)"
    local tmp; tmp=$(mktemp)
    jq --argjson p "$target_p" 'del(.inbounds[] | select(.port == $p and .protocol=="vless" and (.settings.selectedAuth | tostring | contains("Post-Quantum"))))' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
    chmod 600 "$XRAY_CONFIG"
    rm -f "/root/xray_vless_encryption_link_${target_p}.txt"
    restart_xray_service || true
    success "PQ 节点 (端口 $target_p) 已删除。"
}

pq_modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置不存在"; return; fi
    echo "当前 VLESS Encryption 节点:"
    local ports; ports=$(jq -r '.inbounds[] | select(.protocol=="vless" and (.settings.selectedAuth | tostring | contains("Post-Quantum"))) | .port' "$XRAY_CONFIG")
    if [[ -z "$ports" ]]; then error "未找到 PQ 节点"; return; fi
    for p in $ports; do echo " - 端口: $p"; done
    echo ""
    local target_p
    while true; do
        read -rp "请输入要修改的端口: " target_p
        echo "$ports" | grep -q "^$target_p$" && break
        error "端口未找到"
    done
    local new_uuid
    while true; do
        read -rp "请输入新 UUID (留空随机生成): " new_uuid
        if [[ -z "$new_uuid" ]]; then
            new_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')
            break
        elif is_valid_uuid "$new_uuid"; then break
        else error "UUID 格式无效"; fi
    done
    if ! pq_generate_tokens; then return 1; fi
    local tmp; tmp=$(mktemp)
    jq --argjson p "$target_p" 'del(.inbounds[] | select(.port == $p and .protocol=="vless" and (.settings.selectedAuth | tostring | contains("Post-Quantum"))))' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
    pq_append_config "$target_p" "$new_uuid"
    restart_xray_service || true
    success "修改完成"
    pq_view_info "$target_p"
}

# --- PQ 子菜单 ---
module_pq_menu() {
    while true; do
        clear
        echo -e "${CYAN} VLESS Encryption (Post-Quantum) 管理${PLAIN}"
        echo "---------------------------------------------"
        check_xray_status
        echo "---------------------------------------------"
        echo -e "  ${GREEN}1.${PLAIN} 新增/安装 PQ 节点"
        echo -e "  ${CYAN}2.${PLAIN} 查看节点链接"
        echo -e "  ${YELLOW}3.${PLAIN} 修改节点配置"
        echo -e "  ${RED}4.${PLAIN} 删除 PQ 节点"
        echo -e "  ${MAGENTA}5.${PLAIN} 设置连接地址 (NAT/DDNS)"
        echo -e "  ${YELLOW}0.${PLAIN} 返回主菜单"
        echo "---------------------------------------------"
        read -rp "请输入选项 [0-5]: " choice
        case $choice in
            1) pq_install ;;
            2) pq_view_info ;;
            3) pq_modify_config ;;
            4) pq_delete_node ;;
            5) set_connection_address ;;
            0) return ;;
            *) error "无效选项" ;;
        esac
        pause_return
    done
}

# ============================================================
# 第八部分：分流配置 (Routing) 模块
# ============================================================

routing_parse_link_py() {
    python3 -c '
import sys, urllib.parse, json, base64

link = sys.argv[1]
result = {}

def b64decode(s):
    s = s.strip()
    missing_padding = len(s) % 4
    if missing_padding: s += "=" * (4 - missing_padding)
    try: return base64.urlsafe_b64decode(s).decode("utf-8")
    except: return base64.b64decode(s).decode("utf-8")

try:
    if link.startswith("ss://"):
        result["protocol"] = "shadowsocks"
        body = link[5:]
        tag = ""
        if "#" in body:
            body, tag = body.split("#", 1)
            result["tag_comment"] = urllib.parse.unquote(tag)
        if "@" in body:
            userpass_part, hostport = body.split("@", 1)
            method = password = ""
            decoded_success = False
            try:
                decoded_up = b64decode(userpass_part)
                if ":" in decoded_up and decoded_up.isprintable():
                    method, password = decoded_up.split(":", 1)
                    decoded_success = True
            except: pass
            if not decoded_success:
                if ":" in userpass_part:
                    method, password = userpass_part.split(":", 1)
                    password = urllib.parse.unquote(password)
                else: raise Exception("Invalid SS format")
            host, port = hostport.split(":")
            result["address"] = host; result["port"] = int(port)
            result["method"] = method; result["password"] = password
        else:
            decoded = b64decode(body)
            if "@" in decoded:
                method_pass, host_port = decoded.split("@", 1)
                method, password = method_pass.split(":", 1)
                host, port = host_port.split(":")
                result["address"] = host; result["port"] = int(port)
                result["method"] = method; result["password"] = password
    elif link.startswith("vless://"):
        result["protocol"] = "vless"
        parsed = urllib.parse.urlparse(link)
        result["uuid"] = parsed.username; result["address"] = parsed.hostname; result["port"] = parsed.port
        result["tag_comment"] = urllib.parse.unquote(parsed.fragment)
        params = urllib.parse.parse_qs(parsed.query)
        for k in ["encryption","security","flow","sni","pbk","sid","fp","type","spiderx"]:
            result[k] = params.get(k, ["" if k not in ["encryption","type"] else ("none" if k=="encryption" else "tcp")])[0]
    else: result["error"] = "Unsupported scheme"
    print(json.dumps(result))
except Exception as e:
    print(json.dumps({"error": str(e)}))
' "$1"
}

routing_add_outbound() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then die "配置文件不存在"; fi
    echo "================ 添加 Outbound 节点 ================"
    local tag
    while true; do
        read -rp "请输入节点唯一 Tag: " tag
        [[ -z "$tag" ]] && continue
        if jq -e --arg t "$tag" '.outbounds[] | select(.tag == $t)' "$XRAY_CONFIG" >/dev/null 2>&1; then
            echo -e "${RED}Tag '$tag' 已存在${PLAIN}"
        else break; fi
    done
    echo "请选择节点类型:"
    echo "  1) Socks   2) Shadowsocks   3) VLESS"
    read -rp "选择 (1-3): " type_choice
    local outbound_json=""
    case "$type_choice" in
        1)
            read -rp "地址: " addr; read -rp "端口: " port
            read -rp "用户名 (可留空): " user; read -rp "密码 (可留空): " pass
            outbound_json=$(jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" --arg user "$user" --arg pass "$pass" \
                '{ tag: $tag, protocol: "socks", settings: { servers: [{ address: $addr, port: $port, users: (if $user != "" then [{user: $user, pass: $pass}] else [] end) }] } }')
            ;;
        2)
            echo "添加方式: 1) 粘贴链接  2) 手动输入"
            read -rp "选择 (1/2): " ss_m
            if [[ "$ss_m" == "1" ]]; then
                read -rp "请输入 SS 分享链接: " link
                local parsed; parsed=$(routing_parse_link_py "$link")
                if echo "$parsed" | grep -q '"error"'; then die "解析失败: $(echo "$parsed" | jq -r '.error')"; fi
                local addr method pass port
                addr=$(echo "$parsed" | jq -r '.address'); port=$(echo "$parsed" | jq -r '.port')
                method=$(echo "$parsed" | jq -r '.method'); pass=$(echo "$parsed" | jq -r '.password')
                info "解析成功: $method@$addr:$port"
                outbound_json=$(jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" --arg method "$method" --arg pass "$pass" \
                    '{ tag: $tag, protocol: "shadowsocks", settings: { servers: [{ address: $addr, port: $port, method: $method, password: $pass, level: 1 }] } }')
            else
                read -rp "地址: " addr; read -rp "端口: " port
                echo "加密方式: 1)aes-128-gcm 2)aes-256-gcm 3)chacha20-ietf-poly1305 4)2022-blake3-aes-128-gcm 5)2022-blake3-aes-256-gcm 6)2022-blake3-chacha20-poly1305"
                read -rp "选择: " m_idx
                local methods=("aes-128-gcm" "aes-256-gcm" "chacha20-ietf-poly1305" "2022-blake3-aes-128-gcm" "2022-blake3-aes-256-gcm" "2022-blake3-chacha20-poly1305")
                local method="${methods[$((m_idx-1))]}"
                [[ -z "$method" ]] && die "无效选择"
                read -rp "密码: " pass
                outbound_json=$(jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" --arg method "$method" --arg pass "$pass" \
                    '{ tag: $tag, protocol: "shadowsocks", settings: { servers: [{ address: $addr, port: $port, method: $method, password: $pass }] }, streamSettings: { network: "tcp" } }')
            fi
            ;;
        3)
            read -rp "请输入 VLESS 分享链接: " link
            local parsed; parsed=$(routing_parse_link_py "$link")
            if echo "$parsed" | grep -q '"error"'; then die "解析失败: $(echo "$parsed" | jq -r '.error')"; fi
            local addr port uuid encryption security flow sni pbk sid fp type spiderx
            addr=$(echo "$parsed" | jq -r '.address'); port=$(echo "$parsed" | jq -r '.port')
            uuid=$(echo "$parsed" | jq -r '.uuid'); encryption=$(echo "$parsed" | jq -r '.encryption')
            security=$(echo "$parsed" | jq -r '.security'); flow=$(echo "$parsed" | jq -r '.flow')
            sni=$(echo "$parsed" | jq -r '.sni'); pbk=$(echo "$parsed" | jq -r '.pbk')
            sid=$(echo "$parsed" | jq -r '.sid'); fp=$(echo "$parsed" | jq -r '.fp')
            type=$(echo "$parsed" | jq -r '.type'); spiderx=$(echo "$parsed" | jq -r '.spiderx')
            info "解析成功: VLESS $uuid@$addr:$port"
            outbound_json=$(jq -n \
                --arg tag "$tag" --arg addr "$addr" --argjson port "$port" --arg uuid "$uuid" \
                --arg encryption "$encryption" --arg security "$security" --arg flow "$flow" \
                --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg fp "$fp" \
                --arg type "$type" --arg spiderx "$spiderx" \
                '{ tag: $tag, protocol: "vless",
                   settings: { vnext: [{ address: $addr, port: $port, users: [{ id: $uuid, encryption: $encryption, flow: (if $flow == "" then null else $flow end) }] }] },
                   streamSettings: { network: $type,
                       security: (if $security == "none" then null else $security end),
                       realitySettings: (if $security == "reality" then { serverName: $sni, publicKey: $pbk, shortId: $sid, fingerprint: $fp, spiderX: (if $spiderx != "" then $spiderx else null end) } else null end),
                       tlsSettings: (if $security == "tls" then { serverName: $sni } else null end)
                   }
                 } | del(.streamSettings.realitySettings | select(. == null)) | del(.streamSettings.realitySettings.spiderX | select(. == null)) | del(.streamSettings.tlsSettings | select(. == null)) | del(.streamSettings.security | select(. == null))')
            ;;
        *) die "无效选择" ;;
    esac
    local tmp_conf; tmp_conf=$(mktemp)
    jq --argjson new "$outbound_json" '.outbounds += [$new]' "$XRAY_CONFIG" > "$tmp_conf" && mv "$tmp_conf" "$XRAY_CONFIG"
    chmod 600 "$XRAY_CONFIG"
    info "已添加 Outbound: $tag"
    restart_xray_service || true
}

routing_add_routing() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then die "配置文件不存在"; fi
    echo "================ 添加分流规则 ================"
    echo "当前 Inbounds:"
    jq -r '.inbounds[] | " - " + .tag' "$XRAY_CONFIG"
    echo ""
    read -rp "请输入 Inbound Tags (逗号分隔，留空=所有): " in_tags_raw
    local in_tags_json="null"
    if [[ -n "$in_tags_raw" ]]; then
        in_tags_json=$(echo "$in_tags_raw" | jq -R 'split(",") | map(gsub(" "; "")) | map(select(length > 0))')
    fi
    echo "请输入分流条件 (逗号分隔，回车跳过):"
    read -rp "1) IP/CIDR (如 geoip:cn): " ip_raw
    read -rp "2) Domain (如 geosite:cn): " domain_raw
    if [[ -z "$ip_raw" && -z "$domain_raw" ]]; then die "至少输入一个条件"; fi
    local ip_json="null" domain_json="null"
    [[ -n "$ip_raw" ]] && ip_json=$(echo "$ip_raw" | jq -R 'split(",") | map(gsub(" "; "")) | map(select(length > 0))')
    [[ -n "$domain_raw" ]] && domain_json=$(echo "$domain_raw" | jq -R 'split(",") | map(gsub(" "; "")) | map(select(length > 0))')
    echo "当前 Outbounds:"
    jq -r '.outbounds[] | " - " + .tag' "$XRAY_CONFIG"
    echo ""
    local out_tag
    while true; do
        read -rp "请输入目标 Outbound Tag: " out_tag
        jq -e --arg t "$out_tag" '.outbounds[] | select(.tag == $t)' "$XRAY_CONFIG" >/dev/null 2>&1 && break
        echo -e "${RED}Tag 不存在${PLAIN}"
    done
    local rule_json
    rule_json=$(jq -n --argjson inbounds "$in_tags_json" --arg outbound "$out_tag" --argjson ip "$ip_json" --argjson domain "$domain_json" \
        '{ type: "field", inboundTag: $inbounds, outboundTag: $outbound, ip: $ip, domain: $domain } | del(.ip | select(. == null)) | del(.domain | select(. == null)) | del(.inboundTag | select(. == null))')
    local tmp_conf; tmp_conf=$(mktemp)
    jq --argjson rule "$rule_json" '
        if .routing == null then .routing = {rules: []} else . end |
        if .routing.rules == null then .routing.rules = [] else . end |
        .routing.rules += [$rule]
    ' "$XRAY_CONFIG" > "$tmp_conf" && mv "$tmp_conf" "$XRAY_CONFIG"
    chmod 600 "$XRAY_CONFIG"
    info "分流规则添加成功！"
    restart_xray_service || true
}

routing_query_inbounds() {
    echo "================ Inbounds ================"
    printf "%-25s %-15s %-10s\n" "Tag" "Protocol" "Port"
    echo "------------------------------------------------"
    jq -r '.inbounds[] | "\(.tag)\t\(.protocol)\t\(.port)"' "$XRAY_CONFIG" | while IFS=$'\t' read -r tag proto port; do
        printf "%-25s %-15s %-10s\n" "$tag" "$proto" "$port"
    done
}

routing_query_outbounds() {
    echo "================ Outbounds ================"
    printf "%-20s %-15s %-25s %-10s\n" "Tag" "Protocol" "Address" "Port"
    echo "----------------------------------------------------------------------"
    jq -r '.outbounds[] |
        "\(.tag)\t\(.protocol)\t\(if .settings.servers then .settings.servers[0].address else (.settings.vnext[0].address // "N/A") end)\t\(if .settings.servers then .settings.servers[0].port else (.settings.vnext[0].port // "N/A") end)"' "$XRAY_CONFIG" | \
    while IFS=$'\t' read -r tag proto addr port; do
        printf "%-20s %-15s %-25s %-10s\n" "$tag" "$proto" "$addr" "$port"
    done
}

routing_query_routing() {
    echo "================ Routing 规则 ================"
    echo "ID | Source(Inbounds) | IP | Domain | -> Target"
    echo "---------------------------------------------------------------------"
    jq -r '.routing.rules[]? |
        "\(.inboundTag // ["ALL"] | join(",")) | \(.ip // [] | join(",")) | \(.domain // [] | join(",")) | \(.outboundTag)"' "$XRAY_CONFIG" | nl -w 2 -s " | "
}

# --- Routing 子菜单 ---
module_routing_menu() {
    while true; do
        clear
        echo "================================================="
        echo "       Xray 服务端分流配置 (Routing)"
        echo "================================================="
        echo "  1. 安装 Geo 文件 (配置每日自动更新)"
        echo "  2. 添加 Outbounds (Socks / SS / VLESS)"
        echo "  3. 添加 Routing (配置分流规则)"
        echo "  4. 查询已有 Inbounds"
        echo "  5. 查询已有 Outbounds"
        echo "  6. 查询已有 Routing"
        echo "  0. 返回主菜单"
        echo "================================================="
        read -rp "请输入选项 [0-6]: " num
        case "$num" in
            1) module_update_geo ;;
            2) routing_add_outbound ;;
            3) routing_add_routing ;;
            4) routing_query_inbounds ;;
            5) routing_query_outbounds ;;
            6) routing_query_routing ;;
            0) return ;;
            *) error "无效输入"; sleep 1 ;;
        esac
        pause_return
    done
}

# ============================================================
# 第九部分：卸载模块
# ============================================================

module_uninstall() {
    echo "================ 卸载 Xray ================"
    read -rp "确定要卸载 Xray 吗？[y/N]: " confirm
    [[ ! $confirm =~ ^[yY]$ ]] && { info "已取消"; return; }

    # 停止服务
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        # 收集所有 xray 相关 unit
        local units=()
        while IFS= read -r u; do
            [[ -n "$u" ]] && units+=("$u")
        done < <(systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -iE 'xray' || true)
        for u in "${units[@]}"; do
            systemctl stop "$u" --no-block 2>/dev/null || true
            systemctl disable "$u" 2>/dev/null || true
        done
        rm -f /etc/systemd/system/*xray*.service /lib/systemd/system/*xray*.service
        systemctl daemon-reload
    elif command -v rc-service >/dev/null 2>&1 && [[ -f /etc/init.d/xray ]]; then
        rc-service xray stop || true
        rc-update del xray default || true
        rm -f /etc/init.d/xray
        rm -f /run/xray.pid
    fi

    # 备份配置
    if [[ -d /usr/local/etc/xray ]]; then
        local backup="/root/xray-config-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        info "备份配置到 $backup"
        tar -czf "$backup" -C /usr/local/etc xray 2>/dev/null || true
    fi

    # 删除文件
    rm -f "$XRAY_BIN"
    read -rp "是否删除配置文件和日志？[y/N]: " del_conf
    if [[ $del_conf =~ ^[yY]$ ]]; then
        rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
        rm -f "$ADDRESS_FILE"
        rm -f /root/xray_*.txt
        success "Xray 及配置已完全卸载"
    else
        success "Xray 程序已卸载，配置保留"
    fi
}

# ============================================================
# 第十部分：配置还原模块
# ============================================================

restore_from_url() {
    echo "================ 从 URL 还原配置 ================"
    read -rp "请输入 config.json 直链地址: " url
    [[ -z "$url" ]] && { warn "地址不能为空"; return; }
    info "正在下载..."
    local tmp_file; tmp_file="$(mktemp)"
    if curl -fsSL -o "$tmp_file" "$url"; then
        if grep -q "^[[:space:]]*{" "$tmp_file"; then
            if [[ -f "$XRAY_CONFIG" ]]; then
                cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
                info "旧配置已备份"
            fi
            mkdir -p "$(dirname "$XRAY_CONFIG")"
            mv "$tmp_file" "$XRAY_CONFIG"
            chmod 600 "$XRAY_CONFIG"
            info "配置文件已保存到: $XRAY_CONFIG"
            info "建议测试配置 (选项 3)"
        else
            warn "不是有效 JSON，已取消"; rm -f "$tmp_file"
        fi
    else
        error "下载失败"; rm -f "$tmp_file"
    fi
}

restore_manual() {
    echo "================ 手动编辑配置 ================"
    if [[ -f "$XRAY_CONFIG" ]]; then
        cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        info "旧配置已备份"
    fi
    mkdir -p "$(dirname "$XRAY_CONFIG")"
    local editor
    if command -v nano >/dev/null 2>&1; then editor="nano"
    elif command -v vi >/dev/null 2>&1; then editor="vi"
    else die "未找到可用编辑器 (nano/vi)"; fi
    info "即将打开 $editor 编辑 config.json..."
    read -n 1 -s -r -p "按任意键开始编辑..." || true
    $editor "$XRAY_CONFIG"
    chmod 600 "$XRAY_CONFIG"
    info "编辑完成。建议测试配置 (选项 3)"
}

restore_test_config() {
    echo "================ 测试配置文件 ================"
    [[ ! -f "$XRAY_CONFIG" ]] && { error "配置文件不存在"; return; }
    [[ ! -f "$XRAY_BIN" ]]   && { error "Xray 未安装"; return; }
    info "正在执行: xray -config ... -test"
    echo "------------------------------------------------"
    "$XRAY_BIN" -config "$XRAY_CONFIG" -test
    local ret=$?
    echo "------------------------------------------------"
    if [[ $ret -eq 0 ]]; then
        echo -e "${GREEN}配置文件测试通过！${PLAIN}"
    else
        echo -e "${RED}配置文件有错误！请检查上方信息。${PLAIN}"
    fi
}

# --- Restore 子菜单 ---
module_restore_menu() {
    while true; do
        clear
        echo -e "${CYAN}=================================================${PLAIN}"
        echo -e "${CYAN}       Xray 配置还原工具${PLAIN}"
        echo -e "${CYAN}=================================================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 从 URL 下载 config.json"
        echo -e "  ${GREEN}2.${PLAIN} 手动编辑 config.json"
        echo -e "  ${YELLOW}3.${PLAIN} 试运行测试配置"
        echo -e "  ${RED}0.${PLAIN} 返回主菜单"
        echo -e "${CYAN}=================================================${PLAIN}"
        read -rp "请输入选项 [0-3]: " choice
        case "$choice" in
            1) restore_from_url ;;
            2) restore_manual ;;
            3) restore_test_config ;;
            0) return ;;
            *) error "无效输入"; sleep 1 ;;
        esac
        pause_return
    done
}

# ============================================================
# 第十一部分：公共配置写入辅助
# ============================================================

_append_inbound() {
    local inbound_json="$1"
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        info "配置文件不存在，创建新配置..."
        mkdir -p "$(dirname "$XRAY_CONFIG")"
        echo '{ "log": { "loglevel": "warning" }, "inbounds": [], "outbounds": [{ "protocol": "freedom", "settings": {"domainStrategy": "AsIs"}, "tag": "direct" }, { "protocol": "blackhole", "tag": "blocked" }] }' > "$XRAY_CONFIG"
    fi
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
    local temp_file; temp_file=$(mktemp)
    jq --argjson new "$inbound_json" '
        if .inbounds == null then .inbounds = [] else . end |
        .inbounds += [$new]
    ' "$XRAY_CONFIG" > "$temp_file" && mv "$temp_file" "$XRAY_CONFIG"
    chmod 600 "$XRAY_CONFIG"
    success "配置已安全追加到: $XRAY_CONFIG"
}

# ============================================================
# 第十二部分：查看日志
# ============================================================

module_view_log() {
    [[ ! -f "$XRAY_BIN" ]] && { error "Xray 未安装"; return; }
    info "显示 Xray 实时日志... 按 Ctrl+C 停止"
    trap 'echo -e "\n日志查看已停止。"' SIGINT
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u xray -f --no-pager || true
    elif [[ -d /var/log/xray ]]; then
        tail -n 200 -F /var/log/xray/*.log 2>/dev/null || true
    else
        error "无法找到日志"
    fi
    trap - SIGINT
}

module_update_manager_script() {
    echo "================ 手动更新管理脚本 ================"
    echo "更新源: $SCRIPT_UPDATE_URL"
    read -rp "确认从该地址更新当前脚本吗？[y/N]: " confirm
    [[ ! $confirm =~ ^[yY]$ ]] && { info "已取消更新"; return; }

    local self_path tmp backup
    self_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    tmp="$(mktemp)"

    info "正在下载新版本..."
    if ! curl -fsSL "$SCRIPT_UPDATE_URL" -o "$tmp"; then
        rm -f "$tmp"
        error "下载失败，请检查网络或仓库地址。"
        return 1
    fi

    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        error "下载文件语法校验失败，已中止更新。"
        return 1
    fi

    chmod +x "$tmp"
    if [[ -f "$self_path" ]]; then
        backup="${self_path}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$self_path" "$backup"
        info "已备份当前脚本: $backup"
    fi

    if mv "$tmp" "$self_path"; then
        success "更新成功：$self_path"
        info "请重新运行脚本以加载新版本。"
    else
        rm -f "$tmp"
        error "写入失败：$self_path"
        return 1
    fi
}

install_frank_manager_command() {
    local self_path target
    self_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    target="/usr/local/sbin/frank"
    [[ ! -f "$self_path" ]] && { error "当前脚本路径无效: $self_path"; return 1; }

    cp "$self_path" "$target"
    chmod 755 "$target"
    ln -sf "$target" /usr/local/bin/frank
    success "一级总控命令已安装: frank"
}

install_xray_manager_command() {
    require_xray_branch_available || return 1

    local self_path target
    self_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    target="/usr/local/sbin/xray-m"
    [[ ! -f "$self_path" ]] && { error "当前脚本路径无效: $self_path"; return 1; }

    cp "$self_path" "$target"
    chmod 755 "$target"
    ln -sf "$target" /usr/local/bin/xray-m
    success "Xray 分支命令已安装: xray-m"
}

remove_xray_manager_command() {
    local removed=0
    for p in /usr/local/sbin/xray-m /usr/local/bin/xray-m; do
        if [[ -e "$p" ]]; then
            rm -f "$p"
            removed=1
        fi
    done
    if [[ $removed -eq 1 ]]; then
        success "xray-m 命令已删除"
    else
        info "未发现 xray-m 命令，无需删除"
    fi
}

cleanup_manager_environment() {
    read -rp "将清理 Geo 定时任务、网络优化配置、临时日志等痕迹，继续吗？[y/N]: " confirm
    [[ ! $confirm =~ ^[yY]$ ]] && { info "已取消"; return; }

    rm -f /root/update_geo_local.sh /var/log/update_geo.log

    local tmp_cron
    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "update_geo_local.sh" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron"

    if [[ -f "$NETWORK_TUNING_CONF" ]]; then
        rm -f "$NETWORK_TUNING_CONF"
        sysctl --system >/dev/null 2>&1 || true
    fi

    success "环境清理完成"
}

cleanup_xray_branch_fully() {
    read -rp "将彻底清理 Xray 分支痕迹（xray/xray-m/配置/日志/定时任务），继续吗？[y/N]: " confirm
    [[ ! $confirm =~ ^[yY]$ ]] && { info "已取消"; return; }

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        local units=()
        while IFS= read -r u; do
            [[ -n "$u" ]] && units+=("$u")
        done < <(systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -iE 'xray' || true)
        for u in "${units[@]}"; do
            systemctl stop "$u" --no-block 2>/dev/null || true
            systemctl disable "$u" 2>/dev/null || true
        done
        rm -f /etc/systemd/system/*xray*.service /lib/systemd/system/*xray*.service
        systemctl daemon-reload || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service xray stop 2>/dev/null || true
        rc-update del xray default 2>/dev/null || true
        rm -f /etc/init.d/xray /run/xray.pid
    fi

    rm -f "$XRAY_BIN" /usr/local/sbin/xray-m /usr/local/bin/xray-m
    rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
    rm -f "$ADDRESS_FILE" /root/xray_*.txt /root/xray-config-backup-*.tar.gz

    rm -f /root/update_geo_local.sh /var/log/update_geo.log
    local tmp_cron
    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "update_geo_local.sh" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron"

    if [[ -f "$NETWORK_TUNING_CONF" ]]; then
        rm -f "$NETWORK_TUNING_CONF"
        sysctl --system >/dev/null 2>&1 || true
    fi

    success "Xray 分支已彻底清理完成"
}

remove_current_script_file() {
    local self_path
    self_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    read -rp "确认删除当前脚本文件 $self_path 吗？[y/N]: " confirm
    [[ ! $confirm =~ ^[yY]$ ]] && { info "已取消"; return; }

    rm -f "$self_path"
    success "当前脚本文件已删除"
    info "如果你还需要管理器，请重新下载并安装 frank。"
    exit 0
}

module_manager_cleanup_menu() {
    while true; do
        clear
        echo "================================================="
        echo "      管理器命令与环境清理"
        echo "================================================="
        echo "  1. 安装/修复 xray-m 命令"
        echo "  2. 删除 xray-m 命令"
        echo "  3. 清理脚本改动的环境项"
        echo "  4. 删除当前脚本文件"
        echo "  0. 返回主菜单"
        echo "================================================="
        read -rp "请输入选项 [0-4]: " c
        case "$c" in
            1) install_xray_manager_command ;;
            2) remove_xray_manager_command ;;
            3) cleanup_manager_environment ;;
            4) remove_current_script_file ;;
            0) return ;;
            *) error "无效输入" ;;
        esac
        pause_return
    done
}

deploy_pfw_gz() {
    require_pfw_branch_available || return 1

    info "开始部署广州版 PFW（规则管理 + 账本）..."
    install_packages nftables gawk

    mkdir -p /etc/pfwd /etc/nftables.d
    touch /etc/pfwd/rules.tsv /etc/pfwd/usage.tsv

    cat > /etc/nftables.conf <<'NF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.nft"
NF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nftables >/dev/null 2>&1 || true
    fi

    cat > /usr/local/bin/pfwd <<'PFWD'
#!/usr/bin/env bash
set -euo pipefail
RULES="/etc/pfwd/rules.tsv"
NFT_NAT="/etc/nftables.d/pfwd.nft"
NFT_STAT="/etc/nftables.d/pfwd_stat.nft"
TABLE_NAT="pfwd_nat"
TABLE_STAT="pfwd_stat"
mkdir -p /etc/pfwd /etc/nftables.d
touch "$RULES"
next_id(){ [[ -s "$RULES" ]] || { echo 1; return; }; awk -F'\t' 'BEGIN{m=0}$1+0>m{m=$1}END{print m+1}' "$RULES"; }
ask(){ read -rp "$1" v; [[ "$v" =~ ^[Qq]$ ]] && return 1; echo "$v"; }
confirm(){ read -rp "${1:-确认执行?} [y/N]: " c; [[ "$c" == "y" || "$c" == "Y" ]]; }
list_rules(){
  echo "==== 当前规则（TCP+UDP）===="
  [[ -s "$RULES" ]] || { echo "(空)"; return; }
  printf "%-4s %-7s %-8s %-18s %-8s %-20s\n" "ID" "PROTO" "LPORT" "DEST_IP" "DPORT" "NOTE"
  awk -F'\t' '{n=$6;if(n=="")n="-";printf "%-4s %-7s %-8s %-18s %-8s %-20s\n",$1,$2,$3,$4,$5,n}' "$RULES"
}
gen_nat(){
  {
    echo "table ip $TABLE_NAT {"
    echo "  chain prerouting { type nat hook prerouting priority dstnat; policy accept;"
    while IFS=$'\t' read -r id proto lp ip dp note; do
      [[ -n "${id:-}" ]] || continue
      echo "    tcp dport $lp counter dnat to $ip:$dp comment \"pfwd:$id:tcp\""
      echo "    udp dport $lp counter dnat to $ip:$dp comment \"pfwd:$id:udp\""
    done < "$RULES"
    echo "  }"
    echo "  chain postrouting { type nat hook postrouting priority srcnat; policy accept;"
    while IFS=$'\t' read -r id proto lp ip dp note; do
      [[ -n "${id:-}" ]] || continue
      echo "    ip daddr $ip tcp dport $dp counter masquerade comment \"pfwd:$id:tcp\""
      echo "    ip daddr $ip udp dport $dp counter masquerade comment \"pfwd:$id:udp\""
    done < "$RULES"
    echo "  }"
    echo "}"
  } > /tmp/pfwd_nat.nft
}
gen_stat(){
  {
    echo "table inet $TABLE_STAT {"
    echo "  chain forward { type filter hook forward priority filter; policy accept;"
    while IFS=$'\t' read -r id proto lp ip dp note; do
      [[ -n "${id:-}" ]] || continue
      echo "    ip daddr $ip tcp dport $dp counter comment \"pfwd:$lp:tcp:up\""
      echo "    ip saddr $ip tcp sport $dp counter comment \"pfwd:$lp:tcp:down\""
      echo "    ip daddr $ip udp dport $dp counter comment \"pfwd:$lp:udp:up\""
      echo "    ip saddr $ip udp sport $dp counter comment \"pfwd:$lp:udp:down\""
    done < "$RULES"
    echo "  }"
    echo "}"
  } > /tmp/pfwd_stat.nft
}
apply_rules(){
  confirm "将重建 NAT+STAT 规则，继续吗？" || { echo "已取消"; return; }
  command -v pfwd-acct >/dev/null 2>&1 && pfwd-acct sync >/dev/null 2>&1 || true
  gen_nat; gen_stat
  nft delete table ip "$TABLE_NAT" 2>/dev/null || true
  nft delete table inet "$TABLE_STAT" 2>/dev/null || true
  cp /tmp/pfwd_nat.nft "$NFT_NAT"
  cp /tmp/pfwd_stat.nft "$NFT_STAT"
  nft -f "$NFT_NAT"
  nft -f "$NFT_STAT"
  command -v systemctl >/dev/null 2>&1 && systemctl enable nftables >/dev/null 2>&1 || true
  echo "✅ 已应用（NAT+STAT，TCP+UDP）"
}
add_rule(){
  echo "添加规则（默认TCP+UDP，q取消）"
  lp=$(ask "本机监听端口: ") || { echo "已取消"; return; }
  ip=$(ask "目标IP/域名: ") || { echo "已取消"; return; }
  dp=$(ask "目标端口: ") || { echo "已取消"; return; }
  note=$(ask "备注(可空): ") || { echo "已取消"; return; }
  [[ "$lp" =~ ^[0-9]+$ && "$dp" =~ ^[0-9]+$ ]] || { echo "端口无效"; return; }
  ((lp>=1 && lp<=65535 && dp>=1 && dp<=65535)) || { echo "端口范围无效"; return; }
  id=$(next_id)
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$id" "both" "$lp" "$ip" "$dp" "$note" >> "$RULES"
  echo "✅ 已添加 ID=$id"
}
edit_rule(){
  list_rules
  id=$(ask "修改ID(q取消): ") || { echo "已取消"; return; }
  line=$(awk -F'\t' -v id="$id" '$1==id{print;exit}' "$RULES" || true)
  [[ -n "$line" ]] || { echo "ID不存在"; return; }
  IFS=$'\t' read -r _ proto lp ip dp note <<<"$line"
  nlp=$(ask "监听端口[$lp]: ") || { echo "已取消"; return; }; nlp=${nlp:-$lp}
  nip=$(ask "目标IP/域名[$ip]: ") || { echo "已取消"; return; }; nip=${nip:-$ip}
  ndp=$(ask "目标端口[$dp]: ") || { echo "已取消"; return; }; ndp=${ndp:-$dp}
  nno=$(ask "备注[$note]: ") || { echo "已取消"; return; }; nno=${nno:-$note}
  awk -F'\t' -v OFS='\t' -v id="$id" -v lp="$nlp" -v ip="$nip" -v dp="$ndp" -v no="$nno" '{if($1==id){$2="both";$3=lp;$4=ip;$5=dp;$6=no} print}' "$RULES" > /tmp/rules.tsv
  mv /tmp/rules.tsv "$RULES"
  echo "✅ 已修改"
}
del_rule(){
  list_rules
  id=$(ask "删除ID(q取消): ") || { echo "已取消"; return; }
  confirm "确认删除 ID=$id ?" || { echo "已取消"; return; }
  awk -F'\t' -v id="$id" '$1!=id' "$RULES" > /tmp/rules.tsv
  mv /tmp/rules.tsv "$RULES"
  echo "✅ 已删除"
}
show_live_nat(){ nft list table ip "$TABLE_NAT" || echo "(NAT表不存在)"; }
show_live_stat(){ nft list table inet "$TABLE_STAT" || echo "(STAT表不存在)"; }
while true; do
  echo
  echo "====== pfwd（广州版）======"
  echo "1) 查看规则"
  echo "2) 添加规则"
  echo "3) 修改规则"
  echo "4) 删除规则"
  echo "5) 应用规则"
  echo "6) 查看NAT实时规则"
  echo "7) 查看STAT实时规则"
  echo "0) 返回"
  read -rp "选择: " c
  case "$c" in
    1) list_rules ;;
    2) add_rule ;;
    3) edit_rule ;;
    4) del_rule ;;
    5) apply_rules ;;
    6) show_live_nat ;;
    7) show_live_stat ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
PFWD
    chmod +x /usr/local/bin/pfwd

    cat > /usr/local/bin/pfwd-acct <<'ACCT'
#!/usr/bin/env bash
set -euo pipefail
RULES="/etc/pfwd/rules.tsv"
USAGE="/etc/pfwd/usage.tsv"
TABLE="pfwd_stat"
MAX_DELTA=$((50*1024*1024*1024))
mkdir -p /etc/pfwd
touch "$RULES" "$USAGE"
today(){ date +%F; }
get_note(){ local p="$1"; awk -F'\t' -v p="$p" '$3==p{print $6;exit}' "$RULES"; }
ensure_port_row(){ local p="$1" n; grep -qE "^${p}[[:space:]]" "$USAGE" && return 0; n="$(get_note "$p")"; n="${n:--}"; printf "%s\t0\t0\t%s\t%s\n" "$p" "$(today)" "$n" >> "$USAGE"; }
sum_port_bytes(){
  local p="$1"
  nft -a list table inet "$TABLE" 2>/dev/null | awk -v p="$p" '/comment "pfwd:/ && $0 ~ ("pfwd:" p ":") {for(i=1;i<=NF;i++) if($i=="bytes"){s+=$(i+1)}} END{print s+0}'
}
sync_once(){
  [[ -s "$RULES" ]] || exit 0
  awk -F'\t' '{print $3}' "$RULES" | sort -un | while read -r p; do
    [[ -n "$p" ]] || continue
    ensure_port_row "$p"
    cur=$(sum_port_bytes "$p")
    line=$(awk -F'\t' -v p="$p" '$1==p{print;exit}' "$USAGE")
    IFS=$'\t' read -r _ total last reset note <<<"$line"
    total=${total:-0}; last=${last:-0}; reset=${reset:-$(today)}; note=${note:--}
    if (( cur < last )); then
      new_total=$total; new_last=$cur
    else
      delta=$((cur-last))
      if (( delta > MAX_DELTA )); then
        new_total=$total; new_last=$last
      else
        new_total=$((total+delta)); new_last=$cur
      fi
    fi
    awk -F'\t' -v OFS='\t' -v p="$p" -v t="$new_total" -v l="$new_last" -v r="$reset" -v n="$note" '{if($1==p){$2=t;$3=l;$4=r;$5=n} print}' "$USAGE" > /tmp/usage.tsv
    mv /tmp/usage.tsv "$USAGE"
  done
}
show_usage(){ sync_once || true; echo "PORT    TOTAL(GB)   RESET_DATE   NOTE"; awk -F'\t' '{printf "%-7s %-10.3f %-12s %s\n",$1,$2/1024/1024/1024,$4,$5}' "$USAGE" | sort -n; }
reset_port(){ read -rp "端口: " p; awk -F'\t' -v OFS='\t' -v p="$p" '{if($1==p){$2=0;$3=0;$4=strftime("%Y-%m-%d")} print}' "$USAGE" > /tmp/usage.tsv; mv /tmp/usage.tsv "$USAGE"; echo "✅ 已重置 $p"; }
set_reset_date(){ read -rp "端口: " p; read -rp "重置日期(YYYY-MM-DD): " d; awk -F'\t' -v OFS='\t' -v p="$p" -v d="$d" '{if($1==p){$4=d} print}' "$USAGE" > /tmp/usage.tsv; mv /tmp/usage.tsv "$USAGE"; echo "✅ 已设置 $p 重置日期为 $d"; }
set_total(){ read -rp "端口: " p; read -rp "总流量(GB): " g; b=$(awk -v g="$g" 'BEGIN{printf "%.0f", g*1024*1024*1024}'); awk -F'\t' -v OFS='\t' -v p="$p" -v b="$b" '{if($1==p){$2=b} print}' "$USAGE" > /tmp/usage.tsv; mv /tmp/usage.tsv "$USAGE"; echo "✅ 已设置 $p 总流量为 ${g}GB"; }
case "${1:-menu}" in
  sync) sync_once ;;
  show) show_usage ;;
  menu)
    while true; do
      echo
      echo "====== pfwd-acct（广州账本）======"
      echo "1) 查看累计流量"
      echo "2) 手动同步一次"
      echo "3) 重置端口流量"
      echo "4) 设置端口重置日期"
      echo "5) 手动修改端口总流量"
      echo "0) 返回"
      read -rp "选择: " c
      case "$c" in
        1) show_usage ;;
        2) sync_once; echo "✅ 已同步" ;;
        3) reset_port ;;
        4) set_reset_date ;;
        5) set_total ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
      esac
    done
    ;;
  *) echo "用法: pfwd-acct [sync|show|menu]" ;;
esac
ACCT
    chmod +x /usr/local/bin/pfwd-acct

    cat > /usr/local/bin/pfw <<'PFW'
#!/usr/bin/env bash
set -euo pipefail
while true; do
  echo
  echo "========== PFW =========="
  echo "1) 规则管理（pfwd）"
  echo "2) 账本统计（pfwd-acct）"
  echo "0) 退出"
  read -rp "选择: " c
  case "$c" in
    1) /usr/local/bin/pfwd ;;
    2) /usr/local/bin/pfwd-acct ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
PFW
    chmod +x /usr/local/bin/pfw

    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/pfwd-acct-sync.service <<'SVC'
[Unit]
Description=pfwd acct sync

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pfwd-acct sync
SVC

        cat > /etc/systemd/system/pfwd-acct-sync.timer <<'TMR'
[Unit]
Description=Run pfwd-acct sync every 60s

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=1s
Unit=pfwd-acct-sync.service

[Install]
WantedBy=timers.target
TMR

        systemctl daemon-reload
        systemctl enable --now pfwd-acct-sync.timer >/dev/null 2>&1 || true
    else
        local tmp_cron
        tmp_cron="$(mktemp)"
        crontab -l 2>/dev/null | grep -v "pfwd-acct sync" > "$tmp_cron" || true
        echo "* * * * * /usr/local/bin/pfwd-acct sync >/dev/null 2>&1" >> "$tmp_cron"
        crontab "$tmp_cron" || true
        rm -f "$tmp_cron"
    fi

    success "广州版 pfw 部署完成，命令：pfw"
}

deploy_pfw_hk() {
    require_pfw_branch_available || return 1

    info "开始部署香港版 PFW Lite（仅规则管理）..."
    install_packages nftables

    mkdir -p /etc/pfwd /etc/nftables.d
    touch /etc/pfwd/rules.tsv

    cat > /etc/nftables.conf <<'NF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.nft"
NF

    command -v systemctl >/dev/null 2>&1 && systemctl enable nftables >/dev/null 2>&1 || true

    cat > /usr/local/bin/pfwd <<'PFWD'
#!/usr/bin/env bash
set -euo pipefail
RULES="/etc/pfwd/rules.tsv"
NFT="/etc/nftables.d/pfwd.nft"
TABLE="pfwd_nat"
mkdir -p /etc/pfwd /etc/nftables.d
touch "$RULES"
next_id(){ [[ -s "$RULES" ]] || { echo 1; return; }; awk -F'\t' 'BEGIN{m=0}$1+0>m{m=$1}END{print m+1}' "$RULES"; }
ask(){ read -rp "$1" v; [[ "$v" =~ ^[Qq]$ ]] && return 1; echo "$v"; }
confirm(){ read -rp "${1:-确认执行?} [y/N]: " c; [[ "$c" == "y" || "$c" == "Y" ]]; }
list_rules(){
  echo "==== 当前转发规则（TCP+UDP） ===="
  [[ -s "$RULES" ]] || { echo "(空)"; return; }
  printf "%-4s %-7s %-10s %-22s %-10s %-20s\n" "ID" "PROTO" "LPORT" "DEST_IP" "DPORT" "NOTE"
  awk -F'\t' '{n=$6;if(n=="")n="-";printf "%-4s %-7s %-10s %-22s %-10s %-20s\n",$1,$2,$3,$4,$5,n}' "$RULES"
}
gen_nft(){
  {
    echo "table ip $TABLE {"
    echo "  chain prerouting { type nat hook prerouting priority dstnat; policy accept;"
    while IFS=$'\t' read -r id proto lp ip dp note; do
      [[ -n "${id:-}" ]] || continue
      echo "    tcp dport $lp counter dnat to $ip:$dp comment \"pfwd:$id:tcp\""
      echo "    udp dport $lp counter dnat to $ip:$dp comment \"pfwd:$id:udp\""
    done < "$RULES"
    echo "  }"
    echo "  chain postrouting { type nat hook postrouting priority srcnat; policy accept;"
    while IFS=$'\t' read -r id proto lp ip dp note; do
      [[ -n "${id:-}" ]] || continue
      echo "    ip daddr $ip tcp dport $dp counter masquerade comment \"pfwd:$id:tcp\""
      echo "    ip daddr $ip udp dport $dp counter masquerade comment \"pfwd:$id:udp\""
    done < "$RULES"
    echo "  }"
    echo "}"
  } > /tmp/pfwd.nft
}
apply_rules(){
  confirm "将重载 nft 规则，继续吗？" || { echo "已取消"; return; }
  gen_nft
  nft delete table ip "$TABLE" 2>/dev/null || true
  cp /tmp/pfwd.nft "$NFT"
  nft -f "$NFT"
  command -v systemctl >/dev/null 2>&1 && systemctl enable nftables >/dev/null 2>&1 || true
  echo "✅ 已应用（自动 TCP+UDP）"
}
add_rule(){
  echo "添加规则（默认TCP+UDP，输入 q 可取消）"
  lp=$(ask "本机监听端口: ") || { echo "已取消"; return; }
  ip=$(ask "目标IP/域名: ") || { echo "已取消"; return; }
  dp=$(ask "目标端口: ") || { echo "已取消"; return; }
  note=$(ask "备注(可空): ") || { echo "已取消"; return; }
  [[ "$lp" =~ ^[0-9]+$ && "$dp" =~ ^[0-9]+$ ]] || { echo "端口无效"; return; }
  ((lp>=1 && lp<=65535 && dp>=1 && dp<=65535)) || { echo "端口范围无效"; return; }
  id=$(next_id)
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$id" "both" "$lp" "$ip" "$dp" "$note" >> "$RULES"
  echo "✅ 已添加 ID=$id"
}
edit_rule(){
  list_rules
  id=$(ask "修改ID(输入q取消): ") || { echo "已取消"; return; }
  line=$(awk -F'\t' -v id="$id" '$1==id{print;exit}' "$RULES" || true)
  [[ -n "$line" ]] || { echo "ID不存在"; return; }
  IFS=$'\t' read -r _ proto lp ip dp note <<<"$line"
  nlp=$(ask "监听端口[$lp]: ") || { echo "已取消"; return; }; nlp=${nlp:-$lp}
  nip=$(ask "目标IP/域名[$ip]: ") || { echo "已取消"; return; }; nip=${nip:-$ip}
  ndp=$(ask "目标端口[$dp]: ") || { echo "已取消"; return; }; ndp=${ndp:-$dp}
  nno=$(ask "备注[$note]: ") || { echo "已取消"; return; }; nno=${nno:-$note}
  awk -F'\t' -v OFS='\t' -v id="$id" -v lp="$nlp" -v ip="$nip" -v dp="$ndp" -v no="$nno" '{if($1==id){$2="both";$3=lp;$4=ip;$5=dp;$6=no} print}' "$RULES" > /tmp/rules.tsv
  mv /tmp/rules.tsv "$RULES"
  echo "✅ 已修改"
}
del_rule(){
  list_rules
  id=$(ask "删除ID(输入q取消): ") || { echo "已取消"; return; }
  confirm "确认删除 ID=$id ?" || { echo "已取消"; return; }
  awk -F'\t' -v id="$id" '$1!=id' "$RULES" > /tmp/rules.tsv
  mv /tmp/rules.tsv "$RULES"
  echo "✅ 已删除"
}
show_live(){ nft list table ip "$TABLE" || echo "(表不存在，先应用规则)"; }
while true; do
  echo
  echo "====== pfwd lite（香港专用，TCP+UDP一体）======"
  echo "1) 查看规则"
  echo "2) 添加规则（自动TCP+UDP）"
  echo "3) 修改规则"
  echo "4) 删除规则"
  echo "5) 应用规则"
  echo "6) 查看nft实时规则"
  echo "0) 退出"
  read -rp "选择: " c
  case "$c" in
    1) list_rules ;;
    2) add_rule ;;
    3) edit_rule ;;
    4) del_rule ;;
    5) apply_rules ;;
    6) show_live ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
PFWD
    chmod +x /usr/local/bin/pfwd

    cat > /usr/local/bin/pfw <<'PFW'
#!/usr/bin/env bash
exec /usr/local/bin/pfwd
PFW
    chmod +x /usr/local/bin/pfw

    success "香港版 pfw lite 部署完成，命令：pfw"
}

remove_pfw_suite() {
    read -rp "确认移除 pfw/pfwd 及相关 systemd/cron 项吗？[y/N]: " confirm
    [[ ! $confirm =~ ^[yY]$ ]] && { info "已取消"; return; }

    rm -f /usr/local/bin/pfw /usr/local/bin/pfwd /usr/local/bin/pfwd-acct
    rm -f /etc/nftables.d/pfwd.nft /etc/nftables.d/pfwd_stat.nft

    nft delete table ip pfwd_nat 2>/dev/null || true
    nft delete table inet pfwd_stat 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now pfwd-acct-sync.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/pfwd-acct-sync.service /etc/systemd/system/pfwd-acct-sync.timer
        systemctl daemon-reload || true
    fi

    local tmp_cron
    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "pfwd-acct sync" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron"

    success "pfw 套件移除完成"
}

module_pfw_deploy_menu() {
    while true; do
        clear
        echo "================================================="
        echo "      PFW 套件部署"
        echo "================================================="
        echo "  1. 部署广州版 (规则+账本+定时同步)"
        echo "  2. 部署香港版 Lite (仅规则管理)"
        echo "  3. 移除 PFW 套件"
        echo "  0. 返回主菜单"
        echo "================================================="
        read -rp "请输入选项 [0-3]: " c
        case "$c" in
            1) deploy_pfw_gz ;;
            2) deploy_pfw_hk ;;
            3) remove_pfw_suite ;;
            0) return ;;
            *) error "无效输入" ;;
        esac
        pause_return
    done
}

# ============================================================
# 第十三部分：网络优化 (FQ / BBR)
# ============================================================

set_sysctl_key() {
    local key="$1" value="$2"
    touch "$NETWORK_TUNING_CONF"
    if grep -q "^${key}=" "$NETWORK_TUNING_CONF"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$NETWORK_TUNING_CONF"
    else
        echo "${key}=${value}" >> "$NETWORK_TUNING_CONF"
    fi
    sysctl -w "${key}=${value}" >/dev/null 2>&1 || true
}

show_network_tuning_status() {
    local qdisc cc avail_cc
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "unknown")

    echo "================ 当前网络优化状态 ================"
    echo "default_qdisc: $qdisc"
    echo "tcp_congestion_control: $cc"
    echo "available_congestion_control: $avail_cc"
    echo "配置文件: $NETWORK_TUNING_CONF"
}

enable_fq() {
    info "正在启用 FQ 队列调度..."
    set_sysctl_key "net.core.default_qdisc" "fq"
    if [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" == "fq" ]]; then
        success "FQ 已启用 (net.core.default_qdisc=fq)"
    else
        error "FQ 启用失败，请检查内核支持情况。"
        return 1
    fi
}

enable_bbr() {
    info "正在启用 BBR 拥塞控制..."

    # 先确保可用拥塞控制列表里有 bbr
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        modprobe tcp_bbr 2>/dev/null || true
    fi
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        error "当前内核不支持 BBR（available_congestion_control 中未发现 bbr）。"
        return 1
    fi

    # BBR 推荐配合 fq
    set_sysctl_key "net.core.default_qdisc" "fq"
    set_sysctl_key "net.ipv4.tcp_congestion_control" "bbr"

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == "bbr" ]]; then
        success "BBR 已启用，并已设置 FQ。"
    else
        error "BBR 启用失败，请检查内核与权限。"
        return 1
    fi
}

module_network_tuning_menu() {
    while true; do
        clear
        echo "================================================="
        echo "             网络优化 (FQ / BBR)"
        echo "================================================="
        echo "  1. 仅启用 FQ (default_qdisc=fq)"
        echo "  2. 启用 BBR + FQ (推荐)"
        echo "  3. 查看当前状态"
        echo "  0. 返回主菜单"
        echo "================================================="
        read -rp "请输入选项 [0-3]: " num
        case "$num" in
            1) enable_fq ;;
            2) enable_bbr ;;
            3) show_network_tuning_status ;;
            0) return ;;
            *) error "无效输入" ;;
        esac
        pause_return
    done
}

# ============================================================
# 第十四部分：分支化主菜单
# ============================================================

module_xray_operations_menu() {
    while true; do
        clear
        echo -e "${CYAN}=================================================${PLAIN}"
        echo -e "${CYAN}             Xray 功能菜单                      ${PLAIN}"
        echo -e "${CYAN}=================================================${PLAIN}"
        check_xray_status
        echo "-------------------------------------------------"
        echo -e "  ${GREEN}1.${PLAIN} Geo 文件更新"
        echo -e "  ${GREEN}2.${PLAIN} 安装/管理 Shadowsocks (2022)"
        echo -e "  ${GREEN}3.${PLAIN} 安装/管理 VLESS Reality"
        echo -e "  ${GREEN}4.${PLAIN} 安装/管理 VLESS Encryption (Post-Quantum)"
        echo -e "  ${YELLOW}5.${PLAIN} Xray 服务端分流配置 (Routing)"
        echo -e "  ${RED}6.${PLAIN} 卸载 Xray 及相关文件"
        echo -e "  ${CYAN}7.${PLAIN} 还原 Xray 配置 (Restore)"
        echo "-------------------------------------------------"
        echo -e "  ${MAGENTA}8.${PLAIN} 网络优化 (开启 FQ / BBR)"
        echo -e "  ${MAGENTA}9.${PLAIN} 重启 Xray 服务"
        echo -e "  ${MAGENTA}10.${PLAIN} 查看 Xray 日志"
        echo -e "  ${CYAN}0.${PLAIN} 返回上级"
        echo -e "${CYAN}=================================================${PLAIN}"
        read -rp " 请输入选项 [0-10]: " choice

        case "$choice" in
            1) module_update_geo; pause_return ;;
            2) module_ss_menu ;;
            3) module_reality_menu ;;
            4) module_pq_menu ;;
            5) module_routing_menu ;;
            6) module_uninstall; pause_return ;;
            7) module_restore_menu ;;
            8) module_network_tuning_menu ;;
            9) restart_xray_service; pause_return ;;
            10) module_view_log; pause_return ;;
            0) return ;;
            *) error "无效输入"; sleep 1 ;;
        esac
    done
}

module_xray_branch_menu() {
    while true; do
        clear
        echo -e "${CYAN}=================================================${PLAIN}"
        echo -e "${CYAN}                  Xray 分支                      ${PLAIN}"
        echo -e "${CYAN}=================================================${PLAIN}"
        echo -e "  分支状态: $(xray_branch_status_text)"
        check_xray_status
        echo "-------------------------------------------------"
        echo -e "  ${GREEN}1.${PLAIN} 安装/修复 xray-m 命令"
        echo -e "  ${GREEN}2.${PLAIN} 进入 Xray 功能菜单"
        echo -e "  ${YELLOW}3.${PLAIN} 手动更新当前脚本"
        echo -e "  ${RED}4.${PLAIN} 一键彻底清理 Xray 分支"
        echo -e "  ${CYAN}0.${PLAIN} 返回主菜单"
        echo -e "${CYAN}=================================================${PLAIN}"
        read -rp "请输入选项 [0-4]: " c
        case "$c" in
            1) install_xray_manager_command; pause_return ;;
            2)
                require_xray_branch_available || { pause_return; continue; }
                module_xray_operations_menu
                ;;
            3) module_update_manager_script; pause_return ;;
            4) cleanup_xray_branch_fully; pause_return ;;
            0) return ;;
            *) error "无效输入"; sleep 1 ;;
        esac
    done
}

module_pfw_branch_menu() {
    while true; do
        clear
        echo -e "${CYAN}=================================================${PLAIN}"
        echo -e "${CYAN}                  PFW 分支                       ${PLAIN}"
        echo -e "${CYAN}=================================================${PLAIN}"
        echo -e "  分支状态: $(pfw_branch_status_text)"
        echo "-------------------------------------------------"
        echo -e "  ${GREEN}1.${PLAIN} 部署广州版 (规则+账本+定时同步)"
        echo -e "  ${GREEN}2.${PLAIN} 部署香港版 Lite (仅规则管理)"
        echo -e "  ${RED}3.${PLAIN} 移除 PFW 套件"
        echo -e "  ${CYAN}0.${PLAIN} 返回主菜单"
        echo -e "${CYAN}=================================================${PLAIN}"
        read -rp "请输入选项 [0-3]: " c
        case "$c" in
            1) deploy_pfw_gz; pause_return ;;
            2) deploy_pfw_hk; pause_return ;;
            3) remove_pfw_suite; pause_return ;;
            0) return ;;
            *) error "无效输入"; sleep 1 ;;
        esac
    done
}

show_main_menu() {
    clear
    echo -e "${CYAN}=================================================${PLAIN}"
    echo -e "${CYAN}            网络工具总控菜单                    ${PLAIN}"
    echo -e "${CYAN}=================================================${PLAIN}"
    echo -e "  Xray 分支状态: $(xray_branch_status_text)"
    echo -e "  PFW  分支状态: $(pfw_branch_status_text)"
    echo "-------------------------------------------------"
    echo -e "  ${GREEN}1.${PLAIN} 进入 Xray 分支"
    echo -e "  ${GREEN}2.${PLAIN} 进入 PFW 分支"
    echo -e "  ${YELLOW}3.${PLAIN} 安装/修复 frank 一级命令"
    echo -e "  ${RED}4.${PLAIN} 一键彻底清理 Xray 分支"
    echo -e "  ${CYAN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}=================================================${PLAIN}"
}

# --- 入口 ---
main() {
    pre_check
    local entry_name
    entry_name="$(basename "$0")"

    if [[ "$entry_name" == "xray-m" ]]; then
        module_xray_branch_menu
        exit 0
    fi

    while true; do
        show_main_menu
        read -rp "请输入选项 [0-4]: " top_choice
        case "$top_choice" in
            1) module_xray_branch_menu ;;
            2) module_pfw_branch_menu ;;
            3) install_frank_manager_command; pause_return ;;
            4) cleanup_xray_branch_fully; pause_return ;;
            0) echo -e "${GREEN}再见！${PLAIN}"; exit 0 ;;
            *) error "无效输入"; sleep 1 ;;
        esac
    done
}

main "$@"
