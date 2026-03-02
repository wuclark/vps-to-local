#!/usr/bin/env bash
# iptables rules for VPS WireGuard relay
#
# Usage:
#   sudo bash rules.sh              # Apply rules
#   sudo bash rules.sh --dry-run    # Print rules without applying
#
# After applying, persist with:
#   apt install iptables-persistent
#   netfilter-persistent save

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
WG_INTERFACE="wg0"
WG_PORT="51820"
SSH_PORT="22"
WG_SUBNET="10.0.0.0/24"
REMOTE001_WG_IP="10.0.0.2"

# Fill these in before running:
PUBLIC_IP_1="<PUBLIC_IP_1>"   # Additional IP routed to remote001

# ── Dry-run support ────────────────────────────────────────────────────────────
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    ipt() { echo "iptables $*"; }
    echo "=== DRY RUN — rules will not be applied ==="
else
    ipt() { iptables "$@"; }
fi

# ── Validate placeholders ──────────────────────────────────────────────────────
if [[ "$PUBLIC_IP_1" == "<PUBLIC_IP_1>" ]]; then
    echo "ERROR: Fill in PUBLIC_IP_1 before running this script." >&2
    exit 1
fi

echo "Applying iptables rules..."

# ── 1. Flush existing rules ────────────────────────────────────────────────────
ipt -F
ipt -X
ipt -t nat -F
ipt -t nat -X
ipt -t mangle -F
ipt -t mangle -X

# ── 2. Default policies ────────────────────────────────────────────────────────
ipt -P INPUT   DROP
ipt -P FORWARD DROP
ipt -P OUTPUT  ACCEPT

# ── 3. Loopback and established connections ────────────────────────────────────
ipt -A INPUT -i lo -j ACCEPT
ipt -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# ── 4. Drop invalid packets ────────────────────────────────────────────────────
ipt -A INPUT -m state --state INVALID -j DROP

# ── 5. SYN flood rate limiting ─────────────────────────────────────────────────
ipt -A INPUT -p tcp --syn -m limit --limit 25/s --limit-burst 50 -j ACCEPT
ipt -A INPUT -p tcp --syn -j DROP

# ── 6. Allow SSH ───────────────────────────────────────────────────────────────
ipt -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT

# ── 7. Allow WireGuard UDP ────────────────────────────────────────────────────
ipt -A INPUT -p udp --dport "$WG_PORT" -j ACCEPT

# ── 8. Allow ICMP (ping) ──────────────────────────────────────────────────────
ipt -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# ── 9. NAT: DNAT public IPs to WireGuard peer IPs ─────────────────────────────
# Public IP #1 → remote001 (10.0.0.2)
ipt -t nat -A PREROUTING -d "$PUBLIC_IP_1" -j DNAT --to-destination "$REMOTE001_WG_IP"
# Add more peers with: bash scripts/add-peer.sh remote002 --public-ip <IP>

# ── 10. Masquerade outbound WireGuard traffic ──────────────────────────────────
ipt -t nat -A POSTROUTING -o "$WG_INTERFACE" -j MASQUERADE

# ── 11. FORWARD: only permit traffic to/from WireGuard subnet ─────────────────
ipt -A FORWARD -i "$WG_INTERFACE" -o "$WG_INTERFACE" -j ACCEPT
ipt -A FORWARD -d "$WG_SUBNET" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
ipt -A FORWARD -s "$WG_SUBNET" -m state --state ESTABLISHED,RELATED -j ACCEPT
ipt -A FORWARD -j DROP

echo "Done. Rules applied."
echo ""
echo "To persist across reboots:"
echo "  apt install iptables-persistent"
echo "  netfilter-persistent save"
