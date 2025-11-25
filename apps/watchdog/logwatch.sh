#!/bin/sh
set -eu

DB_CONTAINER="supabase-db"
PATTERNS="invalid record length|could not read block|wal corruption|database files are incompatible|FATAL|PANIC"

# One-time startup notification
/app/send_telegram.sh "👀 [LOGWATCH] Watchdog is now polling database logs for corruption..."

while true; do
  LOGS="$(docker logs --tail 200 "$DB_CONTAINER" 2>&1 || true)"
  MATCHES="$(printf '%s' "$LOGS" | grep -iE "$PATTERNS" || true)"

  if [ -n "$MATCHES" ]; then
    echo "⚠️ [LOGWATCH] Detected match:"

    COLLAPSED="$(printf '%s\n' "$MATCHES" \
      | grep -v 'STATEMENT:' \
      | sed -E 's/.*FATAL:/FATAL:/; s/.*PANIC:/PANIC:/; s/.*invalid record length/invalid record length/; s/.*could not read block/could not read block/; s/.*database files are incompatible/database files are incompatible/; s/.*WAL corruption detected/WAL corruption detected/' \
      | awk '{counts[$0]++}
             END {
               for (m in counts) {
                 if (counts[m] > 1) {
                   print m "  (x" counts[m] ")\n"
                 } else {
                   print m "\n"
                 }
               }
             }')"

    echo "$COLLAPSED"

    /app/send_telegram.sh "🛑 [LOGWATCH] Database corruption detected at $(date -u)
    
$COLLAPSED"

  fi

  sleep 60
done
