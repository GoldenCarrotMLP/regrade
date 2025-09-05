#!/bin/bash

# ==============================================================================
# Supabase Self-Hosted PostgreSQL Backup Script
# Single-database backup using pg_dump instead of pg_dumpall
# ==============================================================================

# --- Configuration Variables ---
DOCKER_CONTAINER="supabase-db"
POSTGRES_USER="postgres"
POSTGRES_DB="postgres"   # <-- change if your app uses a different DB
RCLONE_REMOTE="dropbox"
RCLONE_BASE_DIR="SupabaseServerBackups"

# Path to rclone config (root user via cron)
export RCLONE_CONFIG="/root/.config/rclone/rclone.conf"

# Age of backups to keep
BACKUP_AGE_TO_KEEP="7d"

# --- Script Execution ---

# 1. Generate timestamp and file paths
DATE_DIR=$(date +%Y-%m-%d)
TIMESTAMP=$(date +"%H-%M-%p")
BACKUP_FILENAME="supabase-${POSTGRES_DB}-backup-${DATE_DIR}_${TIMESTAMP}.sql.gz"

LOCAL_BACKUP_DIR="/home/anderson/regrade"
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/backup/${BACKUP_FILENAME}"
RCLONE_FULL_PATH="${RCLONE_REMOTE}:${RCLONE_BASE_DIR}/${DATE_DIR}"

echo "Starting Supabase database backup..."
echo "Local backup file: ${LOCAL_BACKUP_PATH}"
echo "Remote destination: ${RCLONE_FULL_PATH}"

# 2. Ensure local backup directory exists
mkdir -p "${LOCAL_BACKUP_DIR}/backup"

# 3. Create the backup file (single DB)
echo "Creating database dump for '${POSTGRES_DB}'..."
sudo docker exec "${DOCKER_CONTAINER}" \
  pg_dump -v -U "${POSTGRES_USER}" "${POSTGRES_DB}" \
  | gzip > "${LOCAL_BACKUP_PATH}"

if [ $? -eq 0 ]; then
    echo "Backup created successfully."
else
    echo "Error: Backup failed. Aborting."
    exit 1
fi

# 4. Upload the backup to Dropbox
echo "Uploading backup to Dropbox..."
rclone copy "${LOCAL_BACKUP_PATH}" "${RCLONE_FULL_PATH}"

if [ $? -eq 0 ]; then
    echo "Upload completed successfully."
else
    echo "Error: Upload failed. Aborting."
    exit 1
fi

# 5. Clean up old backups from the remote
echo "Removing backups older than ${BACKUP_AGE_TO_KEEP} from the remote..."
rclone delete --min-age "${BACKUP_AGE_TO_KEEP}" "${RCLONE_REMOTE}:${RCLONE_BASE_DIR}"
rclone rmdirs "${RCLONE_REMOTE}:${RCLONE_BASE_DIR}"

# 6. Remove local temp file
rm "${LOCAL_BACKUP_PATH}"
echo "Local temporary file removed."

echo "Backup, upload, and cleanup process complete."