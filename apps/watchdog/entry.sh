#!/bin/sh
set -eu

# Send startup notification
/app/send_telegram.sh "🤖 Watchdog bot online at $(date)"

# Start log watcher in background
/app/logwatch.sh &

# Start disk watcher in background (immediate startup alert happens inside the script)
/app/diskwatch.sh &

# Start Redis listener for on-demand cleanup requests
/app/redis-listener.sh &

# Start PGMQ worker to forward DB events to Telegram
/app/pgmq-worker.sh &

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