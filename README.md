# VPS-to-Local Tunnel

Expose home machines to the internet with dedicated public IPs using an OVHcloud
VPS as a WireGuard relay. The VPS forwards all traffic — it never terminates
connections itself. Peers are named `remoteXXX` for consistency.

## Quick Start

```
1. Order VPS + 1 Additional IP on OVHcloud (US/EU datacenter)
2. bash scripts/gen-keys.sh        # generate keypairs (VPS + remote001)
3. Fill in templates under vps/ and peers/
4. sudo bash vps/setup.sh          # bootstrap VPS
5. sudo bash vps/iptables/rules.sh # apply forwarding rules
6. Configure WireGuard on remote001 (see peers/remote001/)
```

## Architecture

```
Internet
    │
    ▼
OVHcloud VPS  (~$12/mo to start)
├── VPS main IP  ──► SSH + WireGuard endpoint  (stays on VPS, included free)
└── Public IP #1 ──► DNAT ──► remote001  (10.0.0.2)
```

**Baseline: 2 IPs for 1 remote.** Add more peers with `scripts/add-peer.sh` —
each needs one additional IP (~$2/mo) if it requires its own public address.
The VPS main IP is never DNAT'd, so SSH and WireGuard handshakes always reach
the VPS directly.

## Adding More Peers

```bash
bash scripts/add-peer.sh remote002 --public-ip <PUBLIC_IP_2>
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
scripts/
  gen-keys.sh                   Generate WireGuard keypairs (VPS + remote001)
  add-peer.sh                   Add a new remoteXXX peer
```

See [CLAUDE.md](CLAUDE.md) for AI assistant conventions and development workflow.
