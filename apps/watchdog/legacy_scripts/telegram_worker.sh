#!/bin/sh
set -u

# Queue name
QUEUE_KEY="telegram_msg_queue"

log() {
  echo "[TELEGRAM_WORKER] $*" >&2
}

log "Worker started. Monitoring Redis queue: $QUEUE_KEY"

while true; do
  # 1. Fetch message from Redis (LPOP)
  # We use a short sleep to prevent CPU spiking if queue is empty, 
  # strictly shell compatible without relying on blocking redis commands which can timeout awkwardly in scripts.
  MSG=$(redis-cli -h "$REDIS_HOST" LPOP "$QUEUE_KEY")

  if [ -z "$MSG" ] || [ "$MSG" = "nil" ]; then
    sleep 1
    continue
  fi

  log "Processing message..."

  # 2. Try to send to Telegram
  # We use -F (form-data) to handle special characters/newlines automatically without JSON escaping issues
  RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -F chat_id="${TELEGRAM_CHAT_ID}" \
    -F text="$MSG")

  # 3. Check for success
  if echo "$RESPONSE" | grep -q '"ok":true'; then
    log "Sent successfully."
  else
    log "Send failed. Response: $RESPONSE"
    log "Re-queueing message and sleeping for 10s..."
    
    # Push back to the HEAD of the queue (Left Push) so it's retried first
    redis-cli -h "$REDIS_HOST" LPUSH "$QUEUE_KEY" "$MSG" >/dev/null
    
    sleep 10
  fi
done