#!/bin/sh
set -e

PORT="${APP_PORT:-10000}"

# First boot: start Bifrost, enable governance, then restart
/app/docker-entrypoint.sh /app/main &
BIFROST_PID=$!

echo "Waiting for Bifrost to start..."
until wget -qO /dev/null http://127.0.0.1:${PORT}/metrics 2>/dev/null; do
  sleep 1
done

# Enable governance via API (requires restart to take effect)
wget -qO- --method=PUT \
  --body-data='{"client_config": {"enable_governance": true, "enforce_governance_header": true, "log_retention_days": 7}}' \
  --header='Content-Type: application/json' \
  http://127.0.0.1:${PORT}/api/config >/dev/null 2>&1 \
  && echo "Governance enabled, restarting..." \
  || echo "Warning: Failed to enable governance"

# Restart Bifrost so governance takes effect
kill $BIFROST_PID 2>/dev/null
wait $BIFROST_PID 2>/dev/null || true

# Second boot: governance is now in the DB, start in foreground
exec /app/docker-entrypoint.sh /app/main
