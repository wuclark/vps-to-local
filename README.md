# VPS-to-Local Tunnel

Expose home machines to the internet with dedicated public IPs using an OVHcloud
VPS as a WireGuard relay. The VPS forwards all traffic — it never terminates
connections itself. Peers are named `remoteXXX` and added on demand.

## Quick Start

```
1. Order VPS on OVHcloud (US/EU datacenter)
2. bash scripts/gen-keys.sh        # generate VPS server keypair
3. Fill <SERVER_PRIVATE_KEY> into vps/wireguard/wg0.conf.template
4. sudo bash vps/setup.sh          # bootstrap VPS
5. bash scripts/add-peer.sh <name> [--public-ip <IP>]  # add peers
6. sudo bash vps/iptables/rules.sh # apply forwarding rules
```

## Architecture

```
Internet
    │
    ▼
OVHcloud VPS
├── VPS main IP  ──► SSH + WireGuard endpoint  (always on VPS, included free)
├── Public IP    ──► DNAT ──► remoteXXX  (public peer, ~$2/mo each)
└── (no extra IP)──► WireGuard only ──► remoteYYY  (VPN client, free)
```

**The VPS main IP is never DNAT'd** — SSH and WireGuard handshakes always reach
the VPS directly regardless of how many peers are configured.

## Peer Modes

| Mode | Command | Cost | Use case |
|------|---------|------|----------|
| **public** | `add-peer.sh <name> --public-ip <IP>` | +~$2/mo | home server, desktop |
| **vpn-only** | `add-peer.sh <name>` | free | phone, laptop, VPN access |

Public peers get all traffic DNAT'd from a dedicated IP (`AllowedIPs = 0.0.0.0/0`).
VPN-only peers can only reach the WireGuard subnet (`AllowedIPs = 10.0.0.0/24`).

## Adding Peers

```bash
# Publicly reachable (order an Additional IP from OVHcloud first)
bash scripts/add-peer.sh remote001 --public-ip <PUBLIC_IP>

# VPN client only (no extra IP needed)
bash scripts/add-peer.sh remote002
```

## Security Layers

| Layer | What | Where |
|-------|------|-------|
| 1 | OVHcloud Network Firewall | OVHcloud control panel (free, pre-VPS) |
| 2 | iptables DNAT + default-deny FORWARD | VPS |
| 3 | WireGuard encrypted tunnels | VPS ↔ remote peers |
| 4 | Fail2Ban brute-force protection | VPS |
| 5 | CrowdSec community threat intel | VPS (optional) |

## Repository Layout

```
vps/
  wireguard/wg0.conf.template   WireGuard server config (no peers pre-configured)
  iptables/rules.sh             iptables forwarding + hardening
  setup.sh                      Full VPS bootstrap
peers/
  <name>/wg0.conf.template      Created by add-peer.sh (none committed by default)
scripts/
  gen-keys.sh                   Generate VPS server keypair
  add-peer.sh                   Add a vpn-only or public peer
```

See [CLAUDE.md](CLAUDE.md) for AI assistant conventions and development workflow.
