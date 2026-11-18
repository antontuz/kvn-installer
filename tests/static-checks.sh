#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
script="kn-vpn-installer.sh"
bash -n "$script"

expect(){ grep -Fq -- "$1" "$script" || { echo "Missing invariant: $1" >&2; exit 1; }; }
reject(){ if grep -Fq -- "$1" "$script"; then echo "Unexpected insecure pattern: $1" >&2; exit 1; fi; }

expect 'umask 077'
expect 'verify_sha256 "$archive" "$expected"'
expect 'XUI_VERSION_PIN="v3.11.0"'
expect 'XRAY_VERSION_PIN="v26.11.9"'
expect 'say_secret "    password:'
expect 'say_secret "  ${cC}${link}'
expect '-listenIP 127.0.0.1'
expect 'subEnable'
expect 'subListen'
expect '"fp":"chrome"'
expect 'mktemp -d /tmp/kvn-vpn.'
reject 'GH_LATEST='
reject '"fp":"randomized"'
reject 'JAR="/tmp/vpn-inst.cookies"'
reject 'https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian'
echo "Static checks passed"
