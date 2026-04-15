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

# --- 全局变量 ---
OS_ID=""
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
    else
        OS_ID="unknown"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="unknown"
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
            apk update && apk add --no-cache "${missing[@]}" bash iproute2 coreutils
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
        else
            die "无法检测包管理器，请手动安装: ${missing[*]}"
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

# ============================================================
# 第十三部分：主菜单
# ============================================================

show_main_menu() {
    clear
    echo -e "${CYAN}=================================================${PLAIN}"
    echo -e "${CYAN}     Xray 本地管理工具 (已脱离远程仓库)          ${PLAIN}"
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
    echo -e "  ${MAGENTA}8.${PLAIN} 重启 Xray 服务"
    echo -e "  ${MAGENTA}9.${PLAIN} 查看 Xray 日志"
    echo -e "  ${CYAN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}=================================================${PLAIN}"
    read -rp " 请输入选项 [0-9]: " choice

    case "$choice" in
        1) module_update_geo ;;
        2) module_ss_menu ;;
        3) module_reality_menu ;;
        4) module_pq_menu ;;
        5) module_routing_menu ;;
        6) module_uninstall ;;
        7) module_restore_menu ;;
        8) restart_xray_service ;;
        9) module_view_log ;;
        0) echo -e "${GREEN}再见！${PLAIN}"; exit 0 ;;
        *) error "无效输入"; sleep 1 ;;
    esac
}

# --- 入口 ---
main() {
    pre_check
    while true; do
        show_main_menu
        # 子菜单模块自己处理 pause，主菜单的单次操作需要 pause
        case "$choice" in
            1|6|8|9) pause_return ;;
        esac
    done
}

main "$@"
