#!/usr/bin/env bash
# switch-mode.sh — Switch between VPS proxy modes without reinstalling WireGuard
#
# Usage:
#   sudo bash scripts/switch-mode.sh
#
# Detects the current mode, prompts for a target, and performs only the
# changes needed for that transition. WireGuard is never touched.
#
# Supported transitions:
#   1 → 2 : add Trojan standalone (direct TLS, HTTP-01 cert)
#   1 → 3 : add Trojan + Cloudflare (WebSocket, DNS-01 cert)
#   2 → 3 : switch transport to WebSocket, update cert renewal to DNS-01
#   3 → 2 : switch transport to direct TLS, update cert renewal to HTTP-01
#   2 → 1 : stop/disable Trojan, close port 443
#   3 → 1 : stop/disable Trojan, close port 443

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="/etc/trojan-go/config.json"
CF_CREDS="/etc/letsencrypt/cloudflare.ini"

# ── Preflight ──────────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash scripts/switch-mode.sh)" >&2
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

detect_mode() {
    if ! systemctl is-active --quiet trojan-go 2>/dev/null; then
        echo "1"
        return
    fi
    if python3 -c "
import json, sys
d = json.load(open('$CONFIG_FILE'))
sys.exit(0 if d.get('websocket', {}).get('enabled') else 1)
" 2>/dev/null; then
        echo "3"
    else
        echo "2"
    fi
}

read_config_domain() {
    python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['ssl']['sni'])"
}

read_config_password() {
    python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['password'][0])"
}

write_config_standalone() {
    local domain="$1" password="$2"
    local cert_dir="/etc/letsencrypt/live/$domain"
    mkdir -p /var/log/trojan-go
    cat > "$CONFIG_FILE" <<EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": 443,
    "remote_addr": "127.0.0.1",
    "remote_port": 8080,
    "password": [
        "$password"
    ],
    "ssl": {
        "cert": "$cert_dir/fullchain.pem",
        "key": "$cert_dir/privkey.pem",
        "sni": "$domain",
        "session_ticket": true,
        "reuse_session": true
    },
    "tcp": {
        "prefer_ipv4": true,
        "no_delay": true,
        "keep_alive": true,
        "fast_open": false
    },
    "log_level": 1,
    "log_file": "/var/log/trojan-go/access.log"
}
EOF
    chmod 600 "$CONFIG_FILE"
}

write_config_cloudflare() {
    local domain="$1" password="$2"
    local cert_dir="/etc/letsencrypt/live/$domain"
    mkdir -p /var/log/trojan-go
    cat > "$CONFIG_FILE" <<EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": 443,
    "remote_addr": "127.0.0.1",
    "remote_port": 8080,
    "password": [
        "$password"
    ],
    "ssl": {
        "cert": "$cert_dir/fullchain.pem",
        "key": "$cert_dir/privkey.pem",
        "sni": "$domain",
        "session_ticket": true,
        "reuse_session": true
    },
    "websocket": {
        "enabled": true,
        "path": "/trojan",
        "host": "$domain"
    },
    "tcp": {
        "prefer_ipv4": true,
        "no_delay": true,
        "keep_alive": true,
        "fast_open": false
    },
    "log_level": 1,
    "log_file": "/var/log/trojan-go/access.log"
}
EOF
    chmod 600 "$CONFIG_FILE"
}

# Update the certbot renewal config so future renewals use the right challenge.
# The existing cert is not re-issued — it's valid regardless of challenge method.
update_renewal_dns01() {
    local domain="$1" cf_token="$2"
    echo "==> Installing certbot-dns-cloudflare plugin..."
    apt-get install -y -qq python3-certbot-dns-cloudflare

    echo "==> Writing Cloudflare credentials for cert renewal..."
    cat > "$CF_CREDS" <<EOF
dns_cloudflare_api_token = $cf_token
EOF
    chmod 600 "$CF_CREDS"

    local renewal="/etc/letsencrypt/renewal/$domain.conf"
    if [[ -f "$renewal" ]]; then
        sed -i 's/^authenticator =.*/authenticator = dns-cloudflare/' "$renewal"
        grep -q '^dns_cloudflare_credentials' "$renewal" \
            || echo "dns_cloudflare_credentials = $CF_CREDS" >> "$renewal"
        sed -i '/^http01_port/d' "$renewal"
    fi
    echo "    Future renewals will use DNS-01 (Cloudflare)."
}

update_renewal_http01() {
    local domain="$1"
    local renewal="/etc/letsencrypt/renewal/$domain.conf"
    if [[ -f "$renewal" ]]; then
        sed -i 's/^authenticator =.*/authenticator = standalone/' "$renewal"
        sed -i '/^dns_cloudflare_credentials/d' "$renewal"
        sed -i '/^dns_cloudflare_propagation_seconds/d' "$renewal"
    fi
    echo "    Future renewals will use HTTP-01 (standalone)."
}

teardown_trojan() {
    echo "==> Stopping and disabling trojan-go..."
    systemctl stop trojan-go 2>/dev/null || true
    systemctl disable trojan-go 2>/dev/null || true

    echo "==> Applying iptables rules (port 443 closed)..."
    bash "$REPO_ROOT/vps/iptables/rules.sh"

    echo ""
    echo "  trojan-go binary, config, and TLS certificate kept in place."
    echo "  To fully purge:  apt remove trojan-go && rm -rf /etc/trojan-go"
}

mode_label() {
    case "$1" in
        1) echo "WireGuard only" ;;
        2) echo "WireGuard + Trojan (standalone)" ;;
        3) echo "WireGuard + Trojan + Cloudflare CDN" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

CURRENT="$(detect_mode)"

echo ""
echo "┌─────────────────────────────────────────────────┐"
echo "│       VPS-to-Local — Mode Switch                │"
echo "└─────────────────────────────────────────────────┘"
echo ""
echo "Current mode: $CURRENT — $(mode_label "$CURRENT")"
echo ""
echo "Available target modes:"
echo ""
for M in 1 2 3; do
    [[ "$M" == "$CURRENT" ]] && continue
    case "$M" in
        1) echo "  1) WireGuard only" ;;
        2) echo "  2) WireGuard + Trojan (standalone)" ;;
        3) echo "  3) WireGuard + Trojan + Cloudflare CDN" ;;
    esac
done
echo ""

while true; do
    read -rp "Enter target mode [1/2/3]: " TARGET
    if [[ "$TARGET" == "$CURRENT" ]]; then
        echo "  Already in mode $TARGET ($(mode_label "$TARGET")) — nothing to do."
        exit 0
    fi
    case "$TARGET" in
        1|2|3) break ;;
        *) echo "  Please enter 1, 2, or 3." ;;
    esac
done

echo ""

# ── Collect inputs ─────────────────────────────────────────────────────────────

if [[ "$TARGET" == "2" || "$TARGET" == "3" ]]; then
    if [[ "$CURRENT" == "1" ]]; then
        read -rp "Domain (e.g. proxy.example.com): " DOMAIN
        [[ -z "$DOMAIN" ]] && { echo "ERROR: domain required." >&2; exit 1; }
        read -rsp "Trojan password: " PASSWORD; echo ""
        [[ -z "$PASSWORD" ]] && { echo "ERROR: password required." >&2; exit 1; }
    else
        DOMAIN="$(read_config_domain)"
        PASSWORD="$(read_config_password)"
        echo "  Keeping existing domain:   $DOMAIN"
        echo "  Keeping existing password: (from /etc/trojan-go/config.json)"
    fi
fi

if [[ "$TARGET" == "3" ]]; then
    echo ""
    echo "Cloudflare API token — needs Zone:DNS:Edit permission only."
    echo "(Used to configure DNS-01 cert renewals. Revoke or scope down after setup.)"
    echo ""
    read -rsp "Cloudflare API token: " CF_TOKEN; echo ""
    [[ -z "$CF_TOKEN" ]] && { echo "ERROR: CF token required." >&2; exit 1; }
fi

echo ""
echo "==> Switching: mode $CURRENT ($(mode_label "$CURRENT")) → mode $TARGET ($(mode_label "$TARGET"))"
echo ""

# ── Execute transition ─────────────────────────────────────────────────────────

case "${CURRENT}→${TARGET}" in

    # ── 1 → 2 : add Trojan standalone ─────────────────────────────────────────
    "1→2")
        bash "$REPO_ROOT/scripts/setup-trojan.sh" "$DOMAIN" "$PASSWORD"
        echo ""
        echo "==> Applying iptables rules (port 443 open)..."
        TROJAN_ENABLED=true bash "$REPO_ROOT/vps/iptables/rules.sh"
        ;;

    # ── 1 → 3 : add Trojan + Cloudflare ───────────────────────────────────────
    "1→3")
        bash "$REPO_ROOT/scripts/setup-trojan-cloudflare.sh" \
            "$DOMAIN" "$PASSWORD" "$CF_TOKEN"
        echo ""
        echo "==> Applying iptables rules (port 443 open)..."
        TROJAN_ENABLED=true bash "$REPO_ROOT/vps/iptables/rules.sh"
        ;;

    # ── 2 → 3 : add WebSocket transport + Cloudflare renewal ──────────────────
    "2→3")
        echo "  NOTE: The existing TLS certificate is reused — no new cert needed."
        echo "  Ensure the Cloudflare orange cloud is ON for $DOMAIN before"
        echo "  switching, then turn on WebSocket in Cloudflare Network settings."
        echo ""
        read -rp "Press Enter when Cloudflare proxy is enabled for $DOMAIN... "
        echo ""
        update_renewal_dns01 "$DOMAIN" "$CF_TOKEN"
        echo "==> Rewriting trojan-go config (WebSocket enabled)..."
        write_config_cloudflare "$DOMAIN" "$PASSWORD"
        echo "==> Restarting trojan-go..."
        systemctl restart trojan-go
        ;;

    # ── 3 → 2 : remove WebSocket transport, switch to standalone renewal ───────
    "3→2")
        echo "  NOTE: The existing TLS certificate is reused — no new cert needed."
        echo "  Turn OFF the Cloudflare proxy (orange → grey cloud) for $DOMAIN"
        echo "  so future HTTP-01 renewals can reach this server directly."
        echo ""
        read -rp "Press Enter when Cloudflare proxy is disabled for $DOMAIN... "
        echo ""
        update_renewal_http01 "$DOMAIN"
        echo "==> Rewriting trojan-go config (WebSocket disabled)..."
        write_config_standalone "$DOMAIN" "$PASSWORD"
        echo "==> Restarting trojan-go..."
        systemctl restart trojan-go
        if [[ -f "$CF_CREDS" ]]; then
            echo ""
            echo "  Cloudflare credentials kept at $CF_CREDS."
            echo "  Remove when no longer needed:  rm $CF_CREDS"
        fi
        ;;

    # ── 2 → 1 : remove Trojan ──────────────────────────────────────────────────
    "2→1")
        teardown_trojan
        ;;

    # ── 3 → 1 : remove Trojan + Cloudflare ────────────────────────────────────
    "3→1")
        teardown_trojan
        if [[ -f "$CF_CREDS" ]]; then
            echo "  Cloudflare credentials kept at $CF_CREDS."
            echo "  Remove when no longer needed:  rm $CF_CREDS"
        fi
        ;;

esac

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Mode switch complete: $CURRENT → $TARGET"
echo ""
case "$TARGET" in
    1)
        echo "  Mode: WireGuard only"
        echo "  Trojan-go stopped. WireGuard peers remain active."
        echo ""
        echo "  To persist iptables across reboot:"
        echo "    netfilter-persistent save"
        ;;
    2)
        echo "  Mode: WireGuard + Trojan (standalone)"
        echo ""
        echo "  Client settings:"
        echo "    server:   $DOMAIN"
        echo "    port:     443"
        echo "    password: (as set)"
        echo "    ssl/tls:  enabled"
        echo ""
        echo "  To persist iptables across reboot:"
        echo "    netfilter-persistent save"
        ;;
    3)
        echo "  Mode: WireGuard + Trojan + Cloudflare CDN"
        echo ""
        echo "  Client settings (WebSocket mode):"
        echo "    server:    $DOMAIN"
        echo "    port:      443"
        echo "    password:  (as set)"
        echo "    websocket: enabled, path: /trojan"
        echo "    ssl/tls:   enabled"
        echo ""
        echo "  Cloudflare dashboard — confirm:"
        echo "    DNS:     $DOMAIN  Proxied (orange cloud ON)"
        echo "    SSL/TLS: Full or Full Strict"
        echo "    Network: WebSocket enabled"
        echo ""
        echo "  To persist iptables across reboot:"
        echo "    netfilter-persistent save"
        ;;
esac
echo "══════════════════════════════════════════════════════"
