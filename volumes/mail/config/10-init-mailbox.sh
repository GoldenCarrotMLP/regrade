#!/bin/bash
set -e

MAILBOX="${DMS_AUTO_MAILBOX}"
PASSWORD="${DMS_AUTO_PASSWORD}"

if [ -z "$MAILBOX" ] || [ -z "$PASSWORD" ]; then
  echo "[init-mailbox] Missing env vars, skipping"
  exit 0
fi

if ! grep -q "^$MAILBOX|" /tmp/docker-mailserver/postfix-accounts.cf 2>/dev/null; then
  echo "[init-mailbox] Creating mailbox: $MAILBOX"
  /usr/local/bin/setup email add "$MAILBOX" "$PASSWORD"
else
  echo "[init-mailbox] Mailbox already exists: $MAILBOX"
fi 