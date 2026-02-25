#!/bin/sh
set -e

# Start Bifrost in background (listens on localhost:8080, not exposed externally)
/app/bifrost -host 127.0.0.1 -port 8080 &

# Start Caddy in foreground (main process, keeps container alive)
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
