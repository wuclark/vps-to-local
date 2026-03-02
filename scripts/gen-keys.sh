#!/usr/bin/env bash
# Generate WireGuard keypairs for the initial nodes (VPS + remote001)
#
# Output is printed to stdout only — nothing is written to disk.
# Copy private keys directly to /etc/wireguard/ on each respective machine.
# Public keys go into the peer's [Peer] block.
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

gen_pair() {
    local name="$1"
    local priv pub
    priv=$(wg genkey)
    pub=$(echo "$priv" | wg pubkey)
    echo "## $name"
    echo "Private key (keep secret, goes in [Interface] PrivateKey): $priv"
    echo "Public key  (share freely, goes in peer's [Peer] PublicKey): $pub"
    echo ""
}

echo "========================================"
echo " WireGuard Keypair Generator"
echo " Generated: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "========================================"
echo ""
echo "IMPORTANT: Store private keys securely."
echo "Never commit private keys to git."
echo ""

gen_pair "VPS (server)"
gen_pair "remote001 (peer)"

echo "========================================"
echo "Next steps:"
echo "  1. Place each private key at /etc/wireguard/ on the respective machine"
echo "  2. chmod 600 /etc/wireguard/wg0.conf on each machine"
echo "  3. Fill public keys into the template files:"
echo "     vps/wireguard/wg0.conf.template    ← remote001 public key"
echo "     peers/remote001/wg0.conf.template  ← server public key"
echo ""
echo "  To add more peers later:"
echo "     bash scripts/add-peer.sh remote002 --public-ip <IP>"
echo "========================================"
