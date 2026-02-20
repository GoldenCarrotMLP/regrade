#!/bin/sh
set -eu

# Combine arguments
MESSAGE="$1"
DETAILS="${2:-}"

FULL_MSG="$MESSAGE"
if [ -n "$DETAILS" ]; then
  FULL_MSG="$MESSAGE

$DETAILS"
fi

# Push to the tail of the queue (Right Push)
# If Redis is down, we fallback to printing to stderr so logs capture it
if ! redis-cli -h "$REDIS_HOST" RPUSH "telegram_msg_queue" "$FULL_MSG" >/dev/null 2>&1; then
  echo "[ERROR] Redis unavailable. Could not queue Telegram message: $FULL_MSG" >&2
fi