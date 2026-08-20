#!/usr/bin/env bash
# Doug's AIShortTrading — deploy to a Tailscale-connected Ubuntu server.
#
# 2026-08-20 rewrite: the original version of this script (inherited from the
# AITrading fork) assumed a brand-new, unclaimed dedicated server -- it ran
# `ufw --force reset`, set up fail2ban fresh, and git-cloned the repo onto the
# box itself. None of that matches how this project is actually deployed: the
# real install lives on a box already running a sibling service
# (AICryptoTrading), reached over Tailscale, with HTTPS via a Tailscale-issued
# cert -- not a public port behind ufw. Running the old script against that
# box would have reset its firewall and broken the sibling service.
#
# This version mirrors the real steps used for the live install instead:
#   - Run from your LOCAL machine, not on the server -- this repo's local git
#     copy is the source of truth (same convention as AITrading and
#     AICryptoTrading); the server never runs `git clone` or `git pull`.
#   - Ships code via rsync, not git.
#   - Never touches the server's firewall or fail2ban -- a shared box's
#     network security posture is the operator's own concern, not something
#     a per-app deploy script should reset.
#   - HTTPS via `tailscale cert` reusing the box's own MagicDNS name, not a
#     plain HTTP port.
#   - Runs as root (matching the sibling services already on Hetzner boxes in
#     this project family), not a dedicated app user.
#   - Auto-detects an unused port rather than defaulting to 8080, since a
#     shared box may already have other family members running.
#
# Usage: bash scripts/deploy_ubuntu.sh <user@host> [install-dir] [port]
#   e.g.: bash scripts/deploy_ubuntu.sh root@100.67.94.82 /opt/aishorttrading 8082
#
# Idempotent where practical: safe to re-run against an already-deployed box
# to push new code (skips venv/.env/cert/systemd steps that already exist).
#
# NOT live-tested end to end against a genuinely fresh box (the real install
# this mirrors was built up manually, one verified step at a time, not by
# running a single script) -- read through it before trusting it blind on a
# real server, same caution the original script deserved and never got.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <user@host> [install-dir] [port]"
  echo "  e.g.: $0 root@100.67.94.82 /opt/aishorttrading 8082"
  exit 1
fi

TARGET="$1"                                  # e.g. root@100.67.94.82
APP_DIR="${2:-/opt/aishorttrading}"
REQUESTED_PORT="${3:-}"
SERVICE_NAME="aishorttrading"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
section() { echo -e "\n${GREEN}━━━ $* ━━━${NC}"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

section "Verify SSH access"
if ! ssh -o ConnectTimeout=10 "$TARGET" "echo connected" &>/dev/null; then
  echo -e "${RED}Cannot reach $TARGET over SSH — check the host/key before continuing.${NC}"
  exit 1
fi
info "SSH access to $TARGET confirmed"

section "Verify Tailscale on the target"
TS_HOSTNAME=$(ssh "$TARGET" "tailscale status --self --json 2>/dev/null" | \
  python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || true)
if [[ -z "$TS_HOSTNAME" ]]; then
  echo -e "${RED}Could not determine the target's Tailscale MagicDNS name.${NC}"
  echo "This deployment relies on Tailscale for both reachability and HTTPS (tailscale cert)."
  echo "Install/connect Tailscale on the target first: https://tailscale.com/download"
  exit 1
fi
info "Target Tailscale hostname: $TS_HOSTNAME"

section "Ship code (rsync, not git)"
rsync -az --delete \
  --exclude='.git' --exclude='venv' --exclude='__pycache__' \
  --exclude='.pytest_cache' --exclude='*.pyc' --exclude='.env' \
  --exclude='/certs' --exclude='/data' \
  -e ssh \
  "$REPO_ROOT/" "$TARGET:$APP_DIR/"
info "Code synced to $TARGET:$APP_DIR"

section "Remote setup"
ssh "$TARGET" bash -s -- "$APP_DIR" <<'REMOTE_SETUP'
set -euo pipefail
APP_DIR="$1"
mkdir -p "$APP_DIR/data" "$APP_DIR/certs"

if [[ ! -d "$APP_DIR/venv" ]]; then
  echo "Creating Python 3.12 venv..."
  /usr/bin/python3.12 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --upgrade pip -q
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" -q
echo "Dependencies installed"
REMOTE_SETUP
info "Venv and dependencies ready"

section "Credentials (.env)"
if ssh "$TARGET" "test -f $APP_DIR/.env"; then
  warn ".env already exists on $TARGET — leaving it untouched"
else
  echo ""
  echo "Enter API keys for the new install (blank = leave unset, edit .env manually later):"
  echo ""
  read -rp "  ANTHROPIC_API_KEY:    " ANT_KEY
  read -rp "  ALPACA_API_KEY:       " ALP_KEY
  read -rp "  ALPACA_SECRET_KEY:    " ALP_SEC
  read -rp "  ALPACA_BASE_URL [https://paper-api.alpaca.markets]: " ALP_URL
  ALP_URL="${ALP_URL:-https://paper-api.alpaca.markets}"
  read -rp "  FINNHUB_API_KEY:      " FIN_KEY
  read -rp "  NEWSAPI_API_KEY:      " NEWS_KEY
  read -rsp "  DASHBOARD_PASSWORD:   " DASH_PW; echo ""
  SESSION_KEY=$(ssh "$TARGET" "python3 -c \"import secrets; print(secrets.token_hex(32))\"")

  ssh "$TARGET" "cat > $APP_DIR/.env << EOF
ANTHROPIC_API_KEY=$ANT_KEY
ALPACA_API_KEY=$ALP_KEY
ALPACA_SECRET_KEY=$ALP_SEC
ALPACA_BASE_URL=$ALP_URL
FINNHUB_API_KEY=$FIN_KEY
NEWSAPI_API_KEY=$NEWS_KEY
DASHBOARD_PASSWORD=$DASH_PW
SESSION_SECRET_KEY=$SESSION_KEY
SSL_CERTFILE=$APP_DIR/certs/cert.pem
SSL_KEYFILE=$APP_DIR/certs/key.pem
EOF
chmod 600 $APP_DIR/.env"
  info ".env created on $TARGET"
fi

section "Pick a port"
if [[ -n "$REQUESTED_PORT" ]]; then
  PORT="$REQUESTED_PORT"
else
  # Start at 8080 (matches this project family's own convention: AITrading=8080,
  # AICryptoTrading=8081) and walk up until we find one nothing is listening on.
  PORT=8080
  while ssh "$TARGET" "ss -tlnp 2>/dev/null | grep -q \":$PORT \""; do
    PORT=$((PORT + 1))
  done
  warn "No port given — auto-selected $PORT (first free port from 8080). Pass a port explicitly to override."
fi
info "Using port $PORT"

section "Tailscale HTTPS certificate"
ssh "$TARGET" "tailscale cert --cert-file $APP_DIR/certs/cert.pem --key-file $APP_DIR/certs/key.pem $TS_HOSTNAME && chmod 600 $APP_DIR/certs/key.pem"
info "Certificate issued for $TS_HOSTNAME"

section "Systemd service"
ssh "$TARGET" "cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Doug's AIShortTrading dashboard and trading engine
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python3 -m uvicorn web.app:app --host 0.0.0.0 --port $PORT --ssl-certfile $APP_DIR/certs/cert.pem --ssl-keyfile $APP_DIR/certs/key.pem
EnvironmentFile=$APP_DIR/.env
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}"
info "Systemd service installed and enabled"

section "Certificate auto-renewal"
ssh "$TARGET" "cat > $APP_DIR/renew_cert.sh << EOF
#!/bin/bash
# Renews the Tailscale HTTPS cert and restarts ${SERVICE_NAME} to pick it up.
# Scheduled for Sunday 07:15 UTC (~3 AM ET) -- always market-closed, safe to
# restart unconditionally. Cert is valid ~90 days; weekly renewal gives a
# large safety margin.
set -e
tailscale cert --cert-file $APP_DIR/certs/cert.pem --key-file $APP_DIR/certs/key.pem $TS_HOSTNAME
chmod 600 $APP_DIR/certs/key.pem
systemctl restart ${SERVICE_NAME}
EOF
chmod +x $APP_DIR/renew_cert.sh
(crontab -l 2>/dev/null | grep -v ${SERVICE_NAME}_cert_renew; echo \"15 7 * * 0 $APP_DIR/renew_cert.sh >> /var/log/${SERVICE_NAME}_cert_renew.log 2>&1\") | crontab -"
info "Weekly cert renewal scheduled (Sunday 07:15 UTC)"

section "VERSION file"
ssh "$TARGET" "cat $APP_DIR/VERSION 2>/dev/null || echo 'v0.0.0' > $APP_DIR/VERSION"

section "Start the service"
ssh "$TARGET" "systemctl restart ${SERVICE_NAME}"
sleep 5
if ssh "$TARGET" "systemctl is-active --quiet ${SERVICE_NAME}"; then
  info "${SERVICE_NAME} is RUNNING"
else
  warn "Service did not come up — check logs: ssh $TARGET journalctl -u ${SERVICE_NAME} -f"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  AIShortTrading deployed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Dashboard:    https://${TS_HOSTNAME}:${PORT}/"
echo "  App dir:      $APP_DIR (on $TARGET)"
echo "  Credentials:  $APP_DIR/.env (on $TARGET)"
echo "  Logs:         ssh $TARGET journalctl -u ${SERVICE_NAME} -f"
echo "  Restart:      ssh $TARGET systemctl restart ${SERVICE_NAME}"
echo ""
echo "  To ship a later code change, either re-run this script (it will rsync"
echo "  fresh code and skip the venv/.env/cert/systemd steps that already"
echo "  exist), or cut a release (scripts/cut_release.sh) and use the"
echo "  dashboard's own Apply Update button, per this project's normal workflow."
