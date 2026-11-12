#!/usr/bin/env bash
# Create a dedicated network namespace before doing any writes.
set -euo pipefail
if [[ ${1:-} != --inside-netns ]]; then
    export XRAY_IPV6_TEST_PARENT_NETNS
    XRAY_IPV6_TEST_PARENT_NETNS=$(readlink /proc/self/ns/net)
    exec unshare -n bash "$0" --inside-netns
fi
# Compare with the exact namespace of the launcher, not PID 1 (which can differ
# in WSL/containers even without isolating this test).
[[ -n ${XRAY_IPV6_TEST_PARENT_NETNS:-} && $(readlink /proc/self/ns/net) != "$XRAY_IPV6_TEST_PARENT_NETNS" ]] || {
    echo 'Refusing unisolated test; run: sudo bash tests/ipv6-disable-netns.sh' >&2
    exit 1
}
repo=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root/etc/network"
source <(sed -e "s|/etc/network/|$root/etc/network/|g" \
    -e "s|/etc/sysctl.d/99-xray-disable-ipv6.conf|$root/etc/disable-ipv6.conf|g" \
    -e "s|/var/backups/xray-manager/ipv6|$root/backups|g" "$repo/xray_manager.sh")
INIT_SYSTEM=systemd
SSH_CONNECTION='198.51.100.2 53000 192.0.2.10 17788'
ip link set lo up
ip link add test0 type veth peer name peer0
ip link set test0 up
ip address add 192.0.2.10/24 dev test0
ip -6 address add 2001:db8::10/64 dev test0 nodad
ip -6 route add default dev test0
ip -6 address show | grep -q 'inet6 '
disable_server_ipv6 <<< y
[[ -z $(ip -6 address show) && -z $(ip -6 route show) ]]
[[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) == 1 ]]
ip link add later0 type veth peer name later1
[[ $(sysctl -n net.ipv6.conf.later0.disable_ipv6) == 1 ]]
ip address show dev test0 | grep -q '192.0.2.10/24'
python3 - <<'PY'
import socket
listener = socket.socket()
listener.bind(('192.0.2.10', 0))
listener.listen(1)
with socket.create_connection(listener.getsockname(), timeout=2) as client:
    server, _ = listener.accept()
    with server:
        client.sendall(b'ipv4-ok')
        assert server.recv(7) == b'ipv4-ok'
listener.close()
PY
echo 'PASS real-kernel IPv6 disable, new-interface inheritance, IPv4 TCP'
