#!/usr/bin/env bash
# ============================================================
#  PasarGuard Fallback Manager  v1.0
#  Local nginx decoy backend for PasarGuard VLESS fallback.
#  By - Meysam | github.com/logi443/nginx
# ============================================================
set -euo pipefail

AMBER='\033[38;5;214m'; RESET='\033[0m'; BOLD='\033[1m'
CONFIG_FILE="/etc/pg-fallback.conf"
FALLBACK_CONF="/etc/nginx/conf.d/pg-fallback.conf"

log(){ echo -e "\033[1;32m[+]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
err(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; }
pause(){ read -rp "Press Enter to continue..." _; }

[[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
command -v apt-get >/dev/null 2>&1 || { err "Ubuntu/Debian only."; exit 1; }

FAKE_SNI=""; FALLBACK_PORT=""; PROXY_VER=""

is_installed(){ [[ -f "$CONFIG_FILE" ]] || [[ -f "$FALLBACK_CONF" ]]; }

load_config(){
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    elif [[ -f "$FALLBACK_CONF" ]]; then
        FAKE_SNI="$(grep -oP 'proxy_pass https://\K[^;]+' "$FALLBACK_CONF" | head -1)"
        FALLBACK_PORT="$(grep -oP 'listen 127\.0\.0\.1:\K[0-9]+' "$FALLBACK_CONF" | head -1)"
        grep -q 'proxy_protocol' "$FALLBACK_CONF" && PROXY_VER="on" || PROXY_VER="off"
        save_config
    fi
}

save_config(){
    cat > "$CONFIG_FILE" <<EOF
FAKE_SNI="${FAKE_SNI}"
FALLBACK_PORT="${FALLBACK_PORT}"
PROXY_VER="${PROXY_VER}"
EOF
}

ensure_nginx(){
    if ! command -v nginx >/dev/null 2>&1; then
        log "Installing nginx..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y nginx
    fi
    mkdir -p /etc/nginx/conf.d
    # never let nginx grab 80/443 — we only host a local backend
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
}

write_conf(){
    # PROXY_VER is "off" (xray sends a clean request) or "on" (xray sends a
    # PROXY-protocol header first; nginx auto-detects v1 or v2). They must match
    # the inbound's fallback xver: 0 => off, 1 or 2 => on.
    local listen_line="listen 127.0.0.1:${FALLBACK_PORT} default_server;"
    local realip=""
    if [[ "$PROXY_VER" == "on" ]]; then
        listen_line="listen 127.0.0.1:${FALLBACK_PORT} proxy_protocol default_server;"
        realip="    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;"
    fi

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
    echo " PROXY protocol  : ${PROXY_VER} $([[ "$PROXY_VER" == "on" ]] && echo '(set inbound fallback xver to 1 or 2)' || echo '(set inbound fallback xver to 0)')"
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
    echo "PROXY protocol between PasarGuard and this fallback:"
    echo " 1) Off  — inbound fallback xver = 0 (recommended, simplest)"
    echo " 2) On   — inbound fallback xver = 1 or 2 (nginx auto-detects the version)"
    read -rp "Select [1/2] (default 1): " p
    case "$p" in 2) PROXY_VER="on";; *) PROXY_VER="off";; esac

    echo
    echo "------------------------------------------------"
    print_cfg
    echo "------------------------------------------------"
    read -rp "Proceed? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }

    ensure_nginx
    apply && save_config && log "Installation complete."
    echo
    warn "In the PasarGuard inbound, set TLS fallback dest to 127.0.0.1:${FALLBACK_PORT}"
    warn "and PROXY protocol (xver) to $([[ "$PROXY_VER" == "on" ]] && echo '1 or 2' || echo '0')."
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
        echo " 3) PROXY protocol    [current: ${PROXY_VER}]"
        echo " 0) Back"
        echo
        read -rp "Select: " ch
        case "$ch" in
            1) read -rp "New SNI (0=cancel): " v; [[ "$v" == "0" || -z "$v" ]] && { warn "Unchanged."; pause; continue; }; FAKE_SNI="$v";;
            2) read -rp "New port (0=cancel): " v; [[ "$v" == "0" || -z "$v" ]] && { warn "Unchanged."; pause; continue; }; FALLBACK_PORT="$v";;
            3) if [[ "$PROXY_VER" == "on" ]]; then PROXY_VER="off"; log "PROXY protocol OFF — set inbound xver to 0."; else PROXY_VER="on"; log "PROXY protocol ON — set inbound xver to 1 or 2."; fi;;
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
║                       v1.0                       ║
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
