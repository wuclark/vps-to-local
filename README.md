# VPS-to-Local Tunnel

Expose home machines to the internet with dedicated public IPs using an OVHcloud
VPS as a WireGuard relay. The VPS forwards all traffic — it never terminates
connections itself. Peers are named `remoteXXX` for consistency.

## Quick Start

```
1. Order VPS + Additional IPs on OVHcloud (US/EU datacenter)
2. bash scripts/gen-keys.sh        # generate keypairs
3. Fill in templates under vps/ and peers/
4. sudo bash vps/setup.sh          # bootstrap VPS
5. sudo bash vps/iptables/rules.sh # apply forwarding rules
6. Configure WireGuard on each remote peer (see peers/)
```

## Architecture

```
Internet
    │
    ▼
OVHcloud VPS  ($9.99/mo + $2/mo per extra IP)
├── Public IP #1  ──► WireGuard ──► remote001  (10.0.0.2)
└── Public IP #2  ──► WireGuard ──► remote002  (10.0.0.3)
```

## Adding More Peers

```bash
bash scripts/add-peer.sh remote003
bash scripts/add-peer.sh remote003 --public-ip <PUBLIC_IP_3>
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
  wireguard/wg0.conf.template   WireGuard server config (VPS)
  iptables/rules.sh             iptables forwarding + hardening
  setup.sh                      Full VPS bootstrap
peers/
  remote001/wg0.conf.template   WireGuard client (remote001, 10.0.0.2)
  remote002/wg0.conf.template   WireGuard client (remote002, 10.0.0.3)
scripts/
  gen-keys.sh                   Generate WireGuard keypairs
  add-peer.sh                   Add a new remoteXXX peer
```

See [CLAUDE.md](CLAUDE.md) for AI assistant conventions and development workflow.
