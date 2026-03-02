# CLAUDE.md — VPS-to-Local Tunnel Project

## Project Purpose

This repository contains **configuration templates and setup scripts** for exposing
home machines (laptop, desktop) to the internet via an OVHcloud VPS acting as a
WireGuard relay. The VPS forwards traffic from dedicated public IPs to each home
machine through encrypted tunnels — no home machine is ever directly reachable.

---

## Architecture

```
Internet
    │
    ▼
OVHcloud VPS  (relay only — no services run here)
├── Public IP #1  ──► WireGuard ──► Laptop  (10.0.0.2)
└── Public IP #2  ──► WireGuard ──► Desktop (10.0.0.3)
```

**WireGuard subnet:** `10.0.0.0/24`
| Host    | WireGuard IP |
|---------|-------------|
| VPS     | 10.0.0.1    |
| Laptop  | 10.0.0.2    |
| Desktop | 10.0.0.3    |

---

## Repository Structure

```
vps-to-local/
├── CLAUDE.md                  # This file
├── README.md                  # Human-readable setup guide
├── vps/
│   ├── wireguard/
│   │   └── wg0.conf.template  # WireGuard server config (VPS side)
│   ├── iptables/
│   │   └── rules.sh           # iptables forwarding + hardening rules
│   └── setup.sh               # Full VPS bootstrap script
├── peers/
│   ├── laptop/
│   │   └── wg0.conf.template  # WireGuard client config for laptop
│   └── desktop/
│       └── wg0.conf.template  # WireGuard client config for desktop
└── scripts/
    └── gen-keys.sh            # Generate WireGuard keypairs for all nodes
```

---

## Key Conventions for AI Assistants

### Placeholder Format
All templates use `<PLACEHOLDER>` syntax. Never substitute real keys or IPs
into committed files. Placeholders that appear in this repo:

| Placeholder            | Meaning                                      |
|------------------------|----------------------------------------------|
| `<VPS_MAIN_IP>`        | VPS primary IP (used as WireGuard endpoint)  |
| `<PUBLIC_IP_1>`        | Additional OVHcloud IP routed to laptop      |
| `<PUBLIC_IP_2>`        | Additional OVHcloud IP routed to desktop     |
| `<SERVER_PRIVATE_KEY>` | VPS WireGuard private key (never commit)     |
| `<SERVER_PUBLIC_KEY>`  | VPS WireGuard public key                     |
| `<LAPTOP_PRIVATE_KEY>` | Laptop WireGuard private key (never commit)  |
| `<LAPTOP_PUBLIC_KEY>`  | Laptop WireGuard public key                  |
| `<DESKTOP_PRIVATE_KEY>`| Desktop WireGuard private key (never commit) |
| `<DESKTOP_PUBLIC_KEY>` | Desktop WireGuard public key                 |

### Security Rules
- **Never commit private keys** — they belong in `/etc/wireguard/` on each machine
- **Never commit real IP addresses** — keep templates generic with placeholders
- All iptables rules must default-deny; only add explicit ACCEPT rules
- SSH must use key-only auth (no passwords)

### Adding a New Peer
1. Generate keypair on the new machine: `wg genkey | tee private.key | wg pubkey > public.key`
2. Assign the next available WireGuard IP (10.0.0.4, 10.0.0.5, ...)
3. Add a `[Peer]` block to `vps/wireguard/wg0.conf.template`
4. Add an iptables DNAT rule in `vps/iptables/rules.sh` if a dedicated public IP is needed
5. Create a new directory under `peers/<hostname>/`

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
- Commit messages: `<scope>: <what changed>` (e.g., `iptables: add SYN flood rate limiting`)
- Never commit secrets (enforced by `.gitignore`)

---

## Cost Reference

| Item                   | Cost/mo |
|------------------------|---------|
| OVHcloud VPS-2         | ~$9.99  |
| Additional IP (laptop) | ~$2.00  |
| Additional IP (desktop)| ~$2.00  |
| **Total**              | **~$14**|

> US/EU datacenters only for unlimited bandwidth. Avoid AP datacenters.
