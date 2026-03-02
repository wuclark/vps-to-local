#!/usr/bin/env bash
# Generate a WireGuard keypair for the VPS server
#
# Output is printed to stdout only — nothing is written to disk.
# Place the private key at /etc/wireguard/ on the VPS.
# The public key goes into each peer's [Peer] block.
#
# For peer keypairs, run this on each peer machine directly:
#   wg genkey | tee /etc/wireguard/private.key | wg pubkey
#
# Usage:
#   bash scripts/gen-keys.sh
#
# Requirements:
#   wireguard-tools (provides wg command)

set -euo pipefail

if ! command -v wg &>/dev/null; then
    echo "ERROR: 'wg' not found. Install wireguard-tools first." >&2
    echo "  Ubuntu/Debian: apt install wireguard-tools" >&2
    echo "  macOS:         brew install wireguard-tools" >&2
    exit 1
fi

priv=$(wg genkey)
pub=$(echo "$priv" | wg pubkey)

echo "========================================"
echo " WireGuard Server Keypair"
echo " Generated: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "========================================"
echo ""
echo "Private key (keep secret — place at /etc/wireguard/private.key on VPS):"
echo "  $priv"
echo ""
echo "Public key (goes in each peer's [Peer] PublicKey field):"
echo "  $pub"
echo ""
echo "========================================"
echo "Next steps:"
echo "  1. Fill <SERVER_PRIVATE_KEY> in vps/wireguard/wg0.conf.template"
echo "  2. chmod 600 /etc/wireguard/wg0.conf on VPS"
echo "  3. Add peers:"
echo "     bash scripts/add-peer.sh remote001 --public-ip <IP>  # publicly reachable"
echo "     bash scripts/add-peer.sh remote001                   # VPN client only"
echo "========================================"
