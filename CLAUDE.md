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
OVHcloud VPS
├── VPS main IP   ──► SSH (port 22) + WireGuard endpoint (port 51820)
└── Public IP #1  ──► DNAT ──► remote001  (10.0.0.2)
```

### IP Allocation
**N remotes require N+1 public IPs total.** The baseline is 2 IPs for 1 remote.

| IP | Role | Cost |
|----|------|------|
| VPS main IP | SSH access + WireGuard handshakes — never DNAT'd | included |
| Additional IP #1 | All traffic forwarded to remote001 | ~$2/mo |

The DNAT rules in `rules.sh` match only on their specific additional IP
(`-d "$PUBLIC_IP_1"`), so the VPS main IP passes through the PREROUTING
chain untouched. SSH and WireGuard handshakes always reach the VPS directly.

Additional peers are added with `scripts/add-peer.sh` — each needs one more
additional IP if it requires its own public address.

**WireGuard subnet:** `10.0.0.0/24`
| Host      | WireGuard IP |
|-----------|-------------|
| VPS       | 10.0.0.1    |
| remote001 | 10.0.0.2    |

New peers continue the sequence: `remote002` → `10.0.0.3`, `remote003` → `10.0.0.4`, etc.

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
│   └── remoteXXX/               # Add more with: bash scripts/add-peer.sh remoteXXX
└── scripts/
    ├── gen-keys.sh              # Generate WireGuard keypairs (VPS + remote001)
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
| `<SERVER_PRIVATE_KEY>`   | VPS WireGuard private key (never commit)       |
| `<SERVER_PUBLIC_KEY>`    | VPS WireGuard public key                       |
| `<REMOTE001_PRIVATE_KEY>`| remote001 WireGuard private key (never commit) |
| `<REMOTE001_PUBLIC_KEY>` | remote001 WireGuard public key                 |

Additional peers follow the same pattern: `<REMOTE002_PRIVATE_KEY>`, `<REMOTE002_PUBLIC_KEY>`, etc.

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
| **Total (1 peer)**        | **~$12**|

Each additional peer costs ~$2/mo more if it needs its own public IP.

> US/EU datacenters only for unlimited bandwidth. Avoid AP datacenters.
