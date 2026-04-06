#!/usr/bin/env bash
# install.sh — Syntex server bootstrap
# Runs on a fresh Ubuntu 24.04 LTS server via Hostinger browser terminal.
# Non-interactive — no prompts after paste. Requires root.
#
# Token placeholder — Syntex replaces this string before serving the script.
SX_TOKEN=__SX_TOKEN__

set -euo pipefail

# ─── COLOUR HELPERS ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step()  { echo -e "\n${CYAN}▶ $*${NC}"; }
ok()    { echo -e "  ${GREEN}✓ $*${NC}"; }
warn()  { echo -e "  ${YELLOW}⚠ $*${NC}"; }
die()   { echo -e "\n${RED}✗ $*${NC}" >&2; exit 1; }

# ─── SANITY CHECKS ────────────────────────────────────────────────────────────

[ "$(id -u)" = "0" ] || die "Must run as root. Try: sudo bash install.sh"

if [ "$SX_TOKEN" = "__SX_TOKEN__" ]; then
  die "SX_TOKEN was not replaced. Download this script from your Syntex dashboard, not from GitHub directly."
fi

ERRORS=0  # accumulated across all steps; reported at the end

# ─── 1. SYSTEM DEPENDENCIES ───────────────────────────────────────────────────

step "Updating apt and installing system dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get install -y -q git curl build-essential
ok "git, curl, build-essential installed"

# ─── 2. NODE.JS 22 VIA NODESOURCE ────────────────────────────────────────────

step "Installing Node.js 22 via NodeSource"
if node --version 2>/dev/null | grep -q '^v22\.'; then
  ok "Node.js $(node --version) already installed — skipping"
else
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - -q
  apt-get install -y -q nodejs
  ok "Node.js $(node --version) installed"
fi

# ─── 3. INSTALL OPENCLAW ──────────────────────────────────────────────────────

step "Installing OpenClaw (--no-onboard)"
if command -v openclaw >/dev/null 2>&1; then
  ok "OpenClaw already installed at $(command -v openclaw) — skipping"
else
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard
  ok "OpenClaw installed"
fi

# Ensure OC binary is on PATH (installer may update .bashrc which is not sourced here)
for candidate in \
    /root/.local/bin \
    /root/.openclaw/bin \
    /usr/local/bin \
    "$HOME/.local/bin" \
    "$HOME/.openclaw/bin"; do
  if [ -x "$candidate/openclaw" ] && [[ ":$PATH:" != *":$candidate:"* ]]; then
    export PATH="$candidate:$PATH"
  fi
done

command -v openclaw >/dev/null 2>&1 || die "openclaw binary not found after install. Check installer output above."

# ─── 4. OC NON-INTERACTIVE ONBOARDING ────────────────────────────────────────

OC_CONFIG="$HOME/.openclaw/openclaw.json"

step "Running OpenClaw non-interactive onboarding"
if [ -f "$OC_CONFIG" ]; then
  ok "OC config already exists at $OC_CONFIG — skipping onboarding"
else
  openclaw onboard --non-interactive \
    --mode local \
    --auth-choice custom-api-key \
    --custom-base-url "https://syntexprotocol.com/v1" \
    --custom-model-id "auto" \
    --custom-api-key "$SX_TOKEN" \
    --custom-compatibility openai \
    --gateway-port 18789 \
    --gateway-bind loopback \
    --install-daemon \
    --daemon-runtime node \
    --skip-skills \
    --accept-risk
  ok "OpenClaw onboarding complete"
  [ -f "$OC_CONFIG" ] || die "OC config not created at $OC_CONFIG — onboarding may have failed"
fi

# ─── 4b. RANDOM PORT, TLS, NGINX PROXY, UFW ──────────────────────────────────
#
# The OC gateway listens on loopback:18789 only. To let Syntex reach it from
# outside, we put an nginx HTTPS reverse proxy on a random high port in front
# of it. nginx validates the SX token as Bearer auth on every inbound request —
# nothing reaches the OC gateway without it. A self-signed TLS certificate
# provides encryption in transit. Authentication is the SX token.

# Reuse the existing port if this server was already set up, otherwise pick a
# new random unprivileged port. This is the key idempotency anchor for the whole
# nginx/ufw/registration block — everything downstream depends on it being stable.
if [ -f /etc/syntex/gateway.port ]; then
  GATEWAY_PORT=$(cat /etc/syntex/gateway.port)
  step "Reusing existing OC gateway port: $GATEWAY_PORT"
else
  GATEWAY_PORT=""
  for _attempt in $(seq 1 20); do
    _p=$(shuf -i 49152-65535 -n 1)
    if ! ss -tlnp 2>/dev/null | grep -q ":${_p} "; then
      GATEWAY_PORT="$_p"
      break
    fi
  done
  [ -n "$GATEWAY_PORT" ] || die "Could not find a free port in 49152-65535 after 20 attempts"
  step "Selected random OC gateway port: $GATEWAY_PORT"
  mkdir -p /etc/syntex
  echo "$GATEWAY_PORT" > /etc/syntex/gateway.port
fi

step "Installing nginx, openssl, and ufw"
apt-get install -y -q nginx openssl ufw
ok "nginx, openssl, ufw installed"

step "Generating self-signed TLS certificate"
if [ -f /etc/nginx/ssl/syntex/oc.crt ] && [ -f /etc/nginx/ssl/syntex/oc.key ]; then
  ok "TLS cert already exists at /etc/nginx/ssl/syntex/ — skipping generation"
else
  mkdir -p /etc/nginx/ssl/syntex
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/syntex/oc.key \
    -out    /etc/nginx/ssl/syntex/oc.crt \
    -subj   "/CN=syntex-oc/O=Syntex/C=AU" \
    2>/dev/null
  chmod 600 /etc/nginx/ssl/syntex/oc.key
  ok "Self-signed TLS cert at /etc/nginx/ssl/syntex/"
fi

step "Configuring nginx HTTPS reverse proxy on port $GATEWAY_PORT"
# Note: bash variables ($GATEWAY_PORT, $SX_TOKEN) are expanded here.
# nginx variables ($host, $remote_addr, etc.) are escaped with \ so bash
# leaves them alone and nginx sees the literal $ at runtime.
cat > /etc/nginx/sites-available/syntex-oc << NGINX_CONF
server {
    listen $GATEWAY_PORT ssl;
    server_name _;

    ssl_certificate     /etc/nginx/ssl/syntex/oc.crt;
    ssl_certificate_key /etc/nginx/ssl/syntex/oc.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Reject any request that does not carry the exact SX token as Bearer auth.
    # Authentication is via the SX token. TLS provides encryption only.
    if (\$http_authorization != "Bearer $SX_TOKEN") {
        return 401;
    }

    location / {
        proxy_pass         http://127.0.0.1:18789;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
    }
}
NGINX_CONF

ln -sf /etc/nginx/sites-available/syntex-oc /etc/nginx/sites-enabled/syntex-oc
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx
ok "nginx configured on port $GATEWAY_PORT"

step "Configuring ufw firewall"
# Allow SSH first so we cannot lock ourselves out.
ufw allow 22/tcp             comment 'SSH'
ufw allow "$GATEWAY_PORT/tcp" comment 'Syntex OC gateway HTTPS'
# Explicitly deny external access to the raw OC gateway port (loopback only).
ufw deny  18789/tcp          comment 'OC gateway loopback — deny external'
ufw --force enable
ok "ufw: port $GATEWAY_PORT open, port 18789 denied"

step "Registering OC gateway with Syntex"
# Send a heartbeat with the X-OC-Gateway-Port header so Syntex can store
# https://[this-server-ip]:[port] as the gateway URL for the modal channel.
REGISTRATION_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST https://syntexprotocol.com/v1/chat/completions \
  -H "Authorization: Bearer $SX_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-OC-Gateway-Port: $GATEWAY_PORT" \
  -d "{\"model\":\"syntex/auto\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"stream\":false}" \
  --max-time 15)
if [ "$REGISTRATION_HTTP" = "200" ]; then
  ok "OC gateway registered with Syntex (HTTP 200)"
else
  warn "Gateway registration returned HTTP $REGISTRATION_HTTP — check Syntex logs"
  ERRORS=$((ERRORS + 1))
fi

# ─── 5. CLONE AND INSTALL SYNTEX MCP ─────────────────────────────────────────

step "Cloning syntex-mcp into /opt/syntex-mcp"
if [ -d /opt/syntex-mcp ]; then
  warn "/opt/syntex-mcp already exists — pulling latest"
  git -C /opt/syntex-mcp pull --ff-only
else
  git clone https://github.com/McFlipperson/syntex-mcp /opt/syntex-mcp
fi
ok "syntex-mcp cloned"

step "Installing syntex-mcp dependencies"
npm install --prefix /opt/syntex-mcp --omit=dev
ok "npm install complete"

# ─── 6. REGISTER MCP SERVER IN OC CONFIG ──────────────────────────────────────
#
# Schema: { "mcp": { "servers": { "<name>": { "command", "args", "env" } } } }
# We read the existing config, merge in the syntex-mcp entry, and write it back.
# The SX_TOKEN is passed as an env var to the MCP process — never hard-coded into
# the command string.

step "Adding syntex-mcp to OC config"

SX_TOKEN="$SX_TOKEN" SX_GATEWAY_PORT="$GATEWAY_PORT" node - "$OC_CONFIG" << 'NODE_SCRIPT'
const fs = require('fs');

// process.argv[1] is empty string when node reads from stdin (node -)
// The first real argument is always at process.argv[2].
const configPath  = process.argv[2];
const token       = process.env.SX_TOKEN;
const gatewayPort = process.env.SX_GATEWAY_PORT;

let config;
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
  process.stderr.write(`Failed to read OC config at ${configPath}: ${e.message}\n`);
  process.exit(1);
}

// Merge — do not clobber existing mcp.servers entries
if (!config.mcp)                config.mcp         = {};
if (!config.mcp.servers)        config.mcp.servers = {};

config.mcp.servers['syntex-mcp'] = {
  command: 'node',
  args:    ['/opt/syntex-mcp/src/index.js'],
  env:     { SX_TOKEN: token, SX_GATEWAY_PORT: gatewayPort }
};

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
process.stdout.write('syntex-mcp entry written to OC config\n');
NODE_SCRIPT

ok "syntex-mcp registered in $OC_CONFIG"

# ─── 7. RESTART OC DAEMON ────────────────────────────────────────────────────
#
# Pick up the new MCP server config. The onboard step may have already started
# the daemon; we restart to ensure the latest config is loaded.
#
# Detection order:
#   1. systemctl — scan known service names
#   2. openclaw restart — OC's own CLI restart subcommand
#   3. Hard failure with exact manual command printed

step "Restarting OC daemon to apply MCP config"

OC_SERVICE=""
for svc in openclaw oc-daemon openclaw-daemon oc-gateway openclaw-gateway; do
  if systemctl list-unit-files --quiet 2>/dev/null | grep -q "^${svc}\.service"; then
    OC_SERVICE="$svc"
    break
  fi
done

if [ -n "$OC_SERVICE" ]; then
  systemctl restart "$OC_SERVICE"
  sleep 2
  ok "Daemon '$OC_SERVICE' restarted via systemctl"
elif openclaw restart 2>/dev/null; then
  sleep 2
  ok "Daemon restarted via openclaw restart"
else
  warn "Could not restart OC daemon automatically."
  warn "Run this command manually before using Syntex:"
  warn "  openclaw restart"
  ERRORS=$((ERRORS + 1))
fi

# ─── 8. GENERATE SSH KEY PAIR ─────────────────────────────────────────────────

step "Generating Ed25519 SSH key pair"
mkdir -p /root/.syntex/ssh
chmod 700 /root/.syntex /root/.syntex/ssh

if [ -f /root/.syntex/ssh/id_ed25519 ]; then
  warn "SSH key already exists at /root/.syntex/ssh/id_ed25519 — skipping generation"
else
  ssh-keygen -t ed25519 \
    -f /root/.syntex/ssh/id_ed25519 \
    -N "" \
    -C "syntex-server-$(hostname)" \
    -q
  ok "Ed25519 key pair generated"
fi

mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Add public key only if not already present
PUBKEY=$(cat /root/.syntex/ssh/id_ed25519.pub)
if ! grep -qF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
  echo "$PUBKEY" >> /root/.ssh/authorized_keys
  ok "Public key added to /root/.ssh/authorized_keys"
else
  warn "Public key already in authorized_keys — skipping"
fi

# ─── 9. VERIFY AND REPORT ────────────────────────────────────────────────────

step "Verifying installation"

# Check OC gateway is listening on port 18789
if ss -tlnp 2>/dev/null | grep -q ':18789' || \
   netstat -tlnp 2>/dev/null | grep -q ':18789'; then
  ok "OC gateway is listening on port 18789"
else
  warn "Gateway not yet listening on port 18789 — may still be starting up"
fi

# Check MCP entry in config
if node -e "
  const cfg = JSON.parse(require('fs').readFileSync('$OC_CONFIG', 'utf8'));
  if (!cfg.mcp?.servers?.['syntex-mcp']) { process.exit(1); }
" 2>/dev/null; then
  ok "syntex-mcp is registered in OC config"
else
  warn "syntex-mcp entry not found in OC config — check $OC_CONFIG manually"
  ERRORS=$((ERRORS + 1))
fi

# Check MCP install
if [ -f /opt/syntex-mcp/src/index.js ] && [ -d /opt/syntex-mcp/node_modules ]; then
  ok "syntex-mcp is installed at /opt/syntex-mcp"
else
  warn "/opt/syntex-mcp is incomplete — check npm install output above"
  ERRORS=$((ERRORS + 1))
fi

# Check SSH key
if [ -f /root/.syntex/ssh/id_ed25519 ] && [ -f /root/.syntex/ssh/id_ed25519.pub ]; then
  ok "SSH key pair present at /root/.syntex/ssh/"
else
  warn "SSH key missing — check key generation output above"
  ERRORS=$((ERRORS + 1))
fi

# ─── SUCCESS MESSAGE ──────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Syntex server bootstrap complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}OC gateway${NC}     listening on localhost:18789"
echo -e "  ${CYAN}MCP server${NC}     syntex-mcp loaded from /opt/syntex-mcp"
echo -e "  ${CYAN}SSH public key${NC} $(cat /root/.syntex/ssh/id_ed25519.pub)"
echo ""

if [ "$ERRORS" -gt 0 ]; then
  echo -e "  ${YELLOW}⚠ $ERRORS warning(s) above — review before continuing${NC}"
  echo ""
fi

echo -e "  ${GREEN}→ Return to your Syntex dashboard to download your server key.${NC}"
echo ""
