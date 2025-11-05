#!/bin/bash
set -euo pipefail

# --- Configuration ---
DOCKER_CONTAINER="supabase-db"
POSTGRES_USER="supabase_admin"
DATABASE_NAME="postgres"   # change if you want a different DB
RCLONE_REMOTE="dropbox"
RCLONE_BASE_DIR="SupabaseServerBackups"

export RCLONE_CONFIG="/root/.config/rclone/rclone.conf"

DATE_DIR=$(date +%Y-%m-%d)
TIMESTAMP=$(date +"%H-%M-%p")
BACKUP_FILENAME="supabase-${DATABASE_NAME}-${DATE_DIR}_${TIMESTAMP}.sql.gz"

LOCAL_BACKUP_DIR="/home/anderson/regrade/backup"
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_FILENAME}"
RCLONE_FULL_PATH="${RCLONE_REMOTE}:${RCLONE_BASE_DIR}/${DATE_DIR}"

mkdir -p "${LOCAL_BACKUP_DIR}"

echo "Creating pg_dump for database '${DATABASE_NAME}'..."
sudo docker exec "${DOCKER_CONTAINER}" \
  pg_dump -U "${POSTGRES_USER}" --clean --if-exists "${DATABASE_NAME}" \
  | gzip > "${LOCAL_BACKUP_PATH}"

echo "Uploading to remote..."
rclone copy "${LOCAL_BACKUP_PATH}" "${RCLONE_FULL_PATH}"

echo "Backup complete: ${LOCAL_BACKUP_PATH}"