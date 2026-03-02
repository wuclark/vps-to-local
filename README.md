# VPS-to-Local Tunnel

Expose home machines (laptop, desktop) to the internet with dedicated public IPs
using an OVHcloud VPS as a WireGuard relay. The VPS forwards all traffic — it
never terminates connections itself.

## Quick Start

```
1. Order VPS + 2 Additional IPs on OVHcloud (US/EU datacenter)
2. bash scripts/gen-keys.sh        # generate keypairs
3. Fill in templates under vps/ and peers/
4. sudo bash vps/setup.sh          # bootstrap VPS
5. sudo bash vps/iptables/rules.sh # apply forwarding rules
6. Configure WireGuard on laptop and desktop (see peers/)
```

## Architecture

```
Internet
    │
    ▼
OVHcloud VPS  ($9.99/mo + $2/mo per extra IP)
├── Public IP #1  ──► WireGuard ──► Laptop  (10.0.0.2)
└── Public IP #2  ──► WireGuard ──► Desktop (10.0.0.3)
```

## Security Layers

| Layer | What | Where |
|-------|------|-------|
| 1 | OVHcloud Network Firewall | OVHcloud control panel (free, pre-VPS) |
| 2 | iptables DNAT + default-deny FORWARD | VPS |
| 3 | WireGuard encrypted tunnels | VPS ↔ home machines |
| 4 | Fail2Ban brute-force protection | VPS |
| 5 | CrowdSec community threat intel | VPS (optional) |

## Repository Layout

```
vps/
  wireguard/wg0.conf.template   WireGuard server config (VPS)
  iptables/rules.sh             iptables forwarding + hardening
  setup.sh                      Full VPS bootstrap
peers/
  laptop/wg0.conf.template      WireGuard client (laptop)
  desktop/wg0.conf.template     WireGuard client (desktop)
scripts/
  gen-keys.sh                   Generate WireGuard keypairs
```

See [CLAUDE.md](CLAUDE.md) for AI assistant conventions and development workflow.
