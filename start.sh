#!/bin/sh
set -e

PORT="${APP_PORT:-10000}"

# Validate required env vars
for var in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY BIFROST_VIRTUAL_KEY BIFROST_ADMIN_USER BIFROST_ADMIN_PASS; do
  eval val=\$$var
  if [ -z "$val" ]; then
    echo "FATAL: $var is not set" >&2
    exit 1
  fi
done

# First boot: bind to LOCALHOST ONLY (not externally reachable)
APP_HOST=127.0.0.1 /app/docker-entrypoint.sh /app/main &
BIFROST_PID=$!
trap "kill $BIFROST_PID 2>/dev/null; exit 1" TERM INT

echo "Waiting for Bifrost to start..."
TRIES=0
until wget -qO /dev/null http://127.0.0.1:${PORT}/metrics 2>/dev/null; do
  TRIES=$((TRIES + 1))
  if [ $TRIES -ge 30 ]; then
    echo "FATAL: Bifrost failed to start after 30s" >&2
    exit 1
  fi
  sleep 1
done

# Enable governance + dashboard auth via API — MUST succeed or refuse to run
wget -qO- --method=PUT \
  --body-data="{\"client_config\": {\"enable_governance\": true, \"enforce_governance_header\": true, \"log_retention_days\": 7}, \"auth_config\": {\"is_enabled\": true, \"disable_auth_on_inference\": true, \"admin_username\": {\"value\": \"${BIFROST_ADMIN_USER}\"}, \"admin_password\": {\"value\": \"${BIFROST_ADMIN_PASS}\"}}}" \
  --header='Content-Type: application/json' \
  http://127.0.0.1:${PORT}/api/config >/dev/null 2>&1 || {
  echo "FATAL: Failed to enable governance/auth — refusing to run without protection" >&2
  kill $BIFROST_PID 2>/dev/null
  exit 1
}
echo "Governance + dashboard auth enabled, restarting..."

# Stop first boot
kill $BIFROST_PID 2>/dev/null
wait $BIFROST_PID 2>/dev/null || true
trap - TERM INT

# Second boot: bind to 0.0.0.0 (publicly reachable), governance is now active
exec /app/docker-entrypoint.sh /app/main
