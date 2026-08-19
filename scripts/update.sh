#!/usr/bin/env bash
# Pull latest code from GitHub and restart AIShortTrading
# Run on the cloud server: bash /opt/aishorttrading/scripts/update.sh

set -euo pipefail
APP_DIR="/opt/aishorttrading"
SERVICE="aishorttrading"

echo "Pulling latest code..."
git -C "$APP_DIR" pull

echo "Updating dependencies..."
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" -q

echo "Restarting service..."
systemctl restart "$SERVICE"
sleep 2
systemctl is-active "$SERVICE" && echo "AIShortTrading restarted OK" || echo "ERROR: check journalctl -u $SERVICE"
