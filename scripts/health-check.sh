#!/bin/bash
# scripts/health-check.sh
# Runs ON the app EC2 to verify the app is healthy

set -euo pipefail

HOST="http://localhost:8080"
MAX_RETRIES=3
RETRY_DELAY=2

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

check_endpoint() {
  local path="$1"
  local expected_key="$2"
  local url="$HOST$path"

  log "Checking $url ..."
  response=$(curl -sf --max-time 5 "$url" 2>/dev/null) || {
    log "ERROR: $url did not respond"
    return 1
  }

  if echo "$response" | grep -q "\"$expected_key\""; then
    log "OK: $url — found '$expected_key' in response"
    return 0
  else
    log "ERROR: $url — '$expected_key' not found in response"
    log "Response was: $response"
    return 1
  fi
}

# ── Retry loop ────────────────────────────────────────────────────────────────
for attempt in $(seq 1 $MAX_RETRIES); do
  log "Health check attempt $attempt/$MAX_RETRIES"

  if check_endpoint "/health" "healthy" && \
     check_endpoint "/" "message" && \
     check_endpoint "/info" "version"; then
    log "All health checks passed"
    exit 0
  fi

  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    log "Retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
  fi
done

log "Health check FAILED after $MAX_RETRIES attempts"
log "Last 20 lines of app logs:"
sudo journalctl -u myapp --no-pager -n 20 2>/dev/null || true
exit 1
