#!/bin/sh
set -e

# Start Bifrost in background (listens on localhost:8080, not exposed externally)
/app/bifrost -app-dir /app/data -port 8080 -host 127.0.0.1 -log-level info -log-style json &

# Start Caddy in foreground (main process, keeps container alive)
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
