#!/bin/sh
set -eu

MODE="${1:-loop}"

check_docker_services() {
  alert=0

  # Get all containers JSON
  containers=$(curl -s --unix-socket /var/run/docker.sock http://localhost/containers/json)

  # Loop over IDs
for cid in $(echo "$containers" | grep -o '"Id":"[^"]*"' | cut -d'"' -f4); do
  info=$(curl -s --unix-socket /var/run/docker.sock http://localhost/containers/$cid/json)

  name=$(echo "$info" | grep -o '"Name":"[^"]*"' | cut -d'"' -f4 | sed 's|/||')
  state=$(echo "$info" | grep -o '"Status":"[^"]*"' | head -n1 | cut -d'"' -f4)
  health=$(echo "$info" | grep -o '"Health":{"Status":"[^"]*"' | cut -d'"' -f6 || echo "")

  case "$state" in
    running) ;; # check health below
    exited|dead|created|paused)
      echo "🛑 $name is $state"
      /app/send_telegram.sh "🛑 $name is $state at $(date)"
      ;;
  esac

  case "$health" in
    healthy) ;;
    unhealthy)
      echo "⚠️ $name is unhealthy"
      /app/send_telegram.sh "⚠️ $name is unhealthy at $(date)"
      ;;
    starting)
      echo "⏳ $name is starting"
      /app/send_telegram.sh "⏳ $name is starting at $(date)"
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

# Default: continuous loop every 5s
while true; do
  check_docker_services
  sleep 20
done