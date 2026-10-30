#!/usr/bin/env bash
# Installer regression tests: no root access, network, or production paths.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
suite=$(mktemp -d)
trap 'rm -rf -- "$suite"' EXIT

test_case() (
    local scenario=$1 root="$suite/$1"
    mkdir -p "$root/bin" "$root/etc" "$root/assets"
    # Redirect the sourced production script's constants into this fixture.
    source <(sed \
        -e "s|/usr/local/bin|$root/bin|g" \
        -e "s|/usr/local/etc/xray|$root/etc|g" \
        -e "s|/usr/local/share/xray|$root/assets|g" \
        -e "s|/var/backups/xray-manager|$root/backups|g" \
        "$repo/xray_manager.sh")
    export MOCK_VERSION=26.6.27 MOCK_CONFIG_OK=1
    printf '{"inbounds": []}\n' > "$XRAY_CONFIG"
    local original_config
    original_config=$(sha256sum "$XRAY_CONFIG")
    if [[ "$scenario" != fresh ]]; then
        printf '#!/bin/sh\necho "Xray %s"\n' \
            "$([[ "$scenario" == same ]] && echo 26.6.27 || echo 26.10.29)" > "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        cp "$XRAY_BIN" "$root/original"
    fi
    cat > "$root/candidate" <<'EOF'
#!/bin/sh
case "$1" in
    version) echo "Xray $MOCK_VERSION" ;;
    run) test "$MOCK_CONFIG_OK" = 1 ;;
    *) exit 1 ;;
esac
EOF
    printf 'mock archive\n' > "$root/archive"
    local digest
    digest=$(sha256sum "$root/archive" | awk '{print $1}')
    curl() {
        local url='' out=''
        while (($#)); do
            case "$1" in
                https:*) url=$1 ;;
                -o) shift; out=$1 ;;
            esac
            shift
        done
        [[ "$url" == https://github.com/XTLS/Xray-core/releases/download/v26.6.27/Xray-linux-64.zip* ]] || return 90
        printf '%s\n' "$url" >> "$root/requests"
        [[ "$scenario" != download-fail ]] || return 22
        if [[ "$url" == *.dgst ]]; then
            [[ "$scenario" != digest-missing ]] || return 22
            case "$scenario" in
                digest-invalid) printf 'unexpected format\n' > "$out" ;;
                digest-mismatch) printf 'SHA2-256= %064d\n' 0 > "$out" ;;
                *) printf 'SHA2-256= %s\n' "$digest" > "$out" ;;
            esac
        else
            cp "$root/archive" "$out"
        fi
    }
    unzip() {
        [[ "$scenario" != unzip-fail ]] || return 1
        cp "$root/candidate" "${@: -1}/xray"
    }
    [[ "$scenario" != version-mismatch ]] || export MOCK_VERSION=26.10.29
    [[ "$scenario" != config-incompatible ]] || export MOCK_CONFIG_OK=0
    local input=y rc=0
    [[ "$scenario" != cancel ]] || input=n
    install_xray_core <<< "$input" > "$root/output" 2>&1 || rc=$?
    [[ "$(sha256sum "$XRAY_CONFIG")" == "$original_config" ]]
    case "$scenario" in
        fresh|replace)
            [[ "$rc" == 0 ]]
            [[ "$("$XRAY_BIN" version)" == 'Xray 26.6.27' ]]
            [[ $(wc -l < "$root/requests") == 2 ]]
            if [[ "$scenario" == replace ]]; then
                local backups=("$root"/backups/*/xray)
                [[ ${#backups[@]} == 1 ]]
                cmp "$root/original" "${backups[0]}"
                cmp "$XRAY_CONFIG" "${backups[0]%/xray}/config.json"
            fi
            ;;
        same)
            [[ "$rc" == 0 && ! -e "$root/requests" ]]
            cmp "$root/original" "$XRAY_BIN"
            ;;
        *)
            [[ "$rc" != 0 ]]
            cmp "$root/original" "$XRAY_BIN"
            [[ ! -d "$root/backups" ]]
            ;;
    esac
    if [[ "$scenario" == cancel ]]; then [[ ! -e "$root/requests" ]]; fi
    local leftovers=("${XRAY_BIN}".new.*)
    [[ ! -e "${leftovers[0]}" ]]
    printf 'PASS %s\n' "$scenario"
)

for scenario in fresh replace same cancel download-fail digest-missing digest-invalid digest-mismatch unzip-fail version-mismatch config-incompatible; do
    test_case "$scenario"
done
