#!/usr/bin/env bash
# ============================================================
#  PasarGuard Fallback Manager  v1.4
#  Local nginx decoy backend for PasarGuard VLESS fallback.
#
#  Roles:
#    relay  — on an Iran server that CAN reach the decoy; proxies
#             to it and is shared by many edge servers.
#    edge   — on a foreign server; sends its fallback to the relay
#             (or proxies the decoy directly, or serves a static copy).
#
#  By - Meysam | github.com/logi443/nginx
# ============================================================
set -euo pipefail

AMBER='\033[38;5;214m'; RESET='\033[0m'; BOLD='\033[1m'
CONFIG_FILE="/etc/pg-fallback.conf"
FALLBACK_CONF="/etc/nginx/conf.d/pg-fallback.conf"
RELAY_CONF="/etc/nginx/conf.d/pg-fallback-relay.conf"
STATIC_DIR="/var/www/pg-fallback"

log(){ echo -e "\033[1;32m[+]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
err(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; }
pause(){ read -rp "Press Enter to continue..." _; }

[[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
command -v apt-get >/dev/null 2>&1 || { err "Ubuntu/Debian only."; exit 1; }

# shared
ROLE=""; FAKE_SNI=""
# edge
FALLBACK_PORT=""; PROXY_VER=""; SOURCE=""; RELAY_ADDR=""
# relay
RELAY_PORT=""; ALLOWED_IPS=""

is_installed(){ [[ -f "$CONFIG_FILE" ]] || [[ -f "$FALLBACK_CONF" ]] || [[ -f "$RELAY_CONF" ]]; }

save_config(){
    cat > "$CONFIG_FILE" <<EOF
ROLE="${ROLE}"
FAKE_SNI="${FAKE_SNI}"
FALLBACK_PORT="${FALLBACK_PORT}"
PROXY_VER="${PROXY_VER}"
SOURCE="${SOURCE}"
RELAY_ADDR="${RELAY_ADDR}"
RELAY_PORT="${RELAY_PORT}"
ALLOWED_IPS="${ALLOWED_IPS}"
EOF
}

load_config(){
    [[ -f "$CONFIG_FILE" ]] && { source "$CONFIG_FILE"; return; }
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

# ---------- RELAY (Iran) ----------
write_relay_conf(){
    local allow_block=""
    if [[ -n "$ALLOWED_IPS" ]]; then
        for ip in $ALLOWED_IPS; do allow_block+="    allow ${ip};
"; done
        allow_block+="    deny all;"
    fi
    mkdir -p /var/cache/nginx/pg-fallback
    cat > "$RELAY_CONF" <<EOF
# managed-by-pg-fallback (relay)
proxy_cache_path /var/cache/nginx/pg-fallback levels=1:2 keys_zone=pgfb:10m max_size=100m inactive=60m use_temp_path=off;

server {
    listen 0.0.0.0:${RELAY_PORT};
    server_name _;
${allow_block}
    location / {
        proxy_pass https://${FAKE_SNI};
        proxy_set_header Host ${FAKE_SNI};
        proxy_ssl_server_name on;
        proxy_ssl_name ${FAKE_SNI};
        proxy_ssl_verify off;
        proxy_hide_header Set-Cookie;
        proxy_http_version 1.1;

        # Cache the decoy so many edges don't hammer the origin (avoids 429).
        proxy_cache pgfb;
        proxy_cache_valid 200 302 10m;
        proxy_cache_valid any 1m;
        proxy_ignore_headers Cache-Control Expires Set-Cookie;
        add_header X-Cache-Status \$upstream_cache_status;
    }
}
EOF
}

# ---------- EDGE (foreign) ----------
fetch_to_static(){
    local src="$1"  # a full URL
    mkdir -p "$STATIC_DIR"
    log "Fetching static copy from ${src} ..."
    if curl -skL --connect-timeout 10 "$src" -o "${STATIC_DIR}/index.html" && [[ -s "${STATIC_DIR}/index.html" ]]; then
        log "Fetched ($(wc -c <"${STATIC_DIR}/index.html") bytes)."; return 0
    fi
    warn "Fetch failed."; return 1
}
write_minimal_static(){
    mkdir -p "$STATIC_DIR"
    printf '<!doctype html><html lang="fa"><head><meta charset="utf-8"><title>%s</title></head><body><h1>%s</h1></body></html>\n' "$FAKE_SNI" "$FAKE_SNI" > "${STATIC_DIR}/index.html"
    log "Wrote placeholder page."
}
use_local_file(){
    [[ -f "$1" && -s "$1" ]] || { err "File not found/empty: $1"; return 1; }
    mkdir -p "$STATIC_DIR"; cp "$1" "${STATIC_DIR}/index.html"
    log "Installed local file ($(wc -c <"${STATIC_DIR}/index.html") bytes)."
}
populate_static(){
    echo
    echo "Static page source:"
    echo " 1) Fetch live from ${FAKE_SNI}"
    echo " 2) Local HTML file"
    echo " 3) Mirror URL"
    echo " 4) Minimal placeholder"
    read -rp "Select [1-4] (default 4): " s
    case "$s" in
        1) fetch_to_static "https://${FAKE_SNI}/" || write_minimal_static;;
        2) read -rp "Path to local HTML file: " f; use_local_file "$f" || write_minimal_static;;
        3) read -rp "Mirror URL (https://...): " u; fetch_to_static "$u" || write_minimal_static;;
        *) write_minimal_static;;
    esac
}

write_edge_conf(){
    local listen_line="listen 127.0.0.1:${FALLBACK_PORT} default_server;"
    local realip=""
    if [[ "$PROXY_VER" == "on" ]]; then
        listen_line="listen 127.0.0.1:${FALLBACK_PORT} proxy_protocol default_server;"
        realip="    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;"
    fi

    case "$SOURCE" in
        relay)
            cat > "$FALLBACK_CONF" <<EOF
# managed-by-pg-fallback (edge->relay)
server {
    ${listen_line}
    server_name _;
${realip}
    location / {
        proxy_pass http://${RELAY_ADDR};
        proxy_set_header Host ${FAKE_SNI};
        proxy_http_version 1.1;
    }
}
EOF
            ;;
        direct)
            cat > "$FALLBACK_CONF" <<EOF
# managed-by-pg-fallback (edge->direct)
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
            ;;
        static)
            cat > "$FALLBACK_CONF" <<EOF
# managed-by-pg-fallback (edge->static)
server {
    ${listen_line}
    server_name _;
${realip}
    charset utf-8;
    root ${STATIC_DIR};
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
            ;;
    esac
}

apply(){
    [[ "$ROLE" == "relay" ]] && write_relay_conf || write_edge_conf
    if nginx -t; then
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
        log "nginx reloaded."
    else
        err "nginx config test failed. Not reloading."; return 1
    fi
}

print_cfg(){
    echo " Role            : ${ROLE}"
    echo " Fake SNI domain : ${FAKE_SNI}"
    if [[ "$ROLE" == "relay" ]]; then
        echo " Relay port      : 0.0.0.0:${RELAY_PORT}"
        echo " Allowed IPs     : ${ALLOWED_IPS:-ANY (open — restrict!)}"
    else
        echo " Fallback port   : 127.0.0.1:${FALLBACK_PORT}"
        echo " Source          : ${SOURCE}$([[ "$SOURCE" == relay ]] && echo " (${RELAY_ADDR})")"
        echo " PROXY protocol  : ${PROXY_VER} $([[ "$PROXY_VER" == on ]] && echo '(inbound xver 1/2)' || echo '(inbound xver 0)')"
    fi
}

install_relay(){
    read -rp "Fake SNI domain to proxy (e.g. soft98.ir): " FAKE_SNI
    [[ -z "$FAKE_SNI" ]] && { err "SNI empty."; return; }
    read -rp "Relay listen port (default: 8443): " RELAY_PORT
    RELAY_PORT="${RELAY_PORT:-8443}"
    echo "Allowed edge IPs (space-separated, empty = allow any — NOT recommended):"
    read -rp "> " ALLOWED_IPS

    echo "------------------------------------------------"
    print_cfg
    echo "------------------------------------------------"
    read -rp "Proceed? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }

    ensure_nginx
    apply && save_config && log "Relay installed."
    echo
    warn "On each edge server, point its fallback source to this relay at:"
    warn "    <this server's IP>:${RELAY_PORT}"
    [[ -z "$ALLOWED_IPS" ]] && err "WARNING: relay is open to any IP — add edge IPs to restrict it."
    pause
}

install_edge(){
    read -rp "Fake SNI domain (e.g. soft98.ir): " FAKE_SNI
    [[ -z "$FAKE_SNI" ]] && { err "SNI empty."; return; }
    read -rp "Fallback local port (default: 8080): " FALLBACK_PORT
    FALLBACK_PORT="${FALLBACK_PORT:-8080}"

    echo
    echo "Where should the decoy content come from?"
    echo " 1) Relay  — proxy to a central Iran relay (IP:port) [recommended]"
    echo " 2) Direct — proxy straight to ${FAKE_SNI} (needs access to it)"
    echo " 3) Static — serve a local copy (no live access needed)"
    read -rp "Select [1-3] (default 1): " s
    case "$s" in
        2) SOURCE="direct";;
        3) SOURCE="static";;
        *) SOURCE="relay"; read -rp "Relay address (IP:port, e.g. 1.2.3.4:8443): " RELAY_ADDR
           [[ -z "$RELAY_ADDR" ]] && { err "Relay address empty."; return; };;
    esac

    echo
    echo "PROXY protocol between PasarGuard and this fallback:"
    echo " 1) Off  — inbound xver = 0 (recommended)"
    echo " 2) On   — inbound xver = 1 or 2"
    read -rp "Select [1/2] (default 1): " p
    case "$p" in 2) PROXY_VER="on";; *) PROXY_VER="off";; esac

    echo "------------------------------------------------"
    print_cfg
    echo "------------------------------------------------"
    read -rp "Proceed? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }

    ensure_nginx
    [[ "$SOURCE" == "static" ]] && populate_static
    apply && save_config && log "Edge installed."
    echo
    warn "In the PasarGuard inbound: TLS fallback dest = 127.0.0.1:${FALLBACK_PORT},"
    warn "PROXY protocol (xver) = $([[ "$PROXY_VER" == on ]] && echo '1 or 2' || echo '0'), ALPN = http/1.1."
    pause
}

do_install(){
    if is_installed; then warn "Already installed."; load_config; print_cfg; pause; return; fi
    echo
    echo "What is this server's role?"
    echo " 1) Edge  — foreign server (PasarGuard node), needs a fallback"
    echo " 2) Relay — Iran server that can reach the decoy, shared by edges"
    echo " 0) Cancel"
    read -rp "Select: " r
    case "$r" in
        1) ROLE="edge"; install_edge;;
        2) ROLE="relay"; install_relay;;
        0) warn "Cancelled.";;
        *) err "Invalid.";;
    esac
}

edit_menu(){
    if ! is_installed; then err "Not installed. Use option 1."; pause; return; fi
    load_config
    while true; do
        clear
        echo "=== Edit Configuration (role: ${ROLE}) ==="
        echo " 1) Fake SNI domain   [current: ${FAKE_SNI}]"
        if [[ "$ROLE" == "relay" ]]; then
            echo " 2) Relay port        [current: ${RELAY_PORT}]"
            echo " 3) Allowed edge IPs  [current: ${ALLOWED_IPS:-ANY}]"
        else
            echo " 2) Fallback port     [current: ${FALLBACK_PORT}]"
            echo " 3) Source            [current: ${SOURCE}]"
            echo " 4) Relay address     [current: ${RELAY_ADDR:-n/a}]"
            echo " 5) PROXY protocol    [current: ${PROXY_VER}]"
        fi
        echo " 0) Back"
        echo
        read -rp "Select: " ch
        case "$ch" in
            1) read -rp "New SNI (0=cancel): " v; [[ "$v" == "0" || -z "$v" ]] && { warn "Unchanged."; pause; continue; }; FAKE_SNI="$v";;
            2) if [[ "$ROLE" == "relay" ]]; then
                   read -rp "New relay port (0=cancel): " v; [[ "$v" == "0" || -z "$v" ]] && { warn "Unchanged."; pause; continue; }; RELAY_PORT="$v"
               else
                   read -rp "New fallback port (0=cancel): " v; [[ "$v" == "0" || -z "$v" ]] && { warn "Unchanged."; pause; continue; }; FALLBACK_PORT="$v"
               fi;;
            3) if [[ "$ROLE" == "relay" ]]; then
                   echo "New allowed IPs (space-separated, empty=any):"; read -rp "> " ALLOWED_IPS
               else
                   echo "Source: 1) relay  2) direct  3) static"; read -rp "Select: " s
                   case "$s" in 1) SOURCE="relay"; read -rp "Relay address (IP:port): " RELAY_ADDR;; 2) SOURCE="direct";; 3) SOURCE="static"; populate_static;; *) warn "Unchanged."; pause; continue;; esac
               fi;;
            4) [[ "$ROLE" == "relay" ]] && { warn "N/A for relay."; pause; continue; }
               read -rp "New relay address IP:port (0=cancel): " v; [[ "$v" == "0" || -z "$v" ]] && { warn "Unchanged."; pause; continue; }; RELAY_ADDR="$v"; SOURCE="relay";;
            5) [[ "$ROLE" == "relay" ]] && { warn "N/A for relay."; pause; continue; }
               if [[ "$PROXY_VER" == "on" ]]; then PROXY_VER="off"; log "xver -> 0 in panel."; else PROXY_VER="on"; log "xver -> 1 or 2 in panel."; fi;;
            0) return;;
            *) err "Invalid."; pause; continue;;
        esac
        apply && save_config && log "Updated."
        pause
    done
}

do_remove(){
    if ! is_installed; then err "Nothing to remove."; pause; return; fi
    read -rp "Remove fallback config? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }
    rm -f "$FALLBACK_CONF" "$RELAY_CONF" "$CONFIG_FILE"; rm -rf "$STATIC_DIR" /var/cache/nginx/pg-fallback
    nginx -t && systemctl reload nginx 2>/dev/null || true
    log "Removed."; pause
    read -rp "Remove fallback config? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }
    rm -f "$FALLBACK_CONF" "$RELAY_CONF" "$CONFIG_FILE"; rm -rf "$STATIC_DIR" /var/cache/nginx/pg-fallback
    nginx -t && systemctl reload nginx 2>/dev/null || true
    log "Removed."; pause
}

do_status(){
    echo "=== nginx ==="; systemctl is-active nginx
    if is_installed; then
        load_config
        echo "=== config ==="; print_cfg
        echo "=== listening ==="
        if [[ "$ROLE" == "relay" ]]; then
            ss -ltnp 2>/dev/null | grep ":${RELAY_PORT}\b" || warn "nothing on ${RELAY_PORT}"
            echo "=== live test (relay -> ${FAKE_SNI}) ==="
            curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://127.0.0.1:${RELAY_PORT}/" 2>/dev/null || warn "test failed"
        else
            ss -ltnp 2>/dev/null | grep ":${FALLBACK_PORT}\b" || warn "nothing on ${FALLBACK_PORT}"
            echo "=== live test (through fallback) ==="
            curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "Host: ${FAKE_SNI}" \
                $([[ "$PROXY_VER" == on ]] && echo "--haproxy-protocol") \
                "http://127.0.0.1:${FALLBACK_PORT}/" 2>/dev/null || warn "test failed"
        fi
    else warn "Not installed."; fi
    pause
}

main_menu(){
    while true; do
        clear
        echo -e "${AMBER}${BOLD}"
        cat <<'B'
╔══════════════════════════════════════════════════╗
║            PasarGuard Fallback Manager           ║
║                       v1.4                       ║
╠══════════════════════════════════════════════════╣
║ By     : Meysam                                  ║
║ GitHub : github.com/logi443/nginx                ║
╚══════════════════════════════════════════════════╝
B
        echo -e "${RESET}"
        if is_installed; then
            load_config
            echo -e "  Status: \033[1;32mINSTALLED\033[0m  (role: ${ROLE})"
        else
            echo -e "  Status: \033[1;31mNOT INSTALLED\033[0m"
        fi
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
