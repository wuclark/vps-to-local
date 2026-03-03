# VPS-to-Local Tunnel

Expose home machines to the internet with dedicated public IPs using an OVHcloud
VPS as a WireGuard relay. The VPS forwards all traffic — it never terminates
connections itself. Peers are named `remoteXXX` and added on demand.

---

## Prerequisites

Install these on your **local machine** (laptop/desktop where you run the scripts)
before doing anything else.

**Linux:**
```bash
bash scripts/install-deps.sh
# Supports Ubuntu/Debian, Fedora/RHEL, Arch/Manjaro
```

**macOS:**
```bash
bash scripts/install-deps.sh
# Installs Homebrew if absent, then wireguard-tools
```

**Windows:**

The setup scripts are bash — install [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install)
first, then run them inside a WSL2 terminal:
```powershell
# In PowerShell (one-time):
wsl --install
```
```bash
# In WSL2 terminal:
bash scripts/install-deps.sh
```
Alternatively, install the [WireGuard app for Windows](https://www.wireguard.com/install/)
and follow the manual steps noted in each section below.

---

## SSH Key Setup (OVHcloud)

SSH password auth is disabled by `setup.sh`, so a key must be in place before
you run it. OVHcloud lets you inject a public key at OS-install time.

**1. Generate a key pair** (skip if you already have one):

**Linux / macOS / WSL2:**
```bash
ssh-keygen -t ed25519 -C "ovh-vps" -f ~/.ssh/ovh_vps
```

**Windows (PowerShell, no WSL):**
```powershell
ssh-keygen -t ed25519 -C "ovh-vps" -f "$env:USERPROFILE\.ssh\ovh_vps"
```

**2. Add the public key to OVHcloud:**

- Log into [OVHcloud Control Panel](https://www.ovh.com/auth/)
- Top-right menu → **My account** → **SSH keys** → **Add an SSH key**
- Paste the contents of `~/.ssh/ovh_vps.pub`, give it a label, save

**3. Attach the key when ordering or reinstalling the VPS:**

- During VPS order: the key selection appears in the **Configure your VPS** step
- On an existing VPS: go to **VPS** → your server → **…** → **Reinstall** →
  select OS → check **SSH key** and pick your key

OVHcloud writes the key to `~/.ssh/authorized_keys` on the new instance.

**4. Connect:**

```bash
# Ubuntu image
ssh -i ~/.ssh/ovh_vps ubuntu@<VPS_IP>

# Debian image
ssh -i ~/.ssh/ovh_vps debian@<VPS_IP>
```

Add this to `~/.ssh/config` to avoid specifying the key every time:

```
Host <VPS_IP>
    User ubuntu
    IdentityFile ~/.ssh/ovh_vps
```

> **Ubuntu 24.04 note:** `setup.sh` writes SSH hardening to
> `/etc/ssh/sshd_config.d/99-hardening.conf` (a drop-in) rather than
> editing `sshd_config` directly. This is compatible with Ubuntu 22.04 and
> 24.04's include-based config layout and survives OS upgrades.

---

## Quick Start

```
[your workstation — where you cloned this repo]
1. bash scripts/install-deps.sh         # install wireguard-tools
2. bash scripts/gen-keys.sh             # generate VPS server keypair — note both keys

[OVHcloud]
3. Order a VPS (US/EU datacenter, Ubuntu 24.04) — inject your SSH public key at install time
   Order one Additional IP per public peer (optional, ~$2/mo each)

[VPS — over SSH]
4. sudo bash scripts/setup.sh          # interactive wizard: WireGuard / Trojan / Trojan+CF
                                        # fills /etc/wireguard/wg0.conf from your input

[your workstation — where you cloned this repo]
5. bash scripts/add-peer.sh <name> [--public-ip <IP>]   # register a peer in the templates
6. bash scripts/gen-peer-conf.sh ...                     # generate the peer's tunnel config
                                                          # (see "Setting Up a Peer Machine")
```

---

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

---

## Peer Modes

| Mode | Command | Cost | Use case |
|------|---------|------|----------|
| **public** | `add-peer.sh <name> --public-ip <IP>` | +~$2/mo | home server, desktop |
| **vpn-only** | `add-peer.sh <name>` | free | phone, laptop, VPN access |

Public peers get all traffic DNAT'd from a dedicated IP (`AllowedIPs = 0.0.0.0/0`).
VPN-only peers can only reach the WireGuard subnet (`AllowedIPs = 10.0.0.0/24`).

---

## Adding Peers

```bash
# Publicly reachable (order an Additional IP from OVHcloud first)
bash scripts/add-peer.sh remote001 --public-ip <PUBLIC_IP>

# VPN client only (no extra IP needed)
bash scripts/add-peer.sh remote002
```

---

## Setting Up a Peer Machine

After running `add-peer.sh`, you have a `peers/<name>/wg0.conf.template` with
placeholders. Complete it, then import it on the peer machine.

### Step 1 — Generate a keypair on the peer machine

**Linux / macOS / WSL2:**
```bash
wg genkey | tee ~/wg-private.key | wg pubkey
# Private key saved to ~/wg-private.key; public key printed to stdout — save it for Step 3
chmod 600 ~/wg-private.key
```

**Windows (WireGuard app — no WSL):**

Open the WireGuard app → **Add Tunnel** → **Add empty tunnel…**

The app generates a keypair automatically and shows the public key at the top of
the editor. Copy it for Step 3, then close without saving (you'll import the
finished config in Step 4 instead).

### Step 2 — Generate `wg0.conf` from the template

**Linux / macOS / WSL2:**
```bash
bash scripts/gen-peer-conf.sh <name> ~/wg-private.key <SERVER_PUBLIC_KEY> <VPS_MAIN_IP>
# Writes peers/<name>/wg0.conf  (chmod 600, gitignored)
```

This reads the private key from a file so it never appears in your shell history.

**Windows (manual — no WSL):**

Copy `peers/<name>/wg0.conf.template` to `peers/<name>/wg0.conf` and replace
the three placeholders in a text editor:

| Placeholder | Value |
|-------------|-------|
| `<REMOTEXXX_PRIVATE_KEY>` | Private key from the WireGuard app (Step 1) |
| `<SERVER_PUBLIC_KEY>` | VPS public key from `gen-keys.sh` output |
| `<VPS_MAIN_IP>` | VPS primary IP address |

> `wg0.conf` is gitignored — it will never be committed. Keep it safe; it contains the private key.

### Step 3 — Tell the VPS about this peer

Copy the updated VPS server config to the VPS and apply it:

```bash
# On your local machine — copy the VPS template to the VPS
scp vps/wireguard/wg0.conf.template ubuntu@<VPS_IP>:/tmp/wg0.conf
ssh ubuntu@<VPS_IP>
```

On the VPS, fill in the two remaining placeholders (use `nano` or `vim`):

```bash
sudo nano /tmp/wg0.conf
```

| Placeholder | Value |
|-------------|-------|
| `<SERVER_PRIVATE_KEY>` | VPS private key from `gen-keys.sh` output |
| `<REMOTEXXX_PUBLIC_KEY>` | Peer public key from Step 1 |

Then place the completed config:

```bash
sudo cp /tmp/wg0.conf /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
```

**If WireGuard is not running yet** (first peer / fresh VPS):
```bash
sudo systemctl enable wg-quick@wg0 --now
```

**If WireGuard is already running** (adding a subsequent peer, no downtime):
```bash
sudo wg syncconf wg0 <(sudo wg-quick strip wg0)
```

### Step 4 — Import the tunnel on the peer machine

**Linux:**
```bash
sudo cp peers/<name>/wg0.conf /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable wg-quick@wg0 --now   # start now + on boot
sudo wg show                                # verify handshake appears
```

**macOS** (WireGuard app from the App Store):
```
File → Import tunnel(s) from file → select peers/<name>/wg0.conf
```
Click **Activate** to connect.

**Windows** (WireGuard app from wireguard.com):
```
Add Tunnel → Import tunnel(s) from file → select peers\<name>\wg0.conf
```
Click **Activate** to connect. To connect automatically on startup: right-click
the tray icon → **Start on Login**.

**iOS / Android** — generate a QR code instead of transferring the file:
```bash
# Install qrencode first: apt install qrencode  or  brew install qrencode
qrencode -t ansiutf8 < peers/<name>/wg0.conf
```
Open the WireGuard app → **+** → **Scan QR code**. Delete `peers/<name>/wg0.conf`
from your local machine after scanning.

---

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

---

## Security Layers

| Layer | What | Where |
|-------|------|-------|
| 1 | OVHcloud Network Firewall | OVHcloud control panel (free, pre-VPS) |
| 2 | iptables DNAT + default-deny FORWARD | VPS |
| 3 | WireGuard encrypted tunnels | VPS ↔ remote peers |
| 4 | Fail2Ban brute-force protection | VPS |
| 5 | CrowdSec community threat intel | VPS (optional) |

---

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
  <name>/wg0.conf               Filled-in config — gitignored, never committed
scripts/
  install-deps.sh                     Install local prerequisites (wireguard-tools) — run once on your machine
  setup.sh                            Interactive setup wizard (WireGuard / Trojan / Trojan+CF) — run on VPS
  gen-keys.sh                         Generate VPS server keypair
  add-peer.sh                         Add a vpn-only or public peer
  gen-peer-conf.sh                    Generate peers/<name>/wg0.conf from the template (gitignored)
  switch-mode.sh                      Upgrade/downgrade between proxy modes on a live VPS
  setup-trojan.sh                     Install Trojan-go (standalone mode, called by wizard)
  setup-trojan-cloudflare.sh          Install Trojan-go (Cloudflare CDN + WebSocket, called by wizard)
```

See [CLAUDE.md](CLAUDE.md) for AI assistant conventions and development workflow.
