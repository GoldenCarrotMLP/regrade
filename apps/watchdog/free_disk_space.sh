#!/bin/sh
set -euo pipefail

LOCKFILE="/tmp/cleanup_busy"

log() {
  echo "[CLEANUP] $*"
}

notify() {
  /app/send_telegram.sh "$1" >/dev/null 2>&1 || true
}

# Prevent double-runs
if [ -f "$LOCKFILE" ]; then
  log "Cleanup already running, exiting."
  exit 0
fi

touch "$LOCKFILE"

# Mark busy in Redis
redis-cli -h "$REDIS_HOST" SET disk_cleanup_busy 1 >/dev/null 2>&1 || true

notify "🧹 Starting disk cleanup on host…"

log "Initial disk usage:"
df -h /

###############################################
# 1. Stop unused containers
###############################################
log "Stopping unused containers…"
docker container prune -f || true

###############################################
# 2. Remove unused images
###############################################
log "Removing unused images…"
docker image prune -a -f || true

###############################################
# 3. Remove unused networks
###############################################
log "Removing unused networks…"
docker network prune -f || true

###############################################
# 4. Remove unused volumes
###############################################
log "Removing unused volumes…"
docker volume prune -f || true

###############################################
# 5. Remove build cache
###############################################
log "Removing build cache…"
docker builder prune -a -f || true

###############################################
# 6. Remove orphaned overlay2 layers
###############################################
OVERLAY_DIR="/var/lib/docker/overlay2"
if [ -d "$OVERLAY_DIR" ]; then
  log "Cleaning orphaned overlay2 layers…"
  find "$OVERLAY_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \; || true
fi

###############################################
# 7. Remove dangling exited containers
###############################################
log "Removing dangling exited containers…"
docker ps -a --filter "status=exited" --format "{{.ID}}" | xargs -r docker rm -f || true

###############################################
# 8. Final disk usage
###############################################
log "Final disk usage:"
df -h /

notify "✅ Disk cleanup completed successfully."

# Clear busy state
rm -f "$LOCKFILE"
redis-cli -h "$REDIS_HOST" DEL disk_cleanup_busy >/dev/null 2>&1 || true

exit 0