#!/bin/bash
# scripts/deploy.sh
# Runs ON the app EC2 after code is synced via rsync

set -euo pipefail

APP_DIR="/home/ec2-user/app"
VENV_DIR="/home/ec2-user/venv"
SERVICE_NAME="myapp"
LOG_FILE="/home/ec2-user/myapp-deploy.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "=== Deployment started ==="
log "Commit: ${GITHUB_SHA:-unknown}"
log "Environment: ${APP_ENV:-dev}"

# ── Create virtualenv if missing ─────────────────────────────────────────────
if [ ! -d "$VENV_DIR" ]; then
  log "Creating virtualenv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi

# ── Install dependencies ──────────────────────────────────────────────────────
log "Installing Python dependencies..."
source "$VENV_DIR/bin/activate"
pip install -r "$APP_DIR/requirements.txt" --quiet

# ── Write env file from secrets ───────────────────────────────────────────────
log "Writing environment config..."
cat > "$APP_DIR/.env" <<EOF
APP_ENV=${APP_ENV:-production}
APP_NAME=${APP_NAME:-my-app}
APP_VERSION=${APP_VERSION:-1.0.0}
PORT=${PORT:-8080}
EOF
chmod 600 "$APP_DIR/.env"

# ── Create systemd service if it doesn't exist ────────────────────────────────
if [ ! -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
  log "Creating systemd service: $SERVICE_NAME"
  sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF
[Unit]
Description=My Application
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=ec2-user
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
Environment=PATH=$VENV_DIR/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$VENV_DIR/bin/python app.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"
fi

# ── Restart the service ───────────────────────────────────────────────────────
log "Restarting $SERVICE_NAME..."
sudo systemctl restart "$SERVICE_NAME"

# ── Wait for service to come up ───────────────────────────────────────────────
log "Waiting for service to start..."
for i in {1..10}; do
  if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
    log "Service is up after ${i}s"
    break
  fi
  if [ "$i" -eq 10 ]; then
    log "ERROR: Service failed to start within 10s"
    sudo journalctl -u "$SERVICE_NAME" --no-pager -n 30
    exit 1
  fi
  sleep 1
done

log "=== Deployment complete ==="
sudo systemctl status "$SERVICE_NAME" --no-pager
