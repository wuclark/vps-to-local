#!/usr/bin/env bash
# Trojan Setup Script — VPS side (standalone mode)
#
# Installs trojan-go on a fresh VPS as a TLS proxy on port 443.
# Unauthenticated connections fall through to an nginx placeholder on port 8080
# so the VPS looks like a normal HTTPS site to scanners.
#
# Usage:
#   sudo bash scripts/setup-trojan.sh <domain> <password>
#
# Requirements:
#   - Domain A record must already point to this VPS IP
#   - Port 80 open for Let's Encrypt HTTP-01 challenge
#   - Port 443 open for Trojan clients
#
# What this script does:
#   1. Installs trojan-go, nginx, certbot
#   2. Obtains a Let's Encrypt TLS certificate (HTTP-01 challenge)
#   3. Configures nginx on port 8080 as a fallback for unauthenticated traffic
#   4. Writes /etc/trojan-go/config.json and creates a systemd service
#   5. Adds an iptables rule to allow port 443
#   6. Installs a certbot renewal hook to restart trojan-go after cert renewal
#
# After running:
#   - Clients connect to <domain>:443 using the Trojan protocol
#   - Compatible clients: Clash, Shadowrocket, v2rayN, NekoBox, trojan-go

set -euo pipefail

TROJAN_GO_VERSION="${TROJAN_GO_VERSION:-0.10.6}"

# ── Preflight ──────────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash scripts/setup-trojan.sh)" >&2
    exit 1
fi

if [[ $# -lt 2 ]]; then
    echo "Usage: sudo bash scripts/setup-trojan.sh <domain> <password>" >&2
    exit 1
fi

DOMAIN="$1"
PASSWORD="$2"

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
CONFIG_DIR="/etc/trojan-go"
LOG_DIR="/var/log/trojan-go"

echo "==> Domain:   $DOMAIN"
echo "==> Password: (provided)"
echo ""

# ── 1. System packages ─────────────────────────────────────────────────────────
echo "==> Installing prerequisites (nginx, certbot, unzip, curl)..."
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx unzip curl

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

# ── 3. Obtain TLS certificate ──────────────────────────────────────────────────
echo "==> Obtaining TLS certificate for $DOMAIN via Let's Encrypt..."
# Temporarily stop nginx so certbot --standalone can bind port 80
systemctl stop nginx 2>/dev/null || true
certbot certonly --standalone -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email
echo "    Certificate: $CERT_DIR"
systemctl start nginx

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

# ── 5. Write trojan-go config ──────────────────────────────────────────────────
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
echo "==> Trojan setup complete."
echo ""
echo "    Domain:   $DOMAIN"
echo "    Port:     443 (TLS)"
echo "    Fallback: nginx on 8080 (internal — looks like a real HTTPS site)"
echo ""
echo "    Client settings:"
echo "      server:   $DOMAIN"
echo "      port:     443"
echo "      password: $PASSWORD"
echo "      ssl/tls:  enabled, verify: true"
echo ""
echo "    Compatible clients: Clash, Shadowrocket, v2rayN, NekoBox, trojan-go"
echo "    Certificate auto-renews via certbot renewal hook."
