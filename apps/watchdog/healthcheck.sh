#!/bin/sh
set -eu

MODE="${1:-loop}"

check_docker_services() {
  alert=0

  # Get all containers JSON
  containers=$(curl -s --unix-socket /var/run/docker.sock http://localhost/containers/json || echo "")

  if [ -z "$containers" ]; then
    /app/send_telegram.sh "❌ Docker API error at $(date)"
    return 1
  fi

  # Loop over IDs
  for cid in $(echo "$containers" | grep -o '"Id":"[^"]*"' | cut -d'"' -f4); do
    info=$(curl -s --unix-socket /var/run/docker.sock http://localhost/containers/$cid/json || echo "")

    if [ -z "$info" ]; then
      /app/send_telegram.sh "❌ Failed to inspect container $cid at $(date)"
      alert=1
      continue
    fi

    # Extract container name
    name=$(echo "$info" | grep -o '"Name":"[^"]*"' | head -n1 | cut -d'"' -f4 | sed 's|/||')

    # Extract state status (running, exited, etc.)
    state=$(echo "$info" | grep -o '"Status":"[^"]*"' | head -n1 | cut -d'"' -f4)

    # Extract health status if present
    health=$(echo "$info" | grep -o '"Health":{"Status":"[^"]*"' | head -n1 | cut -d'"' -f6 || echo "")

    # Report container state
    case "$state" in
      running) ;; # check health below
      exited|dead|created|paused)
        /app/send_telegram.sh "🛑 Container $name is $state at $(date)"
        alert=1
        ;;
    esac

    # Report health status
    case "$health" in
      healthy) ;; # all good
      unhealthy)
        /app/send_telegram.sh "⚠️ Container $name health check failed at $(date)"
        alert=1
        ;;
      starting)
        /app/send_telegram.sh "⏳ Container $name health check still starting at $(date)"
        ;;
    esac
  done

  return $alert
}

check_telegram() {
  resp=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="✅ Watchdog healthcheck ping at $(date)")
  echo "$resp" | grep -q '"ok":true'
}

if [ "$MODE" = "docker+telegram" ]; then
  check_docker_services && check_telegram
  exit $?
fi

# Default: continuous loop every 20s
while true; do
  check_docker_services
  sleep 20
done