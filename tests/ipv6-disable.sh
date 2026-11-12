#!/usr/bin/env bash
# Fixture-only: all filesystem paths and kernel/service commands are isolated.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
suite=$(mktemp -d)
trap 'rm -rf -- "$suite"' EXIT

test_case() (
    scenario=$1
    root="$suite/$scenario"
    mkdir -p "$root/etc/network/interfaces.d" "$root/proc/conf/"{all,default,lo,eth0}
    for key in all default lo eth0; do echo 0 > "$root/proc/conf/$key/disable_ipv6"; done
    source <(sed -e "s|/etc/network/|$root/etc/network/|g" \
        -e "s|/etc/sysctl.d/99-xray-disable-ipv6.conf|$root/etc/disable-ipv6.conf|g" \
        -e "s|/var/backups/xray-manager/ipv6|$root/backups|g" \
        -e "s|/proc/sys/net/ipv6|$root/proc|g" "$repo/xray_manager.sh")
    cat > "$root/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 192.0.2.10/24
    gateway 192.0.2.1

iface eth0 inet6 static
    address 2001:db8::10/64
    gateway 2001:db8::1
    up ip -6 addr add 2001:db8::11/64 dev eth0

source /etc/network/interfaces.d/*
EOF
    cat > "$root/etc/network/interfaces.d/extra" <<'EOF'
iface eth1 inet6 dhcp
    accept_ra 2

iface eth1 inet dhcp
    metric 50
EOF
    cp "$root/etc/network/interfaces" "$root/original"
    cp "$root/etc/network/interfaces.d/extra" "$root/original-extra"
    INIT_SYSTEM=systemd
    SSH_CONNECTION='198.51.100.2 53000 192.0.2.10 17788'
    sysctl() {
        if [[ "$1" == -a ]]; then
            echo 'net.ipv6.conf.all.disable_ipv6 = 0'
        elif [[ "$1" == -p ]]; then
            [[ "$scenario" != apply-fail ]] || return 1
            for key in all default lo eth0; do echo 1 > "$root/proc/conf/$key/disable_ipv6"; done
        else
            echo 'net.ipv6.conf.all.disable_ipv6 = 0'
            echo 'net.ipv6.conf.default.disable_ipv6 = 0'
        fi
    }
    ip() {
        [[ "$2" != address ]] && return 0
        [[ "$scenario" != status-fail || $(cat "$root/proc/conf/all/disable_ipv6") != 1 ]] || return 1
        [[ $(cat "$root/proc/conf/all/disable_ipv6") != 0 ]] || echo '    inet6 2001:db8::10/64 scope global'
        [[ "$scenario" != address-remains ]] || echo '    inet6 2001:db8::10/64 scope global'
        return 0
    }
    rc-update() { echo "$*" > "$root/rc-update"; [[ "$scenario" != boot-fail ]]; }
    case "$scenario" in
        cancel)
            disable_server_ipv6 <<< n
            cmp "$root/original" "$root/etc/network/interfaces"
            [[ ! -e "$IPV6_DISABLE_CONF" && ! -e "$root/backups" ]]
            ;;
        ipv6-ssh)
            SSH_CONNECTION='2001:db8::2 53000 2001:db8::10 17788'
            ! disable_server_ipv6 <<< y
            [[ ! -e "$root/backups" ]]
            ;;
        absent-kernel)
            rm "$root/proc/conf/all/disable_ipv6"
            disable_server_ipv6 <<< y
            [[ ! -e "$root/backups" ]]
            ;;
        symlink)
            mv "$root/etc/network/interfaces" "$root/linked"
            ln -s "$root/linked" "$root/etc/network/interfaces"
            ! disable_server_ipv6 <<< y
            [[ ! -e "$root/backups" ]]
            ;;
        boot-fail)
            INIT_SYSTEM=openrc
            ! disable_server_ipv6 <<< y
            cmp "$root/original" "$root/etc/network/interfaces"
            [[ ! -e "$IPV6_DISABLE_CONF" ]]
            ;;
        apply-fail|address-remains|status-fail)
            ! disable_server_ipv6 > "$root/result" 2>&1 <<< y
            ! grep -q '\[✔\]' "$root/result"
            ;;
        success|openrc|repeat)
            [[ "$scenario" != openrc ]] || INIT_SYSTEM=openrc
            disable_server_ipv6 <<< y
            ! grep -q 'inet6\|ip -6' "$root/etc/network/interfaces"
            grep -q 'address 192.0.2.10/24' "$root/etc/network/interfaces"
            grep -q '^source ' "$root/etc/network/interfaces"
            grep -q '^iface eth1 inet dhcp' "$root/etc/network/interfaces.d/extra"
            ! grep -q inet6 "$root/etc/network/interfaces.d/extra"
            grep -q 'net.ipv6.conf.all.disable_ipv6 = 1' "$IPV6_DISABLE_CONF"
            grep -q 'net.ipv6.conf.default.disable_ipv6 = 1' "$IPV6_DISABLE_CONF"
            backup=$(find "$root/backups" -mindepth 1 -maxdepth 1 -type d | head -n 1)
            cmp "$root/original" "$backup$root/etc/network/interfaces"
            cmp "$root/original-extra" "$backup$root/etc/network/interfaces.d/extra"
            [[ "$scenario" != openrc ]] || grep -q '^add sysctl boot$' "$root/rc-update"
            if [[ "$scenario" == repeat ]]; then
                disable_server_ipv6 <<< y
                [[ $(grep -c '^net.ipv6.conf.all.disable_ipv6' "$IPV6_DISABLE_CONF") == 1 ]]
            fi
            ;;
    esac
    echo "PASS $scenario"
)

for scenario in cancel ipv6-ssh absent-kernel symlink boot-fail apply-fail address-remains status-fail success openrc repeat; do
    test_case "$scenario"
done
