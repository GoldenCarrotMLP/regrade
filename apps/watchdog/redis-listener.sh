#!/bin/sh
set -eu

echo "[WATCHDOG] Redis listener online..."

redis-cli -h "$REDIS_HOST" SUBSCRIBE disk.cleanup.request | while read -r line; do
  case "$line" in
    message)
      read -r channel
      read -r payload

      echo "[WATCHDOG] Received cleanup request"

      /app/free_disk_space.sh
      ;;
  esac
done