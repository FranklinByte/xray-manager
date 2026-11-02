#!/usr/bin/env bash
# Install only the Xray manager. Core installation is an explicit menu action.
set -euo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '请使用 root 运行。' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
curl -fsSL --retry 3 -H 'Cache-Control: no-cache' \
    "https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh?ts=$(date +%s)" \
    -o "$tmp/xray-m"
bash -n "$tmp/xray-m"
grep -q '^install_xray_manager_command()' "$tmp/xray-m"
if [[ -f /usr/local/sbin/xray-m ]]; then
    backup=$(mktemp -d /var/tmp/xray-manager-before-install.XXXXXX)
    chmod 700 "$backup"
    cp -p /usr/local/sbin/xray-m "$backup/xray-m"
    echo "旧管理脚本备份：$backup/xray-m"
fi
bash "$tmp/xray-m" --install
echo '安装完成。运行 xray-m 管理 Xray。'
