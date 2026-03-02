#!/usr/bin/env bash
# VPS Setup — Interactive Mode Selector
#
# Usage:
#   sudo bash scripts/setup.sh
#
# Presents a menu to choose the proxy/tunnel mode, then runs the
# appropriate setup script(s). WireGuard is always installed first.
#
# Modes:
#   1) WireGuard only      — fastest; ideal when UDP 51820 is reachable
#   2) WireGuard + Trojan  — adds HTTPS proxy on port 443 (direct TLS)
#   3) WireGuard + Trojan  — adds HTTPS proxy behind Cloudflare CDN (WebSocket)
#      + Cloudflare

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Preflight ──────────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash scripts/setup.sh)" >&2
    exit 1
fi

echo ""
echo "┌─────────────────────────────────────────────────┐"
echo "│         VPS-to-Local — Setup Wizard             │"
echo "└─────────────────────────────────────────────────┘"
echo ""
echo "Choose a proxy mode:"
echo ""
echo "  1) WireGuard only"
echo "       Fast encrypted UDP tunnel. Best when port 51820 is reachable."
echo "       No domain required."
echo ""
echo "  2) WireGuard + Trojan (standalone)"
echo "       Adds a TLS proxy on port 443. Works through firewalls that"
echo "       block UDP. Requires a domain A record pointing to this VPS."
echo ""
echo "  3) WireGuard + Trojan + Cloudflare CDN"
echo "       Same as #2 but hides the VPS IP behind Cloudflare. Traffic"
echo "       travels as WebSocket through Cloudflare's proxy. Requires a"
echo "       domain on Cloudflare and an API token."
echo ""

while true; do
    read -rp "Enter choice [1/2/3]: " CHOICE
    case "$CHOICE" in
        1|2|3) break ;;
        *) echo "  Please enter 1, 2, or 3." ;;
    esac
done

echo ""

# ── Mode 2 + 3: collect Trojan args before starting anything ──────────────────
if [[ "$CHOICE" == "2" || "$CHOICE" == "3" ]]; then
    read -rp "Domain (e.g. proxy.example.com): " TROJAN_DOMAIN
    if [[ -z "$TROJAN_DOMAIN" ]]; then
        echo "ERROR: domain is required for Trojan modes." >&2
        exit 1
    fi

    read -rsp "Trojan password: " TROJAN_PASSWORD
    echo ""
    if [[ -z "$TROJAN_PASSWORD" ]]; then
        echo "ERROR: password cannot be empty." >&2
        exit 1
    fi

    if [[ "$CHOICE" == "3" ]]; then
        echo ""
        echo "Cloudflare API token — needs Zone:DNS:Edit permission only."
        echo "(Used for the Let's Encrypt DNS-01 challenge. Not stored in"
        echo " trojan-go config. Revoke or scope it down after setup.)"
        echo ""
        read -rsp "Cloudflare API token: " CF_TOKEN
        echo ""
        if [[ -z "$CF_TOKEN" ]]; then
            echo "ERROR: Cloudflare API token cannot be empty." >&2
            exit 1
        fi
    fi
fi

echo ""
echo "==> Starting WireGuard bootstrap..."
bash "$REPO_ROOT/vps/setup.sh"

# ── Trojan addon ───────────────────────────────────────────────────────────────
if [[ "$CHOICE" == "2" ]]; then
    echo ""
    echo "==> Starting Trojan (standalone) setup..."
    bash "$REPO_ROOT/scripts/setup-trojan.sh" "$TROJAN_DOMAIN" "$TROJAN_PASSWORD"

    echo ""
    echo "==> Applying iptables rules with Trojan port enabled..."
    TROJAN_ENABLED=true bash "$REPO_ROOT/vps/iptables/rules.sh"

elif [[ "$CHOICE" == "3" ]]; then
    echo ""
    echo "==> Starting Trojan + Cloudflare setup..."
    bash "$REPO_ROOT/scripts/setup-trojan-cloudflare.sh" \
        "$TROJAN_DOMAIN" "$TROJAN_PASSWORD" "$CF_TOKEN"

    echo ""
    echo "==> Applying iptables rules with Trojan port enabled..."
    TROJAN_ENABLED=true bash "$REPO_ROOT/vps/iptables/rules.sh"

else
    echo ""
    echo "==> Applying iptables rules (WireGuard only)..."
    bash "$REPO_ROOT/vps/iptables/rules.sh"
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Setup complete."
echo ""
case "$CHOICE" in
    1)
        echo "  Mode: WireGuard only"
        echo ""
        echo "  Next steps:"
        echo "    bash scripts/add-peer.sh remote001 [--public-ip <IP>]"
        echo "    (fill placeholders in peers/remote001/wg0.conf.template)"
        ;;
    2)
        echo "  Mode: WireGuard + Trojan (standalone)"
        echo ""
        echo "  WireGuard — add peers as normal:"
        echo "    bash scripts/add-peer.sh remote001 [--public-ip <IP>]"
        echo ""
        echo "  Trojan client settings:"
        echo "    server:   $TROJAN_DOMAIN"
        echo "    port:     443"
        echo "    password: (as provided)"
        echo "    ssl:      enabled"
        ;;
    3)
        echo "  Mode: WireGuard + Trojan + Cloudflare CDN"
        echo ""
        echo "  WireGuard — add peers as normal:"
        echo "    bash scripts/add-peer.sh remote001 [--public-ip <IP>]"
        echo ""
        echo "  Trojan client settings (WebSocket mode):"
        echo "    server:    $TROJAN_DOMAIN"
        echo "    port:      443"
        echo "    password:  (as provided)"
        echo "    websocket: enabled, path: /trojan"
        echo "    ssl:       enabled"
        echo ""
        echo "  Confirm in Cloudflare dashboard:"
        echo "    DNS:     $TROJAN_DOMAIN  Proxied (orange cloud ON)"
        echo "    SSL/TLS: Full or Full Strict"
        echo "    Network: WebSocket enabled"
        ;;
esac
echo "══════════════════════════════════════════════════════"
