#!/bin/sh
set -eu

# Send startup notification
/app/send_telegram.sh "🤖 Watchdog bot online at $(date)"

# Start cron in background (it will read /etc/cron.d/watchdog automatically)
crond

# Start health monitoring loop in foreground
exec /app/healthcheck.sh