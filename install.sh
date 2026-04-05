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

# ─── 1. SYSTEM DEPENDENCIES ───────────────────────────────────────────────────

step "Updating apt and installing system dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get install -y -q git curl build-essential
ok "git, curl, build-essential installed"

# ─── 2. NODE.JS 22 VIA NODESOURCE ────────────────────────────────────────────

step "Installing Node.js 22 via NodeSource"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - -q
apt-get install -y -q nodejs
NODE_VER=$(node --version)
ok "Node.js $NODE_VER installed"

# ─── 3. INSTALL OPENCLAW ──────────────────────────────────────────────────────

step "Installing OpenClaw (--no-onboard)"
curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard
ok "OpenClaw installed"

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

step "Running OpenClaw non-interactive onboarding"
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

OC_CONFIG="$HOME/.openclaw/openclaw.json"
[ -f "$OC_CONFIG" ] || die "OC config not created at $OC_CONFIG — onboarding may have failed"

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

SX_TOKEN="$SX_TOKEN" node - "$OC_CONFIG" << 'NODE_SCRIPT'
const fs   = require('fs');
const path = require('path');

const configPath = process.argv[1];
const token      = process.env.SX_TOKEN;

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
  env:     { SX_TOKEN: token }
};

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
process.stdout.write('syntex-mcp entry written to OC config\n');
NODE_SCRIPT

ok "syntex-mcp registered in $OC_CONFIG"

# ─── 7. WRITE CLAUDE.MD TO OC WORKSPACE ──────────────────────────────────────
#
# Detect workspace dir from config; fall back to $HOME.

step "Writing CLAUDE.md to OC workspace"

OC_WORKSPACE=$(node - "$OC_CONFIG" << 'NODE_SCRIPT'
const fs  = require('fs');
let cfg;
try { cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); } catch { cfg = {}; }
// Try known config keys for workspace location
const ws = cfg.workspace || cfg.workspaceDir || cfg.workDir || '';
process.stdout.write(ws);
NODE_SCRIPT
)

if [ -z "$OC_WORKSPACE" ]; then
  OC_WORKSPACE="$HOME"
  warn "No workspace dir found in OC config — writing CLAUDE.md to $HOME"
fi

mkdir -p "$OC_WORKSPACE"

cat > "$OC_WORKSPACE/CLAUDE.md" << 'CLAUDEMD'
Syntex is handling all routing and cost governance. Do not modify model selection. Do not override routing decisions.
CLAUDEMD

ok "CLAUDE.md written to $OC_WORKSPACE/CLAUDE.md"

# ─── 8. RESTART OC DAEMON ────────────────────────────────────────────────────
#
# Pick up the new MCP server config. The onboard step may have already started
# the daemon; we restart to ensure the latest config is loaded.

step "Restarting OC daemon to apply MCP config"

OC_SERVICE=""
for svc in openclaw oc-gateway openclaw-daemon openclaw-gateway; do
  if systemctl list-unit-files --quiet "$svc.service" 2>/dev/null | grep -q "$svc"; then
    OC_SERVICE="$svc"
    break
  fi
done

if [ -n "$OC_SERVICE" ]; then
  systemctl restart "$OC_SERVICE"
  sleep 2
  ok "Daemon '$OC_SERVICE' restarted"
else
  warn "Could not detect OC systemd service name — daemon may need manual restart"
fi

# ─── 9. GENERATE SSH KEY PAIR ─────────────────────────────────────────────────

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

# ─── 10. VERIFY AND REPORT ────────────────────────────────────────────────────

step "Verifying installation"

ERRORS=0

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
echo -e "  ${CYAN}CLAUDE.md${NC}      written to $OC_WORKSPACE/CLAUDE.md"
echo -e "  ${CYAN}SSH public key${NC} $(cat /root/.syntex/ssh/id_ed25519.pub)"
echo ""

if [ "$ERRORS" -gt 0 ]; then
  echo -e "  ${YELLOW}⚠ $ERRORS warning(s) above — review before continuing${NC}"
  echo ""
fi

echo -e "  ${GREEN}→ Return to your Syntex dashboard to download your server key.${NC}"
echo ""
