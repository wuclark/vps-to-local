# VPS-to-Local Tunnel

Expose home machines to the internet with dedicated public IPs using an OVHcloud
VPS as a WireGuard relay. The VPS forwards all traffic — it never terminates
connections itself. Peers are named `remoteXXX` and added on demand.

## Quick Start

```
1. Order VPS on OVHcloud (US/EU datacenter)
2. bash scripts/gen-keys.sh        # generate VPS server keypair
3. Fill <SERVER_PRIVATE_KEY> into vps/wireguard/wg0.conf.template
4. sudo bash scripts/setup.sh      # interactive wizard — picks WireGuard,
                                   # Trojan, or Trojan+Cloudflare
5. bash scripts/add-peer.sh <name> [--public-ip <IP>]  # add peers
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

## Proxy Options

In addition to WireGuard, this repo supports **Trojan** as a second proxy option.
Trojan disguises traffic as normal HTTPS, which works through firewalls that block UDP or WireGuard.

Run `sudo bash scripts/setup.sh` and choose from the menu, or run individual
scripts directly:

| Option | Command | Use case |
|--------|---------|----------|
| **WireGuard only** | `sudo bash scripts/setup.sh` → pick 1 | Standard — fastest, lowest overhead |
| **Trojan (standalone)** | `sudo bash scripts/setup.sh` → pick 2 | When WireGuard UDP is blocked; domain points directly to VPS |
| **Trojan + Cloudflare** | `sudo bash scripts/setup.sh` → pick 3 | Hides VPS IP behind Cloudflare CDN; uses WebSocket transport |

### Trojan (standalone)

```
1. Point your domain's A record at the VPS IP
2. sudo bash scripts/setup-trojan.sh proxy.example.com <password>
3. TROJAN_ENABLED=true sudo bash vps/iptables/rules.sh
```

Clients connect to `proxy.example.com:443` using the Trojan protocol.
Unauthenticated requests fall through to an nginx placeholder, so the server
looks like a normal HTTPS site to port scanners.

### Trojan + Cloudflare CDN

```
1. Add domain to Cloudflare; enable orange cloud (Proxied ON)
2. Set SSL/TLS to "Full" or "Full Strict" in Cloudflare dashboard
3. Enable WebSocket in Cloudflare Network settings
4. sudo bash scripts/setup-trojan-cloudflare.sh proxy.example.com <password> <cf-api-token>
5. TROJAN_ENABLED=true sudo bash vps/iptables/rules.sh
```

Traffic flows: `Client → Cloudflare CDN → VPS (WebSocket on port 443)`.
The Cloudflare API token only needs `Zone:DNS:Edit` permission (used for the
Let's Encrypt DNS-01 challenge). Revoke or scope it down after setup.

Config templates (for manual setup without the scripts):
```
vps/trojan/config.json.template              Trojan standalone
vps/trojan-cloudflare/config.json.template   Trojan + WebSocket
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
  wireguard/wg0.conf.template              WireGuard server config (no peers pre-configured)
  iptables/rules.sh                        iptables forwarding + hardening (set TROJAN_ENABLED=true for port 443)
  setup.sh                                 Full VPS bootstrap (WireGuard)
  trojan/config.json.template              Trojan-go config template (standalone)
  trojan-cloudflare/config.json.template   Trojan-go config template (WebSocket / Cloudflare CDN)
peers/
  <name>/wg0.conf.template      Created by add-peer.sh (none committed by default)
scripts/
  setup.sh                            Interactive setup wizard (WireGuard / Trojan / Trojan+CF)
  gen-keys.sh                         Generate VPS server keypair
  add-peer.sh                         Add a vpn-only or public peer
  setup-trojan.sh                     Install Trojan-go (standalone mode, called by wizard)
  setup-trojan-cloudflare.sh          Install Trojan-go (Cloudflare CDN + WebSocket, called by wizard)
```

See [CLAUDE.md](CLAUDE.md) for AI assistant conventions and development workflow.
