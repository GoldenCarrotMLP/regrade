#!/bin/sh
set -eu
set -o pipefail

# Global trap: catch any uncaught error
trap 'err=$?; /app/send_telegram.sh "❌ Backup script error (exit $err) at $(date)"' ERR

DOCKER_CONTAINER=${DOCKER_CONTAINER:-supabase-db}
POSTGRES_USER=${POSTGRES_USER:-supabase_admin}
DATABASE_NAME=${DATABASE_NAME:-postgres}

DATE_DIR=$(date +%Y-%m-%d)
TIMESTAMP=$(date +"%H-%M-%p")
BACKUP_FILENAME="supabase-${DATABASE_NAME}-${DATE_DIR}_${TIMESTAMP}.sql.gz"

LOCAL_BACKUP_DIR="/app/backup"
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_FILENAME}"

mkdir -p "${LOCAL_BACKUP_DIR}"

echo "Creating pg_dump..."
if ! docker exec "${DOCKER_CONTAINER}" \
    pg_dump -U "${POSTGRES_USER}" --clean --if-exists "${DATABASE_NAME}" \
    | gzip > "${LOCAL_BACKUP_PATH}"; then
    /app/send_telegram.sh "❌ Backup failed for ${DATABASE_NAME} at $(date)"
    exit 1
fi

# Sanity check: file must not be empty and must be valid gzip
if [ ! -s "${LOCAL_BACKUP_PATH}" ]; then
    /app/send_telegram.sh "❌ Backup file is empty, aborting"
    exit 1
fi

if ! gzip -t "${LOCAL_BACKUP_PATH}" 2>/dev/null; then
    /app/send_telegram.sh "❌ Backup file is corrupted or not valid gzip"
    exit 1
fi

echo "Uploading via rclone container..."
if ! docker exec supabase-rclone rclone --config /config/rclone/rclone.conf \
    copy "/backup/${BACKUP_FILENAME}" "dropbox:SupabaseServerBackups/${DATE_DIR}"; then
    /app/send_telegram.sh "⚠️ Upload failed for ${LOCAL_BACKUP_PATH}"
    exit 1
fi

/app/send_telegram.sh "✅ Backup complete: ${LOCAL_BACKUP_PATH}"