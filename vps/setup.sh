#!/usr/bin/env bash
# VPS Bootstrap Script
# Run once on a fresh OVHcloud VPS (Ubuntu 22.04+ / Debian 12+)
#
# Usage:
#   sudo bash vps/setup.sh
#
# This script:
#   1. Updates the system
#   2. Installs WireGuard, Fail2Ban, iptables-persistent
#   3. Enables IP forwarding
#   4. Hardens SSH (key-only auth)
#   5. Enables WireGuard (expects /etc/wireguard/wg0.conf to already exist)
#
# Prerequisites:
#   - Fill out and place /etc/wireguard/wg0.conf before running
#   - Run vps/iptables/rules.sh separately (requires real IP values)

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash vps/setup.sh)" >&2
    exit 1
fi

echo "==> Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

echo "==> Installing required packages..."
apt-get install -y -qq wireguard fail2ban iptables-persistent curl

echo "==> Enabling IP forwarding..."
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf \
    || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf \
    || echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
sysctl -p

echo "==> Hardening SSH (disabling password auth)..."
# Write a drop-in rather than patching sshd_config directly.
# Ubuntu 22.04+ uses Include /etc/ssh/sshd_config.d/*.conf and the main file
# may not contain these keys at all. Drop-ins also survive OS upgrades.
# KbdInteractiveAuthentication replaces ChallengeResponseAuthentication in
# OpenSSH 8.7+ (Ubuntu 24.04 ships OpenSSH 9.6).
# UsePAM must stay yes on Ubuntu — PAM handles session setup and MOTD.
SSHD_DROP_IN="/etc/ssh/sshd_config.d/99-hardening.conf"
mkdir -p /etc/ssh/sshd_config.d
cat > "$SSHD_DROP_IN" <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
EOF
chmod 600 "$SSHD_DROP_IN"
# Ubuntu names the unit 'ssh'; fall back to 'sshd' for non-Ubuntu distros
systemctl reload ssh 2>/dev/null || systemctl reload sshd
echo "    SSH: password auth disabled. Ensure your public key is in ~/.ssh/authorized_keys!"

echo "==> Enabling Fail2Ban..."
systemctl enable fail2ban --now

echo "==> Checking for WireGuard config..."
if [[ ! -f /etc/wireguard/wg0.conf ]]; then
    echo ""
    echo "WARNING: /etc/wireguard/wg0.conf not found."
    echo "  1. Fill out vps/wireguard/wg0.conf.template with real keys"
    echo "  2. Place it at /etc/wireguard/wg0.conf"
    echo "  3. Run: systemctl enable wg-quick@wg0 --now"
    echo ""
else
    chmod 600 /etc/wireguard/wg0.conf
    systemctl enable wg-quick@wg0 --now
    echo "==> WireGuard started. Status:"
    wg show
fi

echo ""
echo "==> Next: apply iptables rules"
echo "    Run: sudo bash vps/iptables/rules.sh"
echo "    (DNAT rules for public peers are added automatically by scripts/add-peer.sh)"
echo ""
echo "==> Bootstrap complete."
