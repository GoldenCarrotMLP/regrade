#!/bin/sh
set -eu

echo "[WATCHDOG] PGMQ worker online..." >&2

DB_CONTAINER="${DB_CONTAINER:-supabase-db}"
DB_USER="${DB_USER:-supabase_admin}"
DB_NAME="${DB_NAME:-postgres}"

read_queue() {
  queue="$1"

  #echo "[WATCHDOG] Reading queue: $queue" >&2

  docker exec "$DB_CONTAINER" \
    psql -U "$DB_USER" -d "$DB_NAME" -Atc \
      "select msg_id, message->>'message' as msg from pgmq.read('${queue}', 30, 50);" \
    2>/dev/null
}

delete_msg() {
  queue="$1"
  msg_id="$2"

  echo "[WATCHDOG] Deleting msg_id=$msg_id from $queue" >&2

  docker exec "$DB_CONTAINER" \
    psql -U "$DB_USER" -d "$DB_NAME" -Atc \
      "select pgmq.delete('${queue}', ${msg_id});" \
    >/dev/null 2>&1
}

while true; do
  for queue in "ticket_insert_events" "ticket_status_reset_events"; do

    #echo "[WATCHDOG] Polling queue: $queue" >&2

    read_queue "$queue" | while IFS="|" read -r msg_id message; do

      # Skip empty lines
      [ -z "$msg_id" ] && continue

      echo "[WATCHDOG] Found message:" >&2
      echo "  msg_id: $msg_id" >&2
      echo "  message: $message" >&2

      echo "[WATCHDOG] Publishing to Redis notify.telegram" >&2
      if redis-cli -h "$REDIS_HOST" PUBLISH notify.telegram "$message" >/dev/null 2>&1; then
        echo "[WATCHDOG] Redis publish OK — deleting message" >&2
        delete_msg "$queue" "$msg_id" || echo "[WATCHDOG] ERROR deleting msg_id=$msg_id" >&2
      else
        echo "[WATCHDOG] Redis publish FAILED — NOT deleting msg_id=$msg_id" >&2
      fi

    done

  done

  sleep 1
done
