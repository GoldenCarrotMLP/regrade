#!/bin/bash  
set -e  
  
MAILBOX="${DMS_AUTO_MAILBOX}"  
PASSWORD="${DMS_AUTO_PASSWORD}"  
  
if [ -z "$MAILBOX" ] || [ -z "$PASSWORD" ]; then  
  echo "[init-mailbox] Missing env vars, skipping"  
  exit 0  
fi  
  
ACCOUNTS_FILE="/tmp/docker-mailserver/postfix-accounts.cf"  
  
# Check if accounts file exists  
if [ ! -f "$ACCOUNTS_FILE" ]; then  
  echo "[init-mailbox] Accounts file not found, creating mailbox: $MAILBOX"  
  /usr/local/bin/setup email add "$MAILBOX" "$PASSWORD"  
  exit 0  
fi  
  
# Check if mailbox already exists  
if ! grep -q "^$MAILBOX|" "$ACCOUNTS_FILE" 2>/dev/null; then  
  echo "[init-mailbox] Creating mailbox: $MAILBOX"  
  /usr/local/bin/setup email add "$MAILBOX" "$PASSWORD"  
else  
  echo "[init-mailbox] Mailbox already exists: $MAILBOX"  
fi