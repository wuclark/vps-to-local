#!/usr/bin/env bash
# Generate a filled-in wg0.conf from a peer's wg0.conf.template
#
# Usage:
#   bash scripts/gen-peer-conf.sh <name> <private-key-file> <server-public-key> <vps-ip>
#
# Example:
#   bash scripts/gen-peer-conf.sh remote001 ~/wg-private.key AbCdEf...== 203.0.113.10
#
# Output:
#   peers/<name>/wg0.conf  (gitignored — safe to leave in the repo directory)
#
# The private key is read from a file (not a command-line argument) so it does
# not appear in your shell history or the process list.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: bash scripts/gen-peer-conf.sh <name> <private-key-file> <server-public-key> <vps-ip>" >&2
    echo ""                                                                                              >&2
    echo "  <name>              Peer name (e.g. remote001)"                                             >&2
    echo "  <private-key-file>  Path to the file containing the peer's WireGuard private key"          >&2
    echo "  <server-public-key> VPS WireGuard public key (from scripts/gen-keys.sh)"                   >&2
    echo "  <vps-ip>            VPS primary IP address"                                                 >&2
    exit 1
}

[[ $# -ne 4 ]] && usage

PEER_NAME="$1"
PRIV_KEY_FILE="$2"
SERVER_PUB_KEY="$3"
VPS_IP="$4"

TEMPLATE="$REPO_ROOT/peers/$PEER_NAME/wg0.conf.template"
OUTPUT="$REPO_ROOT/peers/$PEER_NAME/wg0.conf"

# ── Validate inputs ────────────────────────────────────────────────────────────
if [[ ! -f "$TEMPLATE" ]]; then
    echo "ERROR: $TEMPLATE not found. Run 'bash scripts/add-peer.sh $PEER_NAME' first." >&2
    exit 1
fi

if [[ ! -f "$PRIV_KEY_FILE" ]]; then
    echo "ERROR: private key file not found: $PRIV_KEY_FILE" >&2
    exit 1
fi

PRIV_KEY="$(cat "$PRIV_KEY_FILE")"
if [[ -z "$PRIV_KEY" ]]; then
    echo "ERROR: private key file is empty: $PRIV_KEY_FILE" >&2
    exit 1
fi

# ── Derive placeholder name from peer name (same logic as add-peer.sh) ─────────
PLACEHOLDER_UPPER="${PEER_NAME^^}"
PLACEHOLDER="${PLACEHOLDER_UPPER//-/_}"
PRIV_KEY_PH="${PLACEHOLDER}_PRIVATE_KEY"

# ── Substitute placeholders ────────────────────────────────────────────────────
sed \
    -e "s|<${PRIV_KEY_PH}>|${PRIV_KEY}|g" \
    -e "s|<SERVER_PUBLIC_KEY>|${SERVER_PUB_KEY}|g" \
    -e "s|<VPS_MAIN_IP>|${VPS_IP}|g" \
    "$TEMPLATE" > "$OUTPUT"

chmod 600 "$OUTPUT"

echo "Generated: peers/$PEER_NAME/wg0.conf"
echo ""
echo "Next: copy to the peer machine and import into WireGuard"
echo "  Linux:   sudo cp peers/$PEER_NAME/wg0.conf /etc/wireguard/wg0.conf"
echo "  GUI app: File → Import tunnel(s) from file (macOS / Windows)"
echo "  Mobile:  qrencode -t ansiutf8 < peers/$PEER_NAME/wg0.conf"
