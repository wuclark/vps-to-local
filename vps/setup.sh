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
apt-get install -y -qq wireguard fail2ban iptables-persistent ufw-less curl

echo "==> Enabling IP forwarding..."
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf \
    || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf \
    || echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
sysctl -p

echo "==> Hardening SSH (disabling password auth)..."
SSHD_CFG="/etc/ssh/sshd_config"
# Only modify if not already set
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CFG"
sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CFG"
sed -i 's/^#*UsePAM.*/UsePAM no/' "$SSHD_CFG"
systemctl reload sshd
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
echo "    Edit vps/iptables/rules.sh (fill in PUBLIC_IP_1, PUBLIC_IP_2)"
echo "    Then run: sudo bash vps/iptables/rules.sh"
echo ""
echo "==> Bootstrap complete."
