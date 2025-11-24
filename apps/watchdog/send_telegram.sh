#!/bin/sh
set -eu

MESSAGE="$1"
DETAILS="${2:-}"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d text="$MESSAGE${DETAILS:+\n$DETAILS}"