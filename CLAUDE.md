# CLAUDE.md — VPS-to-Local Tunnel Project

## Project Purpose

This repository contains **configuration templates and setup scripts** for exposing
home machines to the internet via an OVHcloud VPS acting as a WireGuard relay.
The VPS forwards traffic from dedicated public IPs to each home machine through
encrypted tunnels — no home machine is ever directly reachable.

Peers are named `remoteXXX` (e.g. `remote001`, `remote002`) — not by device type.

---

## Architecture

```
Internet
    │
    ▼
OVHcloud VPS  (relay only — no services run here)
├── Public IP #1  ──► WireGuard ──► remote001  (10.0.0.2)
└── Public IP #2  ──► WireGuard ──► remote002  (10.0.0.3)
```

**WireGuard subnet:** `10.0.0.0/24`
| Host      | WireGuard IP |
|-----------|-------------|
| VPS       | 10.0.0.1    |
| remote001 | 10.0.0.2    |
| remote002 | 10.0.0.3    |

New peers continue the sequence: `remote003` → `10.0.0.4`, `remote004` → `10.0.0.5`, etc.

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
│   ├── remote001/
│   │   └── wg0.conf.template    # WireGuard client config for remote001
│   ├── remote002/
│   │   └── wg0.conf.template    # WireGuard client config for remote002
│   └── remoteXXX/               # Add more with scripts/add-peer.sh
└── scripts/
    ├── gen-keys.sh              # Generate WireGuard keypairs for all nodes
    └── add-peer.sh              # Add a new remoteXXX peer
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

| Placeholder              | Meaning                                        |
|--------------------------|------------------------------------------------|
| `<VPS_MAIN_IP>`          | VPS primary IP (used as WireGuard endpoint)    |
| `<PUBLIC_IP_1>`          | Additional OVHcloud IP routed to remote001     |
| `<PUBLIC_IP_2>`          | Additional OVHcloud IP routed to remote002     |
| `<SERVER_PRIVATE_KEY>`   | VPS WireGuard private key (never commit)       |
| `<SERVER_PUBLIC_KEY>`    | VPS WireGuard public key                       |
| `<REMOTE001_PRIVATE_KEY>`| remote001 WireGuard private key (never commit) |
| `<REMOTE001_PUBLIC_KEY>` | remote001 WireGuard public key                 |
| `<REMOTE002_PRIVATE_KEY>`| remote002 WireGuard private key (never commit) |
| `<REMOTE002_PUBLIC_KEY>` | remote002 WireGuard public key                 |

Additional peers follow the same pattern: `<REMOTE003_PRIVATE_KEY>`, etc.

### Security Rules
- **Never commit private keys** — they belong in `/etc/wireguard/` on each machine
- **Never commit real IP addresses** — keep templates generic with placeholders
- All iptables rules must default-deny; only add explicit ACCEPT rules
- SSH must use key-only auth (no passwords)

### Adding a New Peer
Use the provided script — it handles IP assignment, template creation, and patching automatically:
```bash
bash scripts/add-peer.sh remote003
bash scripts/add-peer.sh remote003 --public-ip <PUBLIC_IP_3>
```

Manual steps (if not using the script):
1. Generate keypair on the new machine: `wg genkey | tee private.key | wg pubkey > public.key`
2. Assign the next available WireGuard IP (10.0.0.4 for remote003, etc.)
3. Add a `[Peer]` block to `vps/wireguard/wg0.conf.template`
4. Add an iptables DNAT rule in `vps/iptables/rules.sh` if a dedicated public IP is needed
5. Create `peers/remote003/wg0.conf.template`

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

| Item                      | Cost/mo |
|---------------------------|---------|
| OVHcloud VPS-2            | ~$9.99  |
| Additional IP (remote001) | ~$2.00  |
| Additional IP (remote002) | ~$2.00  |
| **Total (2 peers)**       | **~$14**|

> US/EU datacenters only for unlimited bandwidth. Avoid AP datacenters.
