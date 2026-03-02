#!/usr/bin/env bash
# Add a new WireGuard peer to the repo templates
#
# Usage:
#   bash scripts/add-peer.sh <hostname>
#   bash scripts/add-peer.sh <hostname> --public-ip <PUBLIC_IP>
#
# Arguments:
#   hostname      Name for the new peer (e.g. "server", "phone", "raspberry-pi")
#   --public-ip   Optional dedicated OVHcloud IP to forward to this peer
#
# What this script does (all changes are to repo templates only — nothing on live systems):
#   1. Assigns the next available WireGuard IP in 10.0.0.0/24
#   2. Creates peers/<hostname>/wg0.conf.template
#   3. Appends a [Peer] block to vps/wireguard/wg0.conf.template
#   4. If --public-ip given, appends a DNAT stub to vps/iptables/rules.sh
#
# After running this script:
#   - Generate a keypair on the new machine: bash scripts/gen-keys.sh
#   - Fill <HOSTNAME_PRIVATE_KEY> and <SERVER_PUBLIC_KEY> into peers/<hostname>/wg0.conf.template
#   - Fill <HOSTNAME_PUBLIC_KEY> into vps/wireguard/wg0.conf.template
#   - On VPS: wg syncconf wg0 <(wg-quick strip wg0)   (no downtime reload)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPS_WG_CONF="$REPO_ROOT/vps/wireguard/wg0.conf.template"
VPS_IPT_RULES="$REPO_ROOT/vps/iptables/rules.sh"
PEERS_DIR="$REPO_ROOT/peers"

# ── Argument parsing ───────────────────────────────────────────────────────────
usage() {
    echo "Usage: bash scripts/add-peer.sh <hostname> [--public-ip <IP>]" >&2
    exit 1
}

[[ $# -lt 1 ]] && usage

HOSTNAME="$1"; shift
PUBLIC_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --public-ip)
            [[ $# -lt 2 ]] && { echo "ERROR: --public-ip requires an IP address." >&2; exit 1; }
            PUBLIC_IP="$2"; shift 2 ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage ;;
    esac
done

# Validate hostname: lowercase letters, digits, hyphens only
if [[ ! "$HOSTNAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "ERROR: hostname must be lowercase letters, digits, and hyphens (e.g. 'raspberry-pi')." >&2
    exit 1
fi

# ── Check peer doesn't already exist ──────────────────────────────────────────
PEER_DIR="$PEERS_DIR/$HOSTNAME"
if [[ -d "$PEER_DIR" ]]; then
    echo "ERROR: peers/$HOSTNAME already exists. Remove it first if you want to recreate." >&2
    exit 1
fi

# ── Auto-assign next WireGuard IP ─────────────────────────────────────────────
# Find all AllowedIPs = 10.0.0.X/32 lines in the server template; pick max X + 1
# Reserve .1 for VPS; start peers at .2
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
PLACEHOLDER_UPPER="${HOSTNAME^^}"           # e.g. raspberry-pi → RASPBERRY-PI
PLACEHOLDER="${PLACEHOLDER_UPPER//-/_}"    # → RASPBERRY_PI
PRIV_KEY_PH="<${PLACEHOLDER}_PRIVATE_KEY>"
PUB_KEY_PH="<${PLACEHOLDER}_PUBLIC_KEY>"

echo "Hostname:       $HOSTNAME"
echo "WireGuard IP:   $WG_IP"
[[ -n "$PUBLIC_IP" ]] && echo "Public IP:      $PUBLIC_IP"
echo ""

# ── 1. Create peer client config template ─────────────────────────────────────
mkdir -p "$PEER_DIR"
cat > "$PEER_DIR/wg0.conf.template" <<EOF
# WireGuard Client Config — $HOSTNAME
# Place at: /etc/wireguard/wg0.conf  (Linux)
#           or import into WireGuard app (macOS/Windows/iOS/Android)
# Permissions: chmod 600 /etc/wireguard/wg0.conf
#
# Start:   wg-quick up wg0
# Stop:    wg-quick down wg0
# Status:  wg show

[Interface]
Address = $WG_IP/24
PrivateKey = $PRIV_KEY_PH
# Optional: DNS = 1.1.1.1

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
Endpoint = <VPS_MAIN_IP>:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

echo "Created: peers/$HOSTNAME/wg0.conf.template"

# ── 2. Append [Peer] block to VPS server config template ──────────────────────
PUBLIC_IP_NOTE="${PUBLIC_IP:-none (shared VPS IP)}"
cat >> "$VPS_WG_CONF" <<EOF

# ─────────────────────────────────────────────
# Peer: $HOSTNAME
# WireGuard IP: $WG_IP
# Mapped to public: $PUBLIC_IP_NOTE
# ─────────────────────────────────────────────
[Peer]
PublicKey = $PUB_KEY_PH
AllowedIPs = $WG_IP/32
EOF

echo "Updated: vps/wireguard/wg0.conf.template"

# ── 3. Append DNAT stub to iptables rules (if public IP given) ─────────────────
if [[ -n "$PUBLIC_IP" ]]; then
    # Insert after the last DNAT line
    DNAT_LINE="ipt -t nat -A PREROUTING -d \"$PUBLIC_IP\" -j DNAT --to-destination \"$WG_IP\""
    COMMENT="# Public IP ($PUBLIC_IP) → $HOSTNAME ($WG_IP)"

    # Find line number of last DNAT block so we can insert after it
    LAST_DNAT_LINE=$(grep -n 'DNAT --to-destination' "$VPS_IPT_RULES" | tail -1 | cut -d: -f1)

    if [[ -n "$LAST_DNAT_LINE" ]]; then
        # Insert the two new lines after the last DNAT line
        sed -i "${LAST_DNAT_LINE}a ${COMMENT}\\n${DNAT_LINE}" "$VPS_IPT_RULES"
    else
        # Fallback: append before the MASQUERADE line
        sed -i "/MASQUERADE/i ${COMMENT}\\n${DNAT_LINE}" "$VPS_IPT_RULES"
    fi

    echo "Updated: vps/iptables/rules.sh  (added DNAT for $PUBLIC_IP → $WG_IP)"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Peer '$HOSTNAME' added. Next steps:"
echo ""
echo "  1. Generate a keypair on $HOSTNAME:"
echo "     bash scripts/gen-keys.sh"
echo "     (use the '$HOSTNAME' keypair output)"
echo ""
echo "  2. Fill private key into:"
echo "     peers/$HOSTNAME/wg0.conf.template"
echo "     Replace: $PRIV_KEY_PH"
echo ""
echo "  3. Fill server public key into the same file:"
echo "     Replace: <SERVER_PUBLIC_KEY>"
echo ""
echo "  4. Fill $HOSTNAME public key into VPS template:"
echo "     vps/wireguard/wg0.conf.template"
echo "     Replace: $PUB_KEY_PH"
echo ""
if [[ -n "$PUBLIC_IP" ]]; then
echo "  5. Verify DNAT rule in vps/iptables/rules.sh for $PUBLIC_IP"
echo ""
fi
echo "  On VPS after deploying — live reload (no downtime):"
echo "     wg syncconf wg0 <(wg-quick strip wg0)"
echo "========================================"
