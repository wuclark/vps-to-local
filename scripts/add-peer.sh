#!/usr/bin/env bash
# Add a new WireGuard peer to the repo templates
#
# Usage:
#   bash scripts/add-peer.sh <name>                        # VPN client only
#   bash scripts/add-peer.sh <name> --public-ip <PUBLIC_IP> # publicly reachable
#
# Modes:
#   Without --public-ip  The peer connects to the VPN (can reach 10.0.0.0/24)
#                        but has no dedicated public IP. Use this for phones,
#                        laptops, or any machine that just needs VPN access.
#
#   With --public-ip     All traffic arriving at PUBLIC_IP is DNAT'd to this
#                        peer. Use this for machines you want to expose publicly
#                        (servers, home desktops, etc.).
#
# What this script does (all changes are to repo templates only — nothing on live systems):
#   1. Assigns the next available WireGuard IP in 10.0.0.0/24
#   2. Creates peers/<name>/wg0.conf.template
#   3. Appends a [Peer] block to vps/wireguard/wg0.conf.template
#   4. If --public-ip given, inserts a DNAT rule into vps/iptables/rules.sh
#
# After running this script:
#   - Generate a keypair on the peer machine:
#       wg genkey | tee /etc/wireguard/private.key | wg pubkey
#   - Fill placeholders in peers/<name>/wg0.conf.template
#   - Fill <NAME_PUBLIC_KEY> in vps/wireguard/wg0.conf.template
#   - On VPS: wg syncconf wg0 <(wg-quick strip wg0)   (no downtime reload)
#   - If --public-ip was used: re-run vps/iptables/rules.sh on VPS

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPS_WG_CONF="$REPO_ROOT/vps/wireguard/wg0.conf.template"
VPS_IPT_RULES="$REPO_ROOT/vps/iptables/rules.sh"
PEERS_DIR="$REPO_ROOT/peers"

# ── Argument parsing ───────────────────────────────────────────────────────────
usage() {
    echo "Usage: bash scripts/add-peer.sh <name> [--public-ip <IP>]" >&2
    exit 1
}

[[ $# -lt 1 ]] && usage

PEER_NAME="$1"; shift
PUBLIC_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --public-ip)
            [[ $# -lt 2 ]] && { echo "ERROR: --public-ip requires an IP address." >&2; exit 1; }
            PUBLIC_IP="$2"; shift 2 ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage ;;
    esac
done

# Validate name: lowercase letters, digits, hyphens only
if [[ ! "$PEER_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "ERROR: name must be lowercase letters, digits, and hyphens (e.g. 'remote001')." >&2
    exit 1
fi

# ── Check peer doesn't already exist ──────────────────────────────────────────
PEER_DIR="$PEERS_DIR/$PEER_NAME"
if [[ -d "$PEER_DIR" ]]; then
    echo "ERROR: peers/$PEER_NAME already exists. Remove it first if you want to recreate." >&2
    exit 1
fi

# ── Auto-assign next WireGuard IP ─────────────────────────────────────────────
# Scan existing AllowedIPs = 10.0.0.X/32 lines in server template; pick max X + 1
# Reserve .1 for VPS; peers start at .2
MAX_OCTET=1
while IFS= read -r line; do
    if [[ "$line" =~ AllowedIPs[[:space:]]*=[[:space:]]*10\.0\.0\.([0-9]+)/32 ]]; then
        octet="${BASH_REMATCH[1]}"
        (( octet > MAX_OCTET )) && MAX_OCTET="$octet"
    fi
done < "$VPS_WG_CONF"

NEXT_OCTET=$(( MAX_OCTET + 1 ))

if (( NEXT_OCTET > 254 )); then
    echo "ERROR: WireGuard subnet 10.0.0.0/24 is full (no IPs left)." >&2
    exit 1
fi

WG_IP="10.0.0.$NEXT_OCTET"
PLACEHOLDER_UPPER="${PEER_NAME^^}"
PLACEHOLDER="${PLACEHOLDER_UPPER//-/_}"
PRIV_KEY_PH="<${PLACEHOLDER}_PRIVATE_KEY>"
PUB_KEY_PH="<${PLACEHOLDER}_PUBLIC_KEY>"

if [[ -n "$PUBLIC_IP" ]]; then
    MODE="public  (DNAT: $PUBLIC_IP → $WG_IP)"
    # Route all traffic through the tunnel so the peer is reachable on its public IP
    CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
    PUBLIC_IP_NOTE="$PUBLIC_IP"
else
    MODE="vpn-only (no public IP)"
    # Only route the WireGuard subnet — internet traffic stays local on the peer
    CLIENT_ALLOWED_IPS="10.0.0.0/24"
    PUBLIC_IP_NOTE="none (VPN client only)"
fi

echo "Name:           $PEER_NAME"
echo "WireGuard IP:   $WG_IP"
echo "Mode:           $MODE"
echo ""

# ── 1. Create peer client config template ─────────────────────────────────────
mkdir -p "$PEER_DIR"
cat > "$PEER_DIR/wg0.conf.template" <<EOF
# WireGuard Client Config — $PEER_NAME
# Place at: /etc/wireguard/wg0.conf  (Linux)
#           or import into WireGuard app (macOS/Windows/iOS/Android)
# Permissions: chmod 600 /etc/wireguard/wg0.conf
#
# Start:   wg-quick up wg0
# Stop:    wg-quick down wg0
# Status:  wg show
#
# Mode: $MODE

[Interface]
Address = $WG_IP/24
PrivateKey = $PRIV_KEY_PH
# Optional: DNS = 1.1.1.1

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
Endpoint = <VPS_MAIN_IP>:51820
AllowedIPs = $CLIENT_ALLOWED_IPS
PersistentKeepalive = 25
EOF

echo "Created: peers/$PEER_NAME/wg0.conf.template"

# ── 2. Append [Peer] block to VPS server config template ──────────────────────
cat >> "$VPS_WG_CONF" <<EOF

# ─────────────────────────────────────────────
# Peer: $PEER_NAME  [$MODE]
# WireGuard IP: $WG_IP
# Public IP: $PUBLIC_IP_NOTE
# ─────────────────────────────────────────────
[Peer]
PublicKey = $PUB_KEY_PH
AllowedIPs = $WG_IP/32
EOF

echo "Updated: vps/wireguard/wg0.conf.template"

# ── 3. Insert DNAT rule into iptables rules (if public IP given) ───────────────
if [[ -n "$PUBLIC_IP" ]]; then
    DNAT_LINE="ipt -t nat -A PREROUTING -d \"$PUBLIC_IP\" -j DNAT --to-destination \"$WG_IP\""
    COMMENT="# $PUBLIC_IP → $PEER_NAME ($WG_IP)"

    LAST_DNAT_LINE=$(grep -n 'DNAT --to-destination' "$VPS_IPT_RULES" | tail -1 | cut -d: -f1)

    if [[ -n "$LAST_DNAT_LINE" ]]; then
        sed -i "${LAST_DNAT_LINE}a ${COMMENT}\\n${DNAT_LINE}" "$VPS_IPT_RULES"
    else
        # No existing DNAT rules — insert before the section 10 comment
        sed -i "/^# ── 10\./i ${COMMENT}\\n${DNAT_LINE}" "$VPS_IPT_RULES"
    fi

    echo "Updated: vps/iptables/rules.sh  (added DNAT for $PUBLIC_IP → $WG_IP)"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Peer '$PEER_NAME' added ($MODE)."
echo ""
echo "Next steps:"
echo ""
echo "  1. On the peer machine, generate a keypair:"
echo "     wg genkey | tee /etc/wireguard/private.key | wg pubkey"
echo ""
echo "  2. Fill in peers/$PEER_NAME/wg0.conf.template:"
echo "     $PRIV_KEY_PH  ← private key from step 1"
echo "     <SERVER_PUBLIC_KEY>       ← from bash scripts/gen-keys.sh on VPS"
echo "     <VPS_MAIN_IP>             ← VPS primary IP address"
echo ""
echo "  3. Fill in vps/wireguard/wg0.conf.template:"
echo "     $PUB_KEY_PH   ← public key from step 1"
echo ""
echo "  On VPS — live reload WireGuard (no downtime):"
echo "     wg syncconf wg0 <(wg-quick strip wg0)"
if [[ -n "$PUBLIC_IP" ]]; then
echo ""
echo "  On VPS — re-apply iptables to activate DNAT rule:"
echo "     sudo bash vps/iptables/rules.sh"
fi
echo "========================================"
