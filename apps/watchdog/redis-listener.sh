#!/bin/sh
set -eu

echo "[WATCHDOG] Redis listener online..."

# Listen to multiple channels
redis-cli -h "$REDIS_HOST" SUBSCRIBE disk.cleanup.request notify.telegram | while read -r line; do
  case "$line" in
    message)
      # Redis SUBSCRIBE protocol:
      # line 1: "message"
      # line 2: channel name
      # line 3: payload
      read -r channel
      read -r payload

      case "$channel" in

        disk.cleanup.request)
          echo "[WATCHDOG] Received cleanup request"
          /app/free_disk_space.sh
          ;;

        notify.telegram)
          echo "[WATCHDOG] Received telegram notification payload"
          /app/send_telegram.sh "$payload"
          ;;

      esac
      ;;
  esac
done