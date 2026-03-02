# CLAUDE.md — VPS-to-Local Tunnel Project

## Project Purpose

This repository contains **configuration templates and setup scripts** for exposing
home machines to the internet via an OVHcloud VPS acting as a WireGuard relay.
The VPS forwards traffic from dedicated public IPs to each home machine through
encrypted tunnels — no home machine is ever directly reachable.

Peers are named `remoteXXX` (e.g. `remote001`, `remote002`) — not by device type.
The repo ships with no peers pre-configured; all peers are added via `scripts/add-peer.sh`.

---

## Architecture

```
Internet
    │
    ▼
OVHcloud VPS
├── VPS main IP        ──► SSH (port 22) + WireGuard endpoint (port 51820)
├── Public IP #1       ──► DNAT ──► remoteXXX  (publicly reachable peer)
└── (no additional IP) ──► WireGuard only ──► remoteYYY  (VPN client peer)
```

### Peer Modes

Peers come in two modes, selected when running `add-peer.sh`:

| Mode | Command | `AllowedIPs` on client | DNAT rule | Use case |
|------|---------|----------------------|-----------|----------|
| **public** | `add-peer.sh <name> --public-ip <IP>` | `0.0.0.0/0` | yes | expose a home server |
| **vpn-only** | `add-peer.sh <name>` | `10.0.0.0/24` | no | phone, laptop, VPN access |

### IP Allocation
**Only public-mode peers need an additional IP.** VPN-only peers use no extra IP.

| IP | Role | Cost |
|----|------|------|
| VPS main IP | SSH + WireGuard handshakes — never DNAT'd | included |
| Additional IP (per public peer) | All traffic DNAT'd to that peer | ~$2/mo each |

DNAT rules match only on their specific additional IP, so the VPS main IP is
never forwarded and always reachable for administration.

**WireGuard subnet:** `10.0.0.0/24`
| Host | WireGuard IP |
|------|-------------|
| VPS  | 10.0.0.1    |
| first peer | 10.0.0.2 |
| second peer | 10.0.0.3 |

Peers are auto-assigned IPs starting at `.2`, incrementing by one each time.

---

## Repository Structure

```
vps-to-local/
├── CLAUDE.md                    # This file
├── README.md                    # Human-readable setup guide
├── vps/
│   ├── wireguard/
│   │   └── wg0.conf.template    # WireGuard server config (VPS side)
│   ├── iptables/
│   │   └── rules.sh             # iptables forwarding + hardening rules
│   └── setup.sh                 # Full VPS bootstrap script
├── peers/
│   └── <name>/                  # Created by: bash scripts/add-peer.sh <name>
│       └── wg0.conf.template    # WireGuard client config (no peers pre-committed)
└── scripts/
    ├── gen-keys.sh              # Generate VPS server keypair
    └── add-peer.sh              # Add a peer (vpn-only or public)
```

---

## Key Conventions for AI Assistants

### Peer Naming
- All peers use the `remoteXXX` naming scheme (zero-padded three digits)
- Never use device-type names like "laptop" or "desktop"
- Peer directories: `peers/remote001/`, `peers/remote002/`, ...
- WireGuard IPs start at `10.0.0.2` for `remote001` and increment by one

### Placeholder Format
All templates use `<PLACEHOLDER>` syntax. Never substitute real keys or IPs
into committed files. Placeholders that appear in this repo:

| Placeholder              | Meaning                                           |
|--------------------------|---------------------------------------------------|
| `<VPS_MAIN_IP>`          | VPS primary IP (used as WireGuard endpoint)       |
| `<SERVER_PRIVATE_KEY>`   | VPS WireGuard private key (never commit)          |
| `<SERVER_PUBLIC_KEY>`    | VPS WireGuard public key                          |
| `<NAME_PRIVATE_KEY>`     | Peer private key — NAME uppercased (never commit) |
| `<NAME_PUBLIC_KEY>`      | Peer public key — NAME uppercased                 |

Placeholder names are derived from the peer name by `add-peer.sh`:
e.g. peer `remote001` → `<REMOTE001_PRIVATE_KEY>`, `<REMOTE001_PUBLIC_KEY>`
e.g. peer `raspberry-pi` → `<RASPBERRY_PI_PRIVATE_KEY>`, `<RASPBERRY_PI_PUBLIC_KEY>`

Public IPs are written as literals into `rules.sh` by `add-peer.sh` — never as
placeholders, since they are real values filled in at commit time.

### Security Rules
- **Never commit private keys** — they belong in `/etc/wireguard/` on each machine
- **Never commit real IP addresses** — keep templates generic with placeholders
- All iptables rules must default-deny; only add explicit ACCEPT rules
- SSH must use key-only auth (no passwords)

### Adding a New Peer
Use the provided script — it handles IP assignment, template creation, and patching automatically:
```bash
# VPN client only (phone, laptop — no public IP needed):
bash scripts/add-peer.sh remote001

# Publicly reachable server (home desktop, NAS, etc.):
bash scripts/add-peer.sh remote001 --public-ip <PUBLIC_IP>
```

The script sets `AllowedIPs` appropriately for each mode and only adds a DNAT
rule to `rules.sh` when `--public-ip` is given.

### WireGuard Reload (no downtime)
```bash
# On VPS, reload config without dropping tunnels
wg syncconf wg0 <(wg-quick strip wg0)
```

### iptables Rule Order
Rules in `rules.sh` must be applied in this order:
1. Flush existing rules
2. Set default policies (INPUT DROP, FORWARD DROP, OUTPUT ACCEPT)
3. Allow loopback and established/related connections
4. Allow WireGuard UDP port (51820)
5. Allow SSH (port 22)
6. DNAT rules (PREROUTING)
7. FORWARD rules (only permit traffic destined for WireGuard subnet)
8. SYN flood rate limiting

---

## Development Workflow

### Testing Changes Locally
Scripts are designed to be idempotent (safe to re-run). Test on a throw-away
VM before applying to production VPS.

```bash
# Dry-run iptables rules (print only)
bash vps/iptables/rules.sh --dry-run

# Validate WireGuard config syntax
wg-quick strip vps/wireguard/wg0.conf
```

### Applying to Production VPS
```bash
# 1. Copy VPS configs
scp vps/wireguard/wg0.conf.template root@<VPS>:/tmp/
scp vps/iptables/rules.sh root@<VPS>:/tmp/

# 2. SSH in and apply
ssh root@<VPS>
# Edit /tmp/wg0.conf.template → fill in real keys/IPs → place at /etc/wireguard/wg0.conf
bash /tmp/rules.sh
```

### Commit Hygiene
- One logical change per commit
- Commit messages: `<scope>: <what changed>` (e.g., `peers: add remote003`)
- Never commit secrets (enforced by `.gitignore`)

---

## Cost Reference

| Item | Cost/mo |
|------|---------|
| OVHcloud VPS-2 | ~$9.99 |
| Additional IP (per public peer) | ~$2.00 |
| **Minimum (VPS only, no peers)** | **~$10** |
| **With 1 public peer** | **~$12** |

VPN-only peers cost nothing extra — they share the VPS main IP via WireGuard.

> US/EU datacenters only for unlimited bandwidth. Avoid AP datacenters.
