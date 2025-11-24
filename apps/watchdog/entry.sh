#!/bin/sh
set -eu

# Send startup notification
/app/send_telegram.sh "🤖 Watchdog bot online at $(date)"

# Trigger an immediate backup on startup
echo "Running initial backup..."
if ! /app/backup.sh; then
  /app/send_telegram.sh "❌ Initial backup failed at $(date)"
else
  /app/send_telegram.sh "✅ Initial backup completed at $(date)"
fi

# Start cron in background (it will read /etc/cron.d/watchdog automatically)
crond

# Start health monitoring loop in foreground
exec /app/healthcheck.sh