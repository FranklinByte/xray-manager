#!/usr/bin/env bash
# Redirect all installation paths to a fixture. No root, downloads or service changes.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root/usr/local/bin" "$root/usr/local/sbin" "$root/etc/pfwd"
printf 'forwarding-manager-sentinel\n' > "$root/usr/local/bin/pfw"
printf 'forwarding-rules-sentinel\n' > "$root/etc/pfwd/rules.tsv"
printf 'legacy-frank-sentinel\n' > "$root/usr/local/sbin/frank"
sed -e "s|/usr/local/|$root/usr/local/|g" -e "s|/etc/pfwd|$root/etc/pfwd|g" \
    -e 's/^    pre_check || return 1$/    : # skip dependency installs in fixture/' \
    "$repo/xray_manager.sh" > "$root/source.sh"
bash "$root/source.sh" --install
cmp "$root/source.sh" "$root/usr/local/sbin/xray-m"
bash "$root/usr/local/bin/xray-m" --install  # already-installed self-copy must succeed
grep -q '^forwarding-manager-sentinel$' "$root/usr/local/bin/pfw"
grep -q '^forwarding-rules-sentinel$' "$root/etc/pfwd/rules.tsv"
grep -q '^legacy-frank-sentinel$' "$root/usr/local/sbin/frank"
# Explicit updater must update only its own script and xray-m, not legacy frank or PFW.
cat > "$root/update-test.sh" <<'EOF'
source "$1"
curl() { cp "$SOURCE_FIXTURE" "$4"; }
module_update_manager_script <<< y
EOF
SOURCE_FIXTURE="$root/source.sh" bash "$root/update-test.sh" "$root/source.sh"
cmp "$root/source.sh" "$root/usr/local/sbin/xray-m"
grep -q '^legacy-frank-sentinel$' "$root/usr/local/sbin/frank"
grep -q '^forwarding-manager-sentinel$' "$root/usr/local/bin/pfw"
! grep -qiE 'deploy_pfw|cleanup_pfw|/etc/pfwd|/usr/local/bin/pfw' "$repo/xray_manager.sh"
echo 'PASS independent Xray install, reinstall and manual update'
