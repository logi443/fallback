#!/usr/bin/env bash
# ============================================================
#  PasarGuard Fallback Manager  v1.2
#  Local nginx decoy backend for PasarGuard VLESS fallback.
#  Modes: reverse-proxy to a reachable decoy, or serve a local
#  static copy (for servers that cannot reach the decoy site).
#  By - Meysam | github.com/logi443/nginx
# ============================================================
set -euo pipefail

AMBER='\033[38;5;214m'; RESET='\033[0m'; BOLD='\033[1m'
CONFIG_FILE="/etc/pg-fallback.conf"
FALLBACK_CONF="/etc/nginx/conf.d/pg-fallback.conf"
STATIC_DIR="/var/www/pg-fallback"

log(){ echo -e "\033[1;32m[+]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
err(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; }
pause(){ read -rp "Press Enter to continue..." _; }

[[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
command -v apt-get >/dev/null 2>&1 || { err "Ubuntu/Debian only."; exit 1; }

FAKE_SNI=""; FALLBACK_PORT=""; PROXY_VER=""; MODE=""

is_installed(){ [[ -f "$CONFIG_FILE" ]] || [[ -f "$FALLBACK_CONF" ]]; }

save_config(){
    cat > "$CONFIG_FILE" <<EOF
FAKE_SNI="${FAKE_SNI}"
FALLBACK_PORT="${FALLBACK_PORT}"
PROXY_VER="${PROXY_VER}"
MODE="${MODE}"
EOF
}

load_config(){
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    elif [[ -f "$FALLBACK_CONF" ]]; then
        FAKE_SNI="$(grep -oP 'proxy_pass https://\K[^;]+' "$FALLBACK_CONF" | head -1)"
        FALLBACK_PORT="$(grep -oP 'listen 127\.0\.0\.1:\K[0-9]+' "$FALLBACK_CONF" | head -1)"
        grep -q 'proxy_protocol' "$FALLBACK_CONF" && PROXY_VER="on" || PROXY_VER="off"
        grep -q "root ${STATIC_DIR}" "$FALLBACK_CONF" && MODE="static" || MODE="proxy"
        save_config
    fi
}

ensure_nginx(){
    if ! command -v nginx >/dev/null 2>&1; then
        log "Installing nginx..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y nginx
    fi
    mkdir -p /etc/nginx/conf.d
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
}

# Try to fetch the decoy page into STATIC_DIR. Returns 0 on success.
fetch_static(){
    mkdir -p "$STATIC_DIR"
    log "Trying to fetch a static copy of https://${FAKE_SNI} ..."
    if curl -skL --connect-timeout 8 "https://${FAKE_SNI}/" -o "${STATIC_DIR}/index.html" \
         && [[ -s "${STATIC_DIR}/index.html" ]]; then
        log "Fetched decoy page ($(wc -c <"${STATIC_DIR}/index.html") bytes)."
        return 0
    fi
    warn "Could not fetch https://${FAKE_SNI} from this server."
    return 1
}

write_minimal_static(){
    mkdir -p "$STATIC_DIR"
    cat > "${STATIC_DIR}/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${FAKE_SNI}</title></head>
<body><h1>${FAKE_SNI}</h1><p>Welcome.</p></body></html>
EOF
    log "Wrote a minimal placeholder page."
}

# Fetch the page from a mirror URL (a host this server CAN reach that serves
# the same page). Returns 0 on success.
fetch_from_url(){
    local url="$1"
    mkdir -p "$STATIC_DIR"
    log "Fetching static copy from ${url} ..."
    if curl -skL --connect-timeout 10 "$url" -o "${STATIC_DIR}/index.html" \
         && [[ -s "${STATIC_DIR}/index.html" ]]; then
        log "Fetched page ($(wc -c <"${STATIC_DIR}/index.html") bytes)."
        return 0
    fi
    warn "Could not fetch ${url}."
    return 1
}

# Copy a local HTML file (that you transferred from another server) into place.
use_local_file(){
    local f="$1"
    [[ -f "$f" && -s "$f" ]] || { err "File not found or empty: $f"; return 1; }
    mkdir -p "$STATIC_DIR"
    cp "$f" "${STATIC_DIR}/index.html"
    log "Installed local file ($(wc -c <"${STATIC_DIR}/index.html") bytes)."
}

# Populate the static page using whichever source the user picks.
populate_static(){
    echo
    echo "Where should the static page come from?"
    echo " 1) Fetch live from ${FAKE_SNI} (needs access to it)"
    echo " 2) Local HTML file (one you copied from another server)"
    echo " 3) Mirror URL (another host this server CAN reach, same page)"
    echo " 4) Minimal placeholder page"
    read -rp "Select [1-4] (default 1): " s
    case "$s" in
        2) read -rp "Path to local HTML file: " f; use_local_file "$f" || write_minimal_static;;
        3) read -rp "Mirror URL (https://...): " u; fetch_from_url "$u" || write_minimal_static;;
        4) write_minimal_static;;
        *) fetch_static || { warn "Falling back to placeholder."; write_minimal_static; };;
    esac
}

write_conf(){
    local listen_line="listen 127.0.0.1:${FALLBACK_PORT} default_server;"
    local realip=""
    if [[ "$PROXY_VER" == "on" ]]; then
        listen_line="listen 127.0.0.1:${FALLBACK_PORT} proxy_protocol default_server;"
        realip="    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;"
    fi

    if [[ "$MODE" == "static" ]]; then
        cat > "$FALLBACK_CONF" <<EOF
# managed-by-pg-fallback
server {
    ${listen_line}
    server_name _;
${realip}
    root ${STATIC_DIR};
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
    else
        cat > "$FALLBACK_CONF" <<EOF
# managed-by-pg-fallback
server {
    ${listen_line}
    server_name _;
${realip}
    location / {
        proxy_pass https://${FAKE_SNI};
        proxy_set_header Host ${FAKE_SNI};
        proxy_ssl_server_name on;
        proxy_ssl_name ${FAKE_SNI};
        proxy_ssl_verify off;
        proxy_hide_header Set-Cookie;
        proxy_http_version 1.1;
    }
}
EOF
    fi
}

apply(){
    write_conf
    if nginx -t; then
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
        log "nginx reloaded."
    else
        err "nginx config test failed. Not reloading."
        return 1
    fi
}

print_cfg(){
    echo " Fake SNI domain : ${FAKE_SNI}"
    echo " Fallback port   : 127.0.0.1:${FALLBACK_PORT}"
    echo " Mode            : ${MODE}"
    echo " PROXY protocol  : ${PROXY_VER} $([[ "$PROXY_VER" == "on" ]] && echo '(inbound xver 1 or 2)' || echo '(inbound xver 0)')"
}

do_install(){
    if is_installed; then
        warn "Already installed."; load_config; print_cfg; pause; return
    fi
    echo
    read -rp "Fake SNI domain (e.g. soft98.ir): " FAKE_SNI
    [[ -z "$FAKE_SNI" ]] && { err "SNI cannot be empty."; return; }

    read -rp "Fallback local port (default: 8080): " FALLBACK_PORT
    FALLBACK_PORT="${FALLBACK_PORT:-8080}"

    echo
    echo "Fallback mode:"
    echo " 1) Reverse-proxy — server fetches ${FAKE_SNI} live (needs access to it)"
    echo " 2) Static        — serve a local copy of the page (for servers that"
    echo "                    cannot reach ${FAKE_SNI}, e.g. geo-blocked decoys)"
    read -rp "Select [1/2] (default 1): " m
    case "$m" in 2) MODE="static";; *) MODE="proxy";; esac

    echo
    echo "PROXY protocol between PasarGuard and this fallback:"
    echo " 1) Off  — inbound fallback xver = 0 (recommended)"
    echo " 2) On   — inbound fallback xver = 1 or 2 (nginx auto-detects)"
    read -rp "Select [1/2] (default 1): " p
    case "$p" in 2) PROXY_VER="on";; *) PROXY_VER="off";; esac

    echo
    echo "------------------------------------------------"
    print_cfg
    echo "------------------------------------------------"
    read -rp "Proceed? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }

    ensure_nginx

    if [[ "$MODE" == "static" ]]; then
        populate_static
    fi

    apply && save_config && log "Installation complete."
    echo
    warn "In the PasarGuard inbound: set TLS fallback dest to 127.0.0.1:${FALLBACK_PORT},"
    warn "PROXY protocol (xver) to $([[ "$PROXY_VER" == "on" ]] && echo '1 or 2' || echo '0'), and ALPN to http/1.1."
    pause
}

edit_menu(){
    if ! is_installed; then err "Not installed. Use option 1."; pause; return; fi
    load_config
    while true; do
        clear
        echo "=== Edit Configuration ==="
        echo " 1) Fake SNI domain   [current: ${FAKE_SNI}]"
        echo " 2) Fallback port     [current: ${FALLBACK_PORT}]"
        echo " 3) Mode              [current: ${MODE}]"
        echo " 4) PROXY protocol    [current: ${PROXY_VER}]"
        echo " 5) Refresh static page (re-pick source)"
        echo " 0) Back"
        echo
        read -rp "Select: " ch
        case "$ch" in
            1) read -rp "New SNI (0=cancel): " v; [[ "$v" == "0" || -z "$v" ]] && { warn "Unchanged."; pause; continue; }; FAKE_SNI="$v";;
            2) read -rp "New port (0=cancel): " v; [[ "$v" == "0" || -z "$v" ]] && { warn "Unchanged."; pause; continue; }; FALLBACK_PORT="$v";;
            3) if [[ "$MODE" == "static" ]]; then MODE="proxy"; else MODE="static"; populate_static; fi;;
            4) if [[ "$PROXY_VER" == "on" ]]; then PROXY_VER="off"; log "xver -> 0 in panel."; else PROXY_VER="on"; log "xver -> 1 or 2 in panel."; fi;;
            5) if [[ "$MODE" == "static" ]]; then populate_static; else warn "Only applies in static mode."; fi; pause; continue;;
            0) return;;
            *) err "Invalid."; pause; continue;;
        esac
        apply && save_config && log "Updated."
        pause
    done
}

do_remove(){
    if ! is_installed; then err "Nothing to remove."; pause; return; fi
    read -rp "Remove the fallback config? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }
    rm -f "$FALLBACK_CONF" "$CONFIG_FILE"
    rm -rf "$STATIC_DIR"
    nginx -t && systemctl reload nginx 2>/dev/null || true
    log "Removed."
    pause
}

do_status(){
    echo "=== nginx ==="
    systemctl is-active nginx
    if is_installed; then
        load_config
        echo "=== listening ==="
        ss -ltnp 2>/dev/null | grep ":${FALLBACK_PORT}\b" || warn "nothing on ${FALLBACK_PORT}"
        echo "=== config ==="
        print_cfg
        echo "=== live test (through fallback) ==="
        curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "Host: ${FAKE_SNI}" \
            $([[ "$PROXY_VER" == "on" ]] && echo "--haproxy-protocol") \
            "http://127.0.0.1:${FALLBACK_PORT}/" 2>/dev/null || warn "test failed"
    else
        warn "Not installed."
    fi
    pause
}

main_menu(){
    while true; do
        clear
        echo -e "${AMBER}${BOLD}"
        cat <<'B'
╔══════════════════════════════════════════════════╗
║            PasarGuard Fallback Manager           ║
║                       v1.2                       ║
╠══════════════════════════════════════════════════╣
║ By     : Meysam                                  ║
║ GitHub : github.com/logi443/nginx                ║
╚══════════════════════════════════════════════════╝
B
        echo -e "${RESET}"
        if is_installed; then echo -e "  Status: \033[1;32mINSTALLED\033[0m"; else echo -e "  Status: \033[1;31mNOT INSTALLED\033[0m"; fi
        echo "------------------------------------------------"
        echo " 1) Install"
        echo " 2) Edit configuration"
        echo " 3) Remove"
        echo " 4) Service status / test"
        echo " 0) Exit"
        echo "================================================"
        read -rp "Select an option: " choice
        case "$choice" in
            1) do_install;;
            2) edit_menu;;
            3) do_remove;;
            4) do_status;;
            0) echo "Bye."; exit 0;;
            *) err "Invalid option."; pause;;
        esac
    done
}

main_menu
