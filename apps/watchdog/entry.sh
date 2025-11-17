#!/bin/sh
set -eu

# Load cron schedule
crontab /etc/cron.d/watchdog

# Send startup notification
/app/send_telegram.sh "🤖 Watchdog bot online at $(date)"

# Start cron in background
crond

# Start health monitoring loop in foreground
exec /app/healthcheck.sh
