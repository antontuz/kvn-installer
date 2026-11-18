#!/usr/bin/env bash
#
# kn-vpn-installer.sh — automatic installer: VLESS + XHTTP + Reality on 3X-UI (Ubuntu 22.04/24.04)
#
# Based on kefir-100/kn-vpn-installer (MIT); see original author notice in LICENSE.
# Clean-room implementation based on official upstream sources only (3X-UI
# install.sh / x-ui.sh / main.go and the Xray transport docs). It does not
# derive from any third-party installer.
#
# Stack: VLESS + XHTTP(mode=auto) + Reality on 443/TCP, no XTLS-Vision.
# Panel: random port + random webBasePath + self-signed TLS (obscure URL).
# All of THIS tool's files live under /home/kn-vpn-installer (logs, creds, state, links).
# Clients: a starter client is created here; more are added via this script
# (re-run -> "add client") or directly in the 3X-UI panel.
#
# Usage:
#   sudo bash kn-vpn-installer.sh [--keys N] [--sni DOMAIN] [--client NAME] [--inbound NAME]
# Env overrides: GOVPN_KEYS, GOVPN_SNI, GOVPN_CLIENT, GOVPN_INBOUND, GOVPN_DRYRUN=1
#
set -euo pipefail
umask 077 # protect credentials, logs, and temp files from other users

# ─────────────────────────────── constants ──────────────────────────────────
XUI_DIR="/usr/local/x-ui"
XUI_BIN="${XUI_DIR}/x-ui"
XUI_DB_DIR="/etc/x-ui"          # 3X-UI database/config (x-ui.db + -wal/-shm + metrics)
CERT_DIR="${XUI_DIR}/cert"
XUI_LOG_DIR="/var/log/x-ui"
SVC_FILE="/etc/systemd/system/x-ui.service"
BBR_CONF="/etc/sysctl.d/99-vpn-bbr.conf"
# Everything this tool produces lives in ONE place:
HOME_DIR="/home/kn-vpn-installer"
STATE_DIR="$HOME_DIR"
STATE_FILE="${STATE_DIR}/state.env"
CRED_FILE="${STATE_DIR}/panel-credentials.txt"
CLIENTS_FILE="${STATE_DIR}/clients.txt"
INFO_FILE="${STATE_DIR}/INSTALL-INFO.txt"
LOG_FILE="${STATE_DIR}/vpn-installer.log"
GH_DL="https://github.com/MHSanaei/3x-ui/releases/download"
XRAY_DL="https://github.com/XTLS/Xray-core/releases/download"
# Reviewed versions and SHA-256 digests; update deliberately.
XUI_VERSION_PIN="v3.11.0"
XUI_SHA256_AMD64="0ddfa4702f595442e2962acd81addc768fdacaa4ff2672c971a0463dae744916"
XUI_SHA256_ARM64="f50b4c30fd919d018f2f4c3d8db53a4ca027503d581328727770afb116a79d90"
XRAY_VERSION_PIN="v26.11.9"
XRAY_SHA256_AMD64="b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82"
XRAY_SHA256_ARM64="64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be"
SNI_CANDIDATES=("github.com" "www.microsoft.com")
MIN_DISK_MB=500
DEP_PKGS=(curl tar ca-certificates openssl jq tzdata socat unzip sqlite3)

KEYS="${GOVPN_KEYS:-1}"
SNI_OVERRIDE="${GOVPN_SNI:-}"
CLIENT_NAME="${GOVPN_CLIENT:-}"   # asked interactively if empty
INBOUND_NAME="${GOVPN_INBOUND:-}" # asked interactively if empty
XHTTP_PATH="/"                    # randomised in configure_panel
DRYRUN="${GOVPN_DRYRUN:-0}"
FORCE=0                # 1 once the user confirms a from-scratch reinstall
ADD_CLIENT_MODE=0      # 1 when re-run chooses "add a new client"
PANEL_SCHEME="https"   # actual scheme is re-detected after the panel starts
XUI_VERSION=""         # filled in by install_3xui
SUBID=""               # filled in by ask_subid (single-client interactive path)
JAR=""   # set inside private temporary directory by main
TMP_DIR=""
PANEL_BASE=""; CSRF=""; ORIGIN=""   # set by panel_wait / panel_login

# ─────────────────────────────── logging ────────────────────────────────────
cG=$'\e[32m'; cY=$'\e[33m'; cR=$'\e[31m'; cC=$'\e[36m'; cB=$'\e[1m'; cD=$'\e[2m'; cX=$'\e[0m'
_strip(){ sed 's/\x1b\[[0-9;]*m//g'; }
_logfile(){ printf '%s\n' "$*" | _strip >>"$LOG_FILE" 2>/dev/null || true; }
say(){ printf '%b\n' "$*"; _logfile "$*"; }
say_secret(){ printf '%b\n' "$*"; } # terminal only; never write credentials or links to log
ok(){   say "  ${cG}OK${cX} $*"; }
warn(){ say "  ${cY}! ${cX} $*"; }
step(){ say "\n${cB}==> $*${cX}"; }
die(){  say "  ${cR}XX $*${cX}"; say "  ${cD}see ${LOG_FILE}${cX}"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

# Wrapper for privileged/system commands; stubbed in dry-run.
run(){
    if [ "$DRYRUN" = 1 ]; then say "  ${cD}[dry-run] $*${cX}"; return 0; fi
    "$@"
}

# ─────────────────────────────── helpers ────────────────────────────────────
arch_tag(){
    case "$(uname -m)" in
        x86_64|amd64)            echo amd64 ;;
        aarch64|arm64|armv8*)    echo arm64 ;;
        *) die "Unsupported CPU architecture: $(uname -m)" ;;
    esac
}

rand_str(){ # rand_str N -> N cryptographically random hexadecimal characters
    local length="${1:-18}"
    openssl rand -hex "$(( (length + 1) / 2 ))" | cut -c "1-${length}"
}
rand_port(){ # random unprivileged port 10000-65000
    echo $(( (RANDOM<<2 ^ RANDOM) % 55001 + 10000 ));
}
gen_uuid(){
    if [ "$DRYRUN" = 1 ]; then echo "00000000-0000-4000-8000-00000000000${1:-0}"; return; fi
    cat /proc/sys/kernel/random/uuid
}
is_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

cleanup(){ [ -z "${TMP_DIR:-}" ] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

# ─────────────────────────── 1. preflight ───────────────────────────────────
preflight(){
    step "Preflight checks"
    if [ "$DRYRUN" != 1 ] && [ "$(id -u)" -ne 0 ]; then
        die "Run as root (sudo bash kn-vpn-installer.sh)."
    fi
    # rebind stdin to the terminal if piped
    if [ ! -t 0 ] && [ -e /dev/tty ]; then { exec </dev/tty; } 2>/dev/null || true; fi
    # OS sanity (best-effort)
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        [ "${ID:-}" = "ubuntu" ] || warn "Tested on Ubuntu 22.04/24.04; detected '${ID:-unknown} ${VERSION_ID:-}'."
    fi
    # disk space
    local free_mb; free_mb=$(df -Pm / | awk 'NR==2{print $4}')
    if [ "$DRYRUN" != 1 ] && [ "${free_mb:-0}" -lt "$MIN_DISK_MB" ]; then
        die "Need >= ${MIN_DISK_MB} MB free on /, have ${free_mb} MB."
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null || run mkdir -p "$STATE_DIR"
    ok "Root, OS and disk checks passed (free: ${free_mb:-?} MB)."
}

# ─────────────── 1b. detect existing install + confirm overwrite ─────────────
# If a previous install is present, do NOT silently reinstall, recreate the 443
# inbound, or overwrite panel settings/port/URL/credentials. Report what was
# found and require an explicit "yes" to overwrite; otherwise exit untouched.
check_existing(){
    local found=()
    [ -f "$STATE_FILE" ]                                   && found+=("install record: ${STATE_FILE}")
    [ -x "$XUI_BIN" ]                                      && found+=("3X-UI binary: ${XUI_BIN}")
    if [ "$DRYRUN" != 1 ] && \
       systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        found+=("systemd service: x-ui")
    fi
    [ "${#found[@]}" -eq 0 ] && return 0   # clean machine -> normal fresh install

    step "Existing installation detected"
    local f; for f in "${found[@]}"; do warn "found ${f}"; done
    [ -f "$CRED_FILE" ] && say "  ${cD}current panel details: ${CRED_FILE}${cX}"
    say ""
    say "  What do you want to do?"
    say "    ${cB}1${cX}) Reinstall from scratch  ${cD}(WIPES panel, inbound on 443, keys; new URL/creds)${cX}"
    say "    ${cB}2${cX}) Add a new client        ${cD}(keep everything, just issue one more key)${cX}"
    if [ "$DRYRUN" = 1 ]; then warn "(dry-run) would prompt 1/2; assuming 1 (reinstall)"; FORCE=1; return 0; fi
    local ans
    printf "  Choose [1/2] (or anything else to cancel): "; read -r ans
    case "$ans" in
        1) FORCE=1; ok "Reinstall from scratch confirmed." ;;
        2) ADD_CLIENT_MODE=1; ok "Add-a-new-client mode selected." ;;
        *) say "  ${cD}Cancelled. Nothing changed.${cX}"; exit 0 ;;
    esac
}

# ─────────────────────── 2. dependencies + BBR ──────────────────────────────
install_deps(){
    step "Installing dependencies"
    # Package set mirrors what 3X-UI's own installer pulls on Debian/Ubuntu,
    # plus jq used by this script. python3 ships with Ubuntu base.
    local missing=()
    for p in "${DEP_PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if [ "${#missing[@]}" -eq 0 ]; then
        ok "All dependencies already present."
    else
        run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
        ok "Installed: ${missing[*]}"
    fi
    have python3 || [ "$DRYRUN" = 1 ] || die "python3 is required but missing."
}

enable_bbr(){
    step "Enabling BBR + fq (best-effort)"
    local conf=/etc/sysctl.d/99-vpn-bbr.conf
    if [ "$DRYRUN" = 1 ]; then say "  ${cD}[dry-run] write $conf (fq + bbr)${cX}"; return 0; fi
    {
        echo "net.core.default_qdisc=fq"
        echo "net.ipv4.tcp_congestion_control=bbr"
    } >"$conf"
    if sysctl --system >/dev/null 2>&1 && \
       [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]; then
        ok "BBR active."
    else
        warn "Could not confirm BBR (kernel may lack support) — continuing."
    fi
}

# ─────────────────────────── 3. public IP ───────────────────────────────────
detect_ip(){
    step "Detecting public IP"
    # 203.0.113.10 is an RFC 5737 documentation-only placeholder (not a real host)
    if [ "$DRYRUN" = 1 ]; then SERVER_IP="203.0.113.10"; ok "IP (dry-run): $SERVER_IP"; return; fi
    local s
    SERVER_IP=""
    for s in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
        SERVER_IP=$(curl -fsS4 --max-time 8 "$s" 2>/dev/null | tr -d '[:space:]') || true
        is_ipv4 "$SERVER_IP" && break
        SERVER_IP=""
    done
    if is_ipv4 "$SERVER_IP"; then
        ok "Detected public IP: $SERVER_IP"
        printf "  Use this IP? [Y] or type another IPv4: "
        read -r ans
        if [ -n "$ans" ] && [[ ! "$ans" =~ ^[Yy]$ ]]; then
            is_ipv4 "$ans" || die "Not a valid IPv4: ${ans}"
            SERVER_IP="$ans"
        fi
    else
        warn "Auto-detection failed."
        printf "  Enter the server's public IPv4: "; read -r SERVER_IP
        is_ipv4 "$SERVER_IP" || die "Not a valid IPv4: ${SERVER_IP}"
    fi
    ok "Server IP: $SERVER_IP"
}

# Port 443 must be free for our Reality inbound. A previous kn-vpn-installer / 3X-UI
# (x-ui or its xray, exe under /usr/local/x-ui) is "ours" -> logged and left for
# full_reset to remove. Anything else (a web server, another proxy) is foreign -> fatal.
check_port_443(){
    [ "$DRYRUN" = 1 ] && return 0
    step "Checking port 443"
    local line pid exe comm
    line=$(ss -tlnpH 2>/dev/null | awk '$4 ~ /:443$/' | head -1)
    [ -z "$line" ] && { ok "Port 443 is free."; return 0; }
    pid=$(grep -oP 'pid=\K[0-9]+' <<<"$line" | head -1)
    exe=""; comm=""
    if [ -n "$pid" ]; then
        exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
        comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    fi
    if [[ "$exe" == "${XUI_DIR}/"* ]] || [[ "$comm" == x-ui* ]] || [[ "$comm" == xray* ]]; then
        warn "Port 443 held by a previous kn-vpn-installer/3X-UI install (${comm:-x-ui}, pid ${pid:-?}) — it will be removed."
        _logfile "found previous install on :443 -> pid=${pid:-?} comm=${comm:-?} exe=${exe:-?}; will be removed by full reset"
        return 0
    fi
    say "  ${cR}Port 443 is in use by a non-kn-vpn-installer process:${cX}"
    say "    pid=${pid:-?}  name=${comm:-?}  path=${exe:-?}"
    die "Free port 443 (e.g. stop that service/container) and re-run."
}

# ─────────────────────────── 4. SNI donor ───────────────────────────────────
# A good Reality donor: TLS1.3 + h2, real cert, ideally hosted in the server's
# own subnet/ASN. We validate before locking it in.
probe_sni(){ # probe_sni domain -> 0 if TLS1.3 + h2 ok
    [ "$DRYRUN" = 1 ] && return 0
    local d="$1" out
    out=$(echo | timeout 10 openssl s_client -connect "${d}:443" -servername "$d" \
            -tls1_3 -alpn h2 2>/dev/null) || return 1
    grep -q "TLSv1.3" <<<"$out" && grep -q "ALPN protocol: h2" <<<"$out"
}
pick_default_sni(){ # probe the built-in candidates, set SNI on first pass
    local d
    for d in "${SNI_CANDIDATES[@]}"; do
        if probe_sni "$d"; then SNI="$d"; ok "Donor: ${SNI} (TLS1.3 + h2 verified)"; return 0; fi
        warn "Candidate ${d} failed TLS1.3/h2 probe — trying next."
    done
    return 1
}
pick_sni(){
    step "Selecting Reality SNI/dest donor"
    # explicit override via --sni / GOVPN_SNI wins, no prompt
    if [ -n "$SNI_OVERRIDE" ]; then
        if probe_sni "$SNI_OVERRIDE"; then SNI="$SNI_OVERRIDE"; ok "Donor (override): ${SNI}"; return; fi
        die "Provided --sni '${SNI_OVERRIDE}' failed TLS1.3+h2 probe."
    fi
    if [ "$DRYRUN" = 1 ]; then SNI="github.com"; ok "Donor (dry-run): $SNI"; return; fi

    say "  ${cD}A strong donor lives in THIS server's subnet/ASN (so SNI<->IP looks plausible)."
    say "  Find one with RealiTLScanner — best run from a residential / throwaway host, NOT"
    say "  this VPS (cloud scanning can get the IP abuse-flagged); keep scans short:"
    say "    git clone https://github.com/XTLS/RealiTLScanner && cd RealiTLScanner && go build"
    say "    ./RealiTLScanner -addr ${SERVER_IP}/24 -port 443 -thread 20 -timeout 5 -out donors.csv"
    say "  Pick a row with a real, recognizable domain (not proxy/VPN junk), same /24 if possible.${cX}"
    printf "  Use a verified default (%s) [D], or enter your own donor [o]? [D/o] " "${SNI_CANDIDATES[0]}"
    read -r ch
    if [[ "$ch" =~ ^[Oo]$ ]]; then
        printf "  Enter donor domain: "; read -r dom
        dom=$(printf '%s' "$dom" | tr -cd 'a-zA-Z0-9.-')
        if [ -n "$dom" ] && probe_sni "$dom"; then SNI="$dom"; ok "Donor: ${SNI} (TLS1.3 + h2 verified)"; return; fi
        warn "Donor '${dom}' failed the TLS1.3+h2 probe — falling back to defaults."
    fi
    pick_default_sni || die "No usable SNI donor (none passed TLS1.3+h2). Re-run and enter one."
}

# Ask for the client label that 3X-UI will show for the key(s).
ask_clients(){
    local def_inbound="vpn-vless-xhttp-reality"
    if [ "$DRYRUN" = 1 ]; then
        CLIENT_NAME="${CLIENT_NAME:-vpn}"
        INBOUND_NAME="${INBOUND_NAME:-$def_inbound}"
        return 0
    fi
    if [ -z "$INBOUND_NAME" ]; then
        printf "  Inbound name (label in 3X-UI) [%s]: " "$def_inbound"; read -r INBOUND_NAME
        INBOUND_NAME="${INBOUND_NAME:-$def_inbound}"
    fi
    # strip quotes/backslashes; keep letters, digits, space and - _ .
    INBOUND_NAME=$(printf '%s' "$INBOUND_NAME" | tr -d '"'\''\\' | tr -cd 'a-zA-Z0-9 _.-')
    [ -n "$INBOUND_NAME" ] || INBOUND_NAME="$def_inbound"
    if [ -z "$CLIENT_NAME" ]; then
        printf "  Client name (label shown in 3X-UI panel) [vpn]: "; read -r CLIENT_NAME
        CLIENT_NAME=$(printf '%s' "${CLIENT_NAME:-vpn}" | tr -cd 'a-zA-Z0-9_.-')
        [ -n "$CLIENT_NAME" ] || CLIENT_NAME="vpn"
    fi
}

# Subscription ID: a random string (>=16 chars), unique among existing clients.
# Used by the panel for the share/QR/subscription feature. We generate one,
# show it, and let the user keep it or type their own (validated >=16, unique).
# $1 (optional): space-separated list of subIds already in use (uniqueness check).
ask_subid(){
    local existing="${1:-}"
    SUBID="$(rand_str 16)"
    if [ "$DRYRUN" = 1 ]; then return 0; fi
    say "  ${cD}A subId must be a string of at least 16 chars and UNIQUE in this"
    say "  setup — no other client may share the same subId.${cX}"
    say_secret "  Generated subId: ${cC}${SUBID}${cX}"
    local ch
    printf "  Use this subId? [Y] or enter your own [o]? [Y/o] "; read -r ch
    if [[ "$ch" =~ ^[Oo]$ ]]; then
        while true; do
            local v
            printf "  Enter subId (>=16 chars): "; read -r v
            v=$(printf '%s' "$v" | tr -cd 'a-zA-Z0-9_.-')
            if [ "${#v}" -lt 16 ]; then warn "Too short (${#v} chars); need >=16."; continue; fi
            if [ -n "$existing" ] && grep -qw -- "$v" <<<"$existing"; then
                warn "That subId is already used by another client; choose another."; continue
            fi
            SUBID="$v"; break
        done
    fi
    ok "subId set."
}

# ─────────────────────── 5. install 3X-UI (release) ─────────────────────────
# Remove ALL 3X-UI artefacts so a (confirmed) reinstall is truly clean and no
# stale inbound/config/DB can survive (the DB lives in /etc/x-ui, separate from
# the binary in /usr/local/x-ui). Safe no-op on a fresh machine. Does NOT touch
# other services on the box.
wipe_3xui(){
    [ "$DRYRUN" = 1 ] && { say "  ${cD}[dry-run] stop/disable/remove x-ui + DB (${XUI_DB_DIR})${cX}"; return 0; }
    systemctl stop x-ui    >/dev/null 2>&1 || true
    systemctl disable x-ui >/dev/null 2>&1 || true
    rm -f "$SVC_FILE" /usr/bin/x-ui 2>/dev/null || true
    rm -rf "$XUI_DIR" "$XUI_DB_DIR" 2>/dev/null || true   # binary + database/config
    systemctl daemon-reload >/dev/null 2>&1 || true
}

# Full reset for "reinstall from scratch": wipe everything THIS tool installed so
# nothing cached can conflict. Reads recorded paths from state.env when present
# (source of truth), else falls back to the constants above. While deleting we
# keep writing to the OLD log (for crash diagnosis); once everything is gone we
# start a brand-new log. BBR config is left in place — re-applying the identical
# settings can't conflict, and removing it only to re-add it is pointless.
full_reset(){
    [ "$DRYRUN" = 1 ] && { say "  ${cD}[dry-run] full reset of previous install (would source ${STATE_FILE})${cX}"; return 0; }
    step "Full reset of previous installation"
    # source of truth: recorded paths from the prior install
    if [ -f "$STATE_FILE" ]; then
        # shellcheck source=/dev/null
        { set -a; . "$STATE_FILE" 2>/dev/null || true; set +a; }
    fi
    say "  removing 3X-UI (${XUI_DIR}), database (${XUI_DB_DIR}), service (${SVC_FILE})…"
    wipe_3xui
    say "  removing this tool's files in ${HOME_DIR} (incl. old log)…"
    rm -rf "$HOME_DIR" 2>/dev/null || true
    mkdir -p "$HOME_DIR"
    chmod 700 "$HOME_DIR"
    : >"$LOG_FILE"   # brand-new log for the fresh install
    chmod 600 "$LOG_FILE"
    _logfile "=== fresh install started $(date -Is) after full reset of a previous installation ==="
    ok "Previous installation fully removed; starting clean."
}

# Install the systemd unit. Current releases ship distro variants
# (x-ui.service.debian/.arch/.rhel), not a plain x-ui.service; on Ubuntu/Debian
# we use the .debian variant, falling back to the official GitHub copy.
install_service(){
    local src=""
    if   [ -f "${XUI_DIR}/x-ui.service" ];        then src="${XUI_DIR}/x-ui.service"
    elif [ -f "${XUI_DIR}/x-ui.service.debian" ]; then src="${XUI_DIR}/x-ui.service.debian"
    fi
    if [ -n "$src" ]; then
        install -m 0644 "$src" /etc/systemd/system/x-ui.service
    else
        die "Pinned 3X-UI archive has no service file; refusing unpinned download."
    fi
}

verify_sha256(){
    local filename="$1" expected="$2" actual
    actual="$(sha256sum "$filename" | awk '{print $1}')"
    [ "$actual" = "$expected" ]
}

install_3xui(){
    step "Installing 3X-UI ${XUI_VERSION_PIN} (verified SHA-256)"
    local arch expected url archive
    arch="$(arch_tag)"
    case "$arch" in
      amd64) expected="$XUI_SHA256_AMD64" ;;
      arm64) expected="$XUI_SHA256_ARM64" ;;
      *) die "Unsupported architecture" ;;
    esac
    url="${GH_DL}/${XUI_VERSION_PIN}/x-ui-linux-${arch}.tar.gz"
    if [ "$DRYRUN" = 1 ]; then
        say "  [dry-run] download / verify ${url}"
        XUI_VERSION="$XUI_VERSION_PIN"
        return
    fi
    archive="${TMP_DIR}/x-ui.tar.gz"
    curl -fLsS4 --retry 3 --connect-timeout 15 -o "$archive" "$url" ||
        die "3X-UI download failed"
    verify_sha256 "$archive" "$expected" ||
        die "3X-UI SHA-256 mismatch; refusing to install"
    gzip -t "$archive" || die "Invalid 3X-UI archive"
    mkdir -p "$(dirname "$XUI_DIR")"
    tar -xzf "$archive" -C "$(dirname "$XUI_DIR")"
    [ -x "${XUI_DIR}/x-ui" ] || die "3X-UI executable missing after extraction"
    chmod +x "${XUI_DIR}/x-ui" "${XUI_DIR}/x-ui.sh" "${XUI_DIR}/bin/xray-linux-${arch}"
    chown -R root:root "$XUI_DIR"
    install_service
    [ ! -f "${XUI_DIR}/x-ui.sh" ] || install -m 0755 "${XUI_DIR}/x-ui.sh" /usr/bin/x-ui
    mkdir -p /var/log/x-ui
    run systemctl daemon-reload
    run systemctl enable x-ui >/dev/null 2>&1
    XUI_VERSION="$XUI_VERSION_PIN"
    ok "Installed verified 3X-UI ${XUI_VERSION}"
}

install_xray(){
    step "Installing Xray-core ${XRAY_VERSION_PIN} (verified SHA-256)"
    local arch asset expected url archive executable
    arch="$(arch_tag)"
    case "$arch" in
      amd64) asset="Xray-linux-64.zip"; expected="$XRAY_SHA256_AMD64" ;;
      arm64) asset="Xray-linux-arm64-v8a.zip"; expected="$XRAY_SHA256_ARM64" ;;
      *) die "Unsupported architecture" ;;
    esac
    url="${XRAY_DL}/${XRAY_VERSION_PIN}/${asset}"
    if [ "$DRYRUN" = 1 ]; then
        say "  [dry-run] download / verify ${url}"
        XRAY_VERSION="$XRAY_VERSION_PIN"
        return
    fi
    archive="${TMP_DIR}/xray.zip"
    executable="${TMP_DIR}/xray"
    curl -fLsS4 --retry 3 --connect-timeout 15 -o "$archive" "$url" ||
        die "Xray download failed"
    verify_sha256 "$archive" "$expected" ||
        die "Xray SHA-256 mismatch; refusing to install"
    unzip -tq "$archive" >/dev/null || die "Invalid Xray archive"
    unzip -p "$archive" xray > "$executable" || die "Xray executable missing in archive"
    [ -s "$executable" ] || die "Empty Xray executable"
    install -m 0755 "$executable" "${XUI_DIR}/bin/xray-linux-${arch}"
    XRAY_VERSION="$XRAY_VERSION_PIN"
    ok "Installed verified Xray-core ${XRAY_VERSION}"
}

# ─────────────────── 6. panel credentials + obscure URL ─────────────────────
configure_panel(){
    step "Configuring panel (credentials, port, webBasePath, TLS)"
    PANEL_USER="u$(rand_str 9)"
    PANEL_PASS="$(rand_str 20)"
    PANEL_PORT="$(rand_port)"
    PANEL_PATH="/$(rand_str 18)/"
    XHTTP_PATH="/$(rand_str 10)"        # non-standard inbound path (not bare "/")
    if [ "$DRYRUN" = 1 ]; then
        say "  ${cD}[dry-run] x-ui setting -username *** -password *** -port ${PANEL_PORT} -webBasePath ${PANEL_PATH}${cX}"
        say "  ${cD}[dry-run] generate self-signed cert for ${SERVER_IP}; x-ui cert -webCert/-webCertKey${cX}"
        ok "Panel parameters generated (dry-run). XHTTP path: ${XHTTP_PATH}"
        return
    fi
    # Show generated panel login/password and let the user keep or override them.
    say "  Generated panel login:"
    say_secret "    username: ${cC}${PANEL_USER}${cX}"
    say_secret "    password: ${cC}${PANEL_PASS}${cX}"
    printf "  Use these? [Y] or enter your own [o]? [Y/o] "; read -r ch
    if [[ "$ch" =~ ^[Oo]$ ]]; then
        local u p
        printf "  Username: "; read -r u
        printf "  Password: "; read -r p
        [ -n "$u" ] && PANEL_USER="$u"
        [ -n "$p" ] && PANEL_PASS="$p"
        ok "Using your custom panel credentials."
    fi
    run "$XUI_BIN" setting -username "$PANEL_USER" -password "$PANEL_PASS" \
        -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" -listenIP 127.0.0.1 >/dev/null 2>&1
    # self-signed cert for panel TLS (no domain in this configuration)
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "${CERT_DIR}/panel.key" -out "${CERT_DIR}/panel.crt" \
        -subj "/CN=${SERVER_IP}" >/dev/null 2>&1 || die "Self-signed cert generation failed."
    chmod 600 "${CERT_DIR}/panel.key"
    # IMPORTANT: panel cert is applied by the 'cert' subcommand, NOT 'setting'
    # ('setting' parses -webCert but ignores it, leaving the panel on plain HTTP).
    run "$XUI_BIN" cert -webCert "${CERT_DIR}/panel.crt" -webCertKey "${CERT_DIR}/panel.key" >/dev/null 2>&1
    ok "Panel set on port ${PANEL_PORT}, path ${PANEL_PATH}, TLS enabled."
    ok "XHTTP inbound path: ${XHTTP_PATH}"
    # Save credentials to disk NOW (not only at the end), so they survive a
    # failure in any later step. Re-saved with the detected scheme by persist_state.
    write_credentials
    say "  ${cD}credentials saved to ${CRED_FILE}${cX}"
}

# ───────────────────────── 7. Reality keys ──────────────────────────────────
disable_subscriptions(){
    step "Disabling unused subscription listener"
    if [ "$DRYRUN" = 1 ]; then
        say "  [dry-run] subEnable=false, subListen=127.0.0.1"
        return
    fi
    local db="${XUI_DB_DIR}/x-ui.db"
    [ -f "$db" ] || die "3X-UI database not found: $db"
    sqlite3 "$db" <<'SQL' || die "Failed to disable subscription listener."
BEGIN IMMEDIATE;
INSERT INTO settings (key,value) SELECT 'subEnable','false' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='subEnable');
UPDATE settings SET value='false' WHERE key='subEnable';
INSERT INTO settings (key,value) SELECT 'subListen','127.0.0.1' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='subListen');
UPDATE settings SET value='127.0.0.1' WHERE key='subListen';
COMMIT;
SQL
    ok "Subscription listener disabled."
}

gen_reality(){
    step "Generating Reality keys"
    local xray out
    xray="${XUI_DIR}/bin/xray-linux-$(arch_tag)"
    SHORT_ID="$(openssl rand -hex 4)"
    if [ "$DRYRUN" = 1 ]; then
        REALITY_PRIV="PRIV_dryrun"; REALITY_PUB="PUB_dryrun"
        ok "Reality keys (dry-run); shortId=${SHORT_ID}"
        return
    fi
    out=$("$xray" x25519) || die "xray x25519 failed."
    # output format varies by version: "Private key:"/"Public key:" or "PrivateKey:"/"Password:"
    REALITY_PRIV=$(grep -iE 'private' <<<"$out" | awk -F'[: ]+' '{print $NF}')
    REALITY_PUB=$(grep -iE 'public|password' <<<"$out" | awk -F'[: ]+' '{print $NF}')
    [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ] || die "Could not parse x25519 output."
    ok "Reality keypair generated; shortId=${SHORT_ID}"
}

# ──────────────── 8. build inbound payload + create via API ──────────────────
build_payload(){
    # Emits the inbound JSON (with nested JSON-as-strings, per 3X-UI API) to stdout.
    python3 - "$@" <<'PY'
import json, sys
ip, port, sni, priv, pub, sid, xpath, cname, remark, subid, n_clients = sys.argv[1:12]
n=int(n_clients)
clients=[]
for i in range(n):
    uid=sys.argv[12+i]
    email=cname if n==1 else f"{cname}{i+1}"
    csub=subid if n==1 else f"{subid}{i+1}"
    clients.append({"id":uid,"flow":"","email":email,"limitIp":0,
                    "totalGB":0,"expiryTime":0,"enable":True,
                    "tgId":"","subId":csub,"reset":0})
settings={"clients":clients,"decryption":"none","fallbacks":[]}
stream={
  "network":"xhttp","security":"reality",
  "xhttpSettings":{"path":xpath,"host":"","mode":"auto"},
  "realitySettings":{
    "show":False,"xver":0,"dest":f"{sni}:443",
    "serverNames":[sni],
    "privateKey":priv,"minClient":"","maxClient":"","maxTimediff":0,
    "shortIds":[sid],
    "settings":{"publicKey":pub,"fingerprint":"chrome","serverName":"","spiderX":"/"}
  }
}
sniffing={"enabled":True,"destOverride":["http","tls","quic","fakedns"],
          "metadataOnly":False,"routeOnly":True}
payload={"remark":remark,"enable":True,"expiryTime":0,
  "listen":"","port":int(port),"protocol":"vless",
  "settings":json.dumps(settings),
  "streamSettings":json.dumps(stream),
  "sniffing":json.dumps(sniffing),
  "allocate":json.dumps({"strategy":"always","refresh":5,"concurrency":3})}
print(json.dumps(payload))
PY
}

# ──────────────── panel API helpers (shared by both flows) ──────────────────
# Authenticated curl against the panel: adds session cookie + CSRF + Origin.
papi(){ local ep="$1"; shift
    curl -sk -b "$JAR" -c "$JAR" "${PANEL_BASE}${ep}" \
        -H "Origin: ${ORIGIN}" -H "Referer: ${PANEL_BASE}/" \
        -H "X-CSRF-Token: ${CSRF}" "$@"
}
# Wait for the panel, detect scheme (https then http), set PANEL_BASE/SCHEME/ORIGIN.
panel_wait(){ local port="$1" path="$2" sc code
    PANEL_BASE=""
    for _ in $(seq 1 40); do
        for sc in https http; do
            code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 4 \
                   "${sc}://127.0.0.1:${port}${path}" 2>/dev/null || echo 000)
            if [ "$code" != 000 ] && [ "$code" -ge 100 ] 2>/dev/null; then
                PANEL_BASE="${sc}://127.0.0.1:${port}${path%/}"; PANEL_SCHEME="$sc"; break 2
            fi
        done
        sleep 1
    done
    [ -n "$PANEL_BASE" ] || die "Panel did not become reachable on 127.0.0.1:${port}${path}"
    [ "$PANEL_SCHEME" = https ] || die "Panel TLS is not active; refusing to continue."
    ORIGIN="${PANEL_SCHEME}://127.0.0.1:${port}"
    local bindings
    bindings="$(ss -tlnH | awk -v port=":${port}" '$4 ~ port "$" {print $4}')"
    [ "$bindings" = "127.0.0.1:${port}" ] ||
        die "Panel must listen only on 127.0.0.1:${port}, found: ${bindings}"
    ok "Panel reachable on localhost over ${PANEL_SCHEME} (HTTP ${code})."
}
# CSRF login: GET page for cookie+token, then POST /login. Sets JAR + CSRF.
panel_login(){ local u="$1" p="$2" lg
    rm -f "$JAR"
    CSRF=$(curl -sk -c "$JAR" "${PANEL_BASE}/" \
            | grep -oE 'csrf-token" content="[^"]+"' | sed 's/.*content="//;s/"//') || true
    [ -n "$CSRF" ] || warn "csrf-token not found on panel page — login may fail."
    lg=$(papi "/login" -X POST --data-urlencode "username=${u}" --data-urlencode "password=${p}") \
        || die "Panel login request failed."
    echo "$lg" | jq -e '.success == true' >/dev/null 2>&1 || die "Panel login rejected: ${lg}"
    ok "Logged into panel."
}
# Build a vless:// link.  args: uuid ip sni pub sid xpath label
make_link(){
    python3 - "$@" <<'PY'
import sys, urllib.parse as u
uid, ip, sni, pub, sid, xpath, label = sys.argv[1:8]
q=u.urlencode({"type":"xhttp","path":xpath,"mode":"auto","security":"reality",
               "pbk":pub,"fp":"chrome","sni":sni,"sid":sid,"spx":"/"})
print(f"vless://{uid}@{ip}:443?{q}#{label}")
PY
}

create_inbound(){
    step "Creating VLESS + XHTTP + Reality inbound (${KEYS} client(s))"
    CLIENT_UUIDS=()
    local i; for i in $(seq 1 "$KEYS"); do CLIENT_UUIDS+=("$(gen_uuid "$i")"); done
    local payload; payload=$(build_payload "$SERVER_IP" 443 "$SNI" \
        "$REALITY_PRIV" "$REALITY_PUB" "$SHORT_ID" "$XHTTP_PATH" "$CLIENT_NAME" \
        "$INBOUND_NAME" "$SUBID" "$KEYS" "${CLIENT_UUIDS[@]}")
    echo "$payload" | python3 -c 'import json,sys; json.load(sys.stdin)' \
        || die "Generated inbound payload is not valid JSON."
    if [ "$DRYRUN" = 1 ]; then
        ok "Inbound payload built and JSON-validated (dry-run, not sent)."
        echo "$payload" >/tmp/vpn-inst.payload.json
        return
    fi
    run systemctl restart x-ui
    panel_wait "$PANEL_PORT" "$PANEL_PATH"
    panel_login "$PANEL_USER" "$PANEL_PASS"
    local resp
    resp=$(papi "/panel/api/inbounds/add" -X POST -H 'Content-Type: application/json' -d "$payload") \
        || die "Inbound creation request failed."
    echo "$resp" | jq -e '.success == true' >/dev/null 2>&1 || die "Panel rejected inbound: ${resp}"
    ok "Inbound created with ${KEYS} client(s)."
}

# ──────────────────────── 9. build vless:// links ───────────────────────────
print_links(){
    step "Connection keys (text)"
    local i email link
    for i in $(seq 1 "$KEYS"); do
        if [ "$KEYS" -eq 1 ]; then email="$CLIENT_NAME"; else email="${CLIENT_NAME}${i}"; fi
        link=$(make_link "${CLIENT_UUIDS[$((i-1))]}" "$SERVER_IP" "$SNI" "$REALITY_PUB" "$SHORT_ID" "$XHTTP_PATH" "$email")
        say_secret "  ${cC}${link}${cX}"
        [ "$DRYRUN" = 1 ] || { mkdir -p "$STATE_DIR"; printf '%s\t%s\n' "$email" "$link" >>"$CLIENTS_FILE"; }
    done
    [ "$DRYRUN" = 1 ] || { chmod 600 "$CLIENTS_FILE" 2>/dev/null || true; say "  ${cD}links saved to ${CLIENTS_FILE}${cX}"; }
}

# ───────────────────────── 10. persist + summary ────────────────────────────
write_credentials(){
    [ "$DRYRUN" = 1 ] && return 0
    umask 077
    mkdir -p "$STATE_DIR"
    cat >"$CRED_FILE" <<EOF
Panel URL : ${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}${PANEL_PATH}
Username  : ${PANEL_USER}
Password  : ${PANEL_PASS}
EOF
    chmod 600 "$CRED_FILE"
}

persist_state(){
    [ "$DRYRUN" = 1 ] && return 0
    umask 077
    cat >"$STATE_FILE" <<EOF
SERVER_IP=${SERVER_IP}
SNI=${SNI}
XHTTP_PATH=${XHTTP_PATH}
INBOUND_NAME=${INBOUND_NAME}
PANEL_SCHEME=${PANEL_SCHEME}
PANEL_PORT=${PANEL_PORT}
PANEL_PATH=${PANEL_PATH}
KEYS=${KEYS}
XUI_VERSION=${XUI_VERSION}
XRAY_VERSION=${XRAY_VERSION}
INSTALLED_AT=$(date -Is)
# machine-readable install paths (source of truth for a future full reset)
XUI_DIR=${XUI_DIR}
XUI_DB_DIR=${XUI_DB_DIR}
CERT_DIR=${CERT_DIR}
SVC_FILE=${SVC_FILE}
BBR_CONF=${BBR_CONF}
HOME_DIR=${HOME_DIR}
EOF
    write_credentials   # rewrite with the finally-detected PANEL_SCHEME
    write_install_info
    chmod 600 "$STATE_FILE"
}

# Human-readable map so that, months later, everything is findable in one place.
write_install_info(){
    [ "$DRYRUN" = 1 ] && return 0
    mkdir -p "$STATE_DIR"
    cat >"$INFO_FILE" <<EOF
KN-VPN-INSTALLER — installation map (generated $(date '+%Y-%m-%d %H:%M:%S %Z'))
────────────────────────────────────────────────────────────
3X-UI panel binary : ${XUI_DIR}            (${XUI_VERSION:-unknown})
3X-UI system logs  : ${XUI_LOG_DIR}
systemd service    : ${SVC_FILE}
panel TLS cert     : ${CERT_DIR}/panel.crt (+ panel.key)
BBR sysctl config  : ${BBR_CONF}
APT packages added : ${DEP_PKGS[*]}

This tool's files (all here in ${HOME_DIR}):
  ├─ panel-credentials.txt   panel URL + login / password
  ├─ state.env               machine-readable parameters
  ├─ clients.txt             client names + their vless:// links
  ├─ INSTALL-INFO.txt        this file
  └─ vpn-installer.log       this installer's log

Panel URL : ${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}${PANEL_PATH}
Re-run 'sudo bash kn-vpn-installer.sh' to reinstall from scratch OR add a new client.
EOF
    chmod 600 "$INFO_FILE"
    ok "Install map written to ${INFO_FILE}"
}

summary(){
    step "Done"
    say "  ${cB}Panel:${cX} ${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"
    say_secret "  ${cB}User :${cX} ${PANEL_USER:-<dry-run>}"
    say_secret "  ${cB}Pass :${cX} ${PANEL_PASS:-<dry-run>}"
    say "  ${cB}XHTTP path:${cX} ${XHTTP_PATH}   ${cB}inbound:${cX} ${INBOUND_NAME}   ${cB}client:${cX} ${CLIENT_NAME}"
    [ "$DRYRUN" != 1 ] && say "  ${cD}(also saved to ${CRED_FILE}, chmod 600)${cX}"
    cat <<EOF

  ${cB}Manual verification${cX} (copy-paste):

  # A. service up + port listening (on this server)
  systemctl status x-ui --no-pager | head -5
  ss -tlnp | grep ':443'

  # B. active probing (from another host on a different network):
  curl -sv --resolve ${SNI}:443:${SERVER_IP} https://${SNI}/ -o /dev/null 2>&1 | grep -E 'SSL connection|HTTP/|subject:'

  # C. panel reachable only at the obscure URL (from your machine):
  curl -sk -o /dev/null -w "%{http_code}\\n" ${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}${PANEL_PATH}
  #   ${PANEL_SCHEME}://${SERVER_IP}:443/ and the bare root must NOT open the panel.

  # D. client TLS fingerprint (on a device connected through the VPN):
  curl -s https://tls.peet.ws/api/all | grep -iE '"ja3"|"ja4"'
  #   chrome requests a browser-like fingerprint; compare against the selected client.

  Further clients: re-run 'sudo bash kn-vpn-installer.sh' -> "Add a new client", or use the panel.
EOF
}

# ───────────── add-a-new-client flow (re-run on an existing install) ─────────
# Reads panel access from /home/kn-vpn-installer, finds the live VLESS+XHTTP+Reality
# inbound, and adds ONE client to it — touching nothing else.
load_panel_access(){
    # shellcheck source=/dev/null
    [ -f "$STATE_FILE" ] && { set -a; . "$STATE_FILE" 2>/dev/null || true; set +a; }
    if [ -f "$CRED_FILE" ]; then
        PANEL_USER=$(sed -n 's/^Username[[:space:]]*:[[:space:]]*//p' "$CRED_FILE" | head -1)
        PANEL_PASS=$(sed -n 's/^Password[[:space:]]*:[[:space:]]*//p' "$CRED_FILE" | head -1)
    fi
    [ -n "${PANEL_PORT:-}" ] || { printf "  Panel port: "; read -r PANEL_PORT; }
    [ -n "${PANEL_PATH:-}" ] || { printf "  Panel webBasePath (e.g. /abc/): "; read -r PANEL_PATH; }
    [ -n "${PANEL_USER:-}" ] || { printf "  Panel username: "; read -r PANEL_USER; }
    [ -n "${PANEL_PASS:-}" ] || { printf "  Panel password: "; read -r PANEL_PASS; }
    [ -n "${SERVER_IP:-}" ]  || { printf "  Server public IP: "; read -r SERVER_IP; }
}

add_client_flow(){
    step "Add a new client to the existing inbound"
    command -v jq >/dev/null && command -v python3 >/dev/null || die "jq/python3 missing (is 3X-UI really installed here?)."
    load_panel_access
    panel_wait "$PANEL_PORT" "$PANEL_PATH"
    panel_login "$PANEL_USER" "$PANEL_PASS"
    local list; list=$(papi "/panel/api/inbounds/list" -X GET) || die "Could not fetch inbounds list."
    echo "$list" | jq -e '.success == true' >/dev/null 2>&1 || die "Inbounds list failed: ${list}"

    # candidate inbounds: vless + reality + xhttp  -> id, remark, sni, pub, sid, path
    local rows; rows=$(python3 - "$list" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
for ib in d.get("obj",[]):
    if ib.get("protocol")!="vless": continue
    try: ss=json.loads(ib.get("streamSettings","{}"))
    except Exception: continue
    if ss.get("security")!="reality" or ss.get("network")!="xhttp": continue
    rs=ss.get("realitySettings",{}); st=rs.get("settings",{})
    sni=(rs.get("serverNames") or [""])[0]
    sid=(rs.get("shortIds") or [""])[0]
    xpath=ss.get("xhttpSettings",{}).get("path","/")
    print("\t".join([str(ib.get("id")), str(ib.get("remark","")), sni, st.get("publicKey",""), sid, xpath]))
PY
)
    [ -n "$rows" ] || die "No VLESS+XHTTP+Reality inbound found to add a client to."
    mapfile -t cand <<<"$rows"
    local sel
    if [ "${#cand[@]}" -eq 1 ]; then
        sel="${cand[0]}"
    else
        say "  Multiple inbounds found:"
        local n=1 r
        for r in "${cand[@]}"; do say "    ${n}) $(cut -f2 <<<"$r")  (id $(cut -f1 <<<"$r"))"; n=$((n+1)); done
        local pick; printf "  Choose inbound [1-${#cand[@]}]: "; read -r pick
        [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#cand[@]}" ] || die "Invalid choice."
        sel="${cand[$((pick-1))]}"
    fi
    local IBID SNI REALITY_PUB SHORT_ID XHTTP_PATH
    IFS=$'\t' read -r IBID _ SNI REALITY_PUB SHORT_ID XHTTP_PATH <<<"$sel"
    ok "Target inbound id ${IBID} (SNI ${SNI}, path ${XHTTP_PATH})."

    # all subIds already in use (uniqueness check)
    local existing; existing=$(python3 - "$list" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); subs=[]
for ib in d.get("obj",[]):
    try: s=json.loads(ib.get("settings","{}"))
    except Exception: continue
    for c in s.get("clients",[]):
        if c.get("subId"): subs.append(c["subId"])
print(" ".join(subs))
PY
)
    # name + subId
    if [ -z "$CLIENT_NAME" ]; then
        printf "  New client name [vpn]: "; read -r CLIENT_NAME
        CLIENT_NAME=$(printf '%s' "${CLIENT_NAME:-vpn}" | tr -cd 'a-zA-Z0-9_.-'); [ -n "$CLIENT_NAME" ] || CLIENT_NAME="vpn"
    fi
    ask_subid "$existing"

    local uid; uid=$(gen_uuid 1)
    local settings; settings=$(python3 - "$uid" "$CLIENT_NAME" "$SUBID" <<'PY'
import json,sys
uid,email,sub=sys.argv[1:4]
print(json.dumps({"clients":[{"id":uid,"flow":"","email":email,"limitIp":0,
  "totalGB":0,"expiryTime":0,"enable":True,"tgId":"","subId":sub,"reset":0}]}))
PY
)
    local resp
    resp=$(papi "/panel/api/inbounds/addClient" -X POST \
            --data-urlencode "id=${IBID}" --data-urlencode "settings=${settings}") \
            || die "addClient request failed."
    echo "$resp" | jq -e '.success == true' >/dev/null 2>&1 || die "Panel rejected the new client: ${resp}"
    ok "Client '${CLIENT_NAME}' added to inbound ${IBID}."

    local link; link=$(make_link "$uid" "$SERVER_IP" "$SNI" "$REALITY_PUB" "$SHORT_ID" "$XHTTP_PATH" "$CLIENT_NAME")
    step "New connection key"
    say_secret "  ${cC}${link}${cX}"
    mkdir -p "$STATE_DIR"; printf '%s\t%s\n' "$CLIENT_NAME" "$link" >>"$CLIENTS_FILE"
    chmod 600 "$CLIENTS_FILE" 2>/dev/null || true
    say "  ${cD}appended to ${CLIENTS_FILE}${cX}"
}

# ──────────────────────────────── main ──────────────────────────────────────
main(){
    while [ $# -gt 0 ]; do
        case "$1" in
            --keys)   KEYS="${2:-}"; shift 2 ;;
            --sni)    SNI_OVERRIDE="${2:-}"; shift 2 ;;
            --client) CLIENT_NAME="${2:-}"; shift 2 ;;
            --inbound) INBOUND_NAME="${2:-}"; shift 2 ;;
            --dry-run) DRYRUN=1; shift ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    [[ "$KEYS" =~ ^[0-9]+$ ]] && [ "$KEYS" -ge 1 ] && [ "$KEYS" -le 100 ] || { warn "Invalid --keys '${KEYS}', using 1."; KEYS=1; }
    mkdir -p "$STATE_DIR" || { printf '%s\n' "Cannot create state directory" >&2; exit 1; }
    chmod 700 "$STATE_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    TMP_DIR="$(mktemp -d /tmp/kvn-vpn.XXXXXXXX)"
    JAR="${TMP_DIR}/panel.cookies"

    say "${cB}KN-VPN-INSTALLER — VLESS + XHTTP + Reality${cX}  ${cD}(dry-run=${DRYRUN})${cX}"
    preflight
    check_existing      # fork: reinstall (FORCE=1) / add client (ADD_CLIENT_MODE=1) / exit
    if [ "$ADD_CLIENT_MODE" = 1 ]; then
        add_client_flow
        say "\n${cB}==> Done (client added).${cX}"
        exit 0
    fi
    check_port_443      # ours on :443 -> noted & removed; foreign -> fatal
    [ "$FORCE" = 1 ] && full_reset   # reinstall = wipe everything we installed
    install_deps
    enable_bbr
    detect_ip
    pick_sni
    ask_clients
    ask_subid           # fresh install: no existing clients, so no uniqueness arg
    say "\n  ${cB}Summary:${cX} IP=${SERVER_IP}  port=443  mode=XHTTP+Reality  SNI=${SNI}  keys=${KEYS}  client=${CLIENT_NAME}"
    if [ "$DRYRUN" != 1 ] && [ "$FORCE" != 1 ]; then
        printf "  Proceed? [y/N] "; read -r a; [[ "$a" =~ ^[Yy]$ ]] || die "Aborted by user."
    fi
    install_3xui
    install_xray
    configure_panel
    disable_subscriptions
    gen_reality
    create_inbound
    print_links
    persist_state
    summary
}
main "$@"
