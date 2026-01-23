#!/bin/bash

# ==============================================================================
# Supabase Self-Hosted PostgreSQL Backup Script
# Single-database backup using pg_dump instead of pg_dumpall
# ==============================================================================

# --- Configuration Variables ---
DOCKER_CONTAINER="supabase-db"
POSTGRES_USER="postgres"
POSTGRES_DB="postgres"   # <-- change to the actual DB name you want to back up
RCLONE_REMOTE="Google-Backup"
RCLONE_BASE_DIR="SupabaseServerBackups"
CLEANUP_DAYS=14

# --- Script Execution ---

# 1. Generate timestamp and file paths
DATE_DIR=$(date +%Y-%m-%d)
TIMESTAMP=$(date +"%Y-%m-%d_%I-%M-%p")
BACKUP_FILENAME="supabase-${POSTGRES_DB}-backup-${TIMESTAMP}.sql.gz"

RCLONE_FULL_PATH="${RCLONE_REMOTE}:${RCLONE_BASE_DIR}/${DATE_DIR}"
RCLONE_FILE_PATH="${RCLONE_FULL_PATH}/${BACKUP_FILENAME}"

echo "Starting Supabase database backup..."
echo "Local backup file: ${BACKUP_FILENAME}"
echo "Remote destination: ${RCLONE_FULL_PATH}"

# 2. Create the backup file
# pg_dump just dumps the single database, not globals/roles
sudo docker exec -t "${DOCKER_CONTAINER}" \
  pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" \
  | gzip > "/tmp/${BACKUP_FILENAME}"

if [ $? -eq 0 ]; then
    echo "Backup created successfully."
else
    echo "Error: Backup failed. Aborting."
    exit 1
fi

# 3. Upload the backup to Google Drive using rclone
echo "Uploading backup to Google Drive..."
rclone copy "/tmp/${BACKUP_FILENAME}" "${RCLONE_FULL_PATH}"

if [ $? -eq 0 ]; then
    echo "Upload completed successfully."
else
    echo "Error: Upload failed. Aborting."
    exit 1
fi

# 4. Clean up local temporary backup file
rm "/tmp/${BACKUP_FILENAME}"
echo "Local temporary file removed."

# 5. Clean up old backups on Google Drive
echo "Checking for and deleting files older than ${CLEANUP_DAYS} days..."
rclone delete "${RCLONE_REMOTE}:${RCLONE_BASE_DIR}" --min-age "${CLEANUP_DAYS}d"

echo "Cleanup finished."
echo "Backup and upload process complete."