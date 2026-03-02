#!/usr/bin/env bash
# Trojan + Cloudflare Setup Script — VPS side
#
# Installs trojan-go with WebSocket transport so the domain can be proxied
# through Cloudflare's CDN. The CDN hides the real VPS IP and provides an
# additional layer against IP-based blocking.
#
# How it works:
#   Client ──► Cloudflare CDN (port 443, TLS) ──► VPS (port 443, WebSocket)
#   Trojan traffic travels inside WebSocket frames through Cloudflare.
#
# Usage:
#   sudo bash scripts/setup-trojan-cloudflare.sh <domain> <password> <cf-api-token>
#
# Arguments:
#   <domain>        Domain proxied through Cloudflare (e.g. proxy.example.com)
#   <password>      Trojan authentication password
#   <cf-api-token>  Cloudflare API token with Zone:DNS:Edit permission
#                   (used only for Let's Encrypt DNS-01 challenge; not stored
#                    in trojan-go config — delete the credentials file afterwards
#                    or rotate the token scope to DNS:Edit only)
#
# Requirements:
#   - Domain must be in Cloudflare (orange cloud / proxied ON)
#   - Cloudflare SSL/TLS mode must be set to "Full" or "Full Strict"
#   - Cloudflare WebSocket must be enabled (Network tab in dashboard)
#   - Port 443 open on VPS (HTTP-01 challenge NOT used; DNS-01 is used instead)
#
# What this script does:
#   1. Installs trojan-go, nginx, certbot + certbot-dns-cloudflare
#   2. Obtains a Let's Encrypt cert via DNS-01 challenge (no port 80 required)
#   3. Configures nginx on port 8080 as fallback for unauthenticated traffic
#   4. Writes /etc/trojan-go/config.json with WebSocket transport enabled
#   5. Creates a systemd service for trojan-go
#   6. Adds an iptables rule to allow port 443
#   7. Installs a certbot renewal hook
#
# Client settings (trojan-go / compatible clients):
#   server:    <domain>
#   port:      443
#   password:  <password>
#   websocket: enabled, path: /trojan, host: <domain>
#   ssl/tls:   enabled, verify: true

set -euo pipefail

TROJAN_GO_VERSION="${TROJAN_GO_VERSION:-0.10.6}"

# ── Preflight ──────────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash scripts/setup-trojan-cloudflare.sh)" >&2
    exit 1
fi

if [[ $# -lt 3 ]]; then
    echo "Usage: sudo bash scripts/setup-trojan-cloudflare.sh <domain> <password> <cf-api-token>" >&2
    exit 1
fi

DOMAIN="$1"
PASSWORD="$2"
CF_API_TOKEN="$3"

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
CF_CREDS="/etc/letsencrypt/cloudflare.ini"
CONFIG_DIR="/etc/trojan-go"
LOG_DIR="/var/log/trojan-go"

echo "==> Domain:         $DOMAIN"
echo "==> Password:       (provided)"
echo "==> CF API Token:   (provided)"
echo ""

# ── 1. System packages ─────────────────────────────────────────────────────────
echo "==> Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-dns-cloudflare unzip curl

# ── 2. Download and install trojan-go ─────────────────────────────────────────
echo "==> Installing trojan-go v${TROJAN_GO_VERSION}..."

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  TG_ARCH="amd64" ;;
    aarch64) TG_ARCH="arm64" ;;
    armv7l)  TG_ARCH="armv7" ;;
    *) echo "ERROR: Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

TG_URL="https://github.com/p4gefau1t/trojan-go/releases/download/v${TROJAN_GO_VERSION}/trojan-go-linux-${TG_ARCH}.zip"
TG_TMP="$(mktemp -d)"
trap 'rm -rf "$TG_TMP"' EXIT

curl -fsSL "$TG_URL" -o "$TG_TMP/trojan-go.zip"
unzip -q "$TG_TMP/trojan-go.zip" -d "$TG_TMP"
install -m 755 "$TG_TMP/trojan-go" /usr/local/bin/trojan-go
echo "    Installed: $(trojan-go --version 2>&1 | head -1)"

# ── 3. Obtain TLS certificate via DNS-01 challenge ────────────────────────────
# DNS-01 doesn't require port 80 to be reachable from the internet, so it
# works even when the domain is behind Cloudflare's proxy (orange cloud ON).
echo "==> Writing Cloudflare credentials..."
cat > "$CF_CREDS" <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
chmod 600 "$CF_CREDS"

echo "==> Obtaining TLS certificate for $DOMAIN via DNS-01..."
certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_CREDS" \
    --dns-cloudflare-propagation-seconds 30 \
    -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email
echo "    Certificate: $CERT_DIR"

echo "==> Cloudflare credentials file retained at $CF_CREDS for auto-renewal."
echo "    Restrict the token to Zone:DNS:Edit only; revoke when no longer needed."

# ── 4. Configure nginx as fallback on port 8080 ────────────────────────────────
echo "==> Configuring nginx fallback (port 8080)..."
cat > /etc/nginx/sites-available/trojan-fallback <<NGINX
server {
    listen 8080 default_server;
    server_name $DOMAIN;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
NGINX

ln -sf /etc/nginx/sites-available/trojan-fallback /etc/nginx/sites-enabled/trojan-fallback
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t
systemctl enable nginx --now

# ── 5. Write trojan-go config (WebSocket transport) ───────────────────────────
echo "==> Writing $CONFIG_DIR/config.json..."
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

cat > "$CONFIG_DIR/config.json" <<EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": 443,
    "remote_addr": "127.0.0.1",
    "remote_port": 8080,
    "password": [
        "$PASSWORD"
    ],
    "ssl": {
        "cert": "$CERT_DIR/fullchain.pem",
        "key": "$CERT_DIR/privkey.pem",
        "sni": "$DOMAIN",
        "session_ticket": true,
        "reuse_session": true
    },
    "websocket": {
        "enabled": true,
        "path": "/trojan",
        "host": "$DOMAIN"
    },
    "tcp": {
        "prefer_ipv4": true,
        "no_delay": true,
        "keep_alive": true,
        "fast_open": false
    },
    "log_level": 1,
    "log_file": "$LOG_DIR/access.log"
}
EOF
chmod 600 "$CONFIG_DIR/config.json"

# ── 6. Create systemd service ──────────────────────────────────────────────────
echo "==> Creating trojan-go systemd service..."
cat > /etc/systemd/system/trojan-go.service <<UNIT
[Unit]
Description=Trojan-Go proxy server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/trojan-go -config /etc/trojan-go/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable trojan-go --now

# ── 7. Certbot renewal hook ────────────────────────────────────────────────────
echo "==> Adding certbot renewal hook..."
cat > /etc/letsencrypt/renewal-hooks/post/restart-trojan-go.sh <<'HOOK'
#!/usr/bin/env bash
systemctl reload-or-restart trojan-go
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/post/restart-trojan-go.sh

# ── 8. Open port 443 in iptables ──────────────────────────────────────────────
echo "==> Allowing port 443 in iptables..."
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport 443 -j ACCEPT
echo "    NOTE: Re-running vps/iptables/rules.sh will reset this rule."
echo "          Add TROJAN_ENABLED=true at the top of rules.sh to persist it."

echo ""
echo "==> Trojan + Cloudflare setup complete."
echo ""
echo "    Domain:      $DOMAIN"
echo "    Port:        443 (TLS + WebSocket)"
echo "    WS path:     /trojan"
echo "    Fallback:    nginx on 8080 (internal)"
echo ""
echo "    Client settings (trojan-go WebSocket mode):"
echo "      server:    $DOMAIN"
echo "      port:      443"
echo "      password:  $PASSWORD"
echo "      websocket: enabled"
echo "      ws-path:   /trojan"
echo "      ws-host:   $DOMAIN"
echo "      ssl/tls:   enabled, verify: true"
echo ""
echo "    Cloudflare dashboard — confirm these settings:"
echo "      DNS:     $DOMAIN  A  <VPS_IP>  Proxied (orange cloud ON)"
echo "      SSL/TLS: Full or Full Strict"
echo "      Network: WebSocket enabled"
echo ""
echo "    Compatible clients: Clash (trojan+ws), v2rayN, NekoBox, trojan-go"
echo "    Certificate auto-renews via certbot DNS-01 renewal hook."
