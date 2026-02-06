#!/bin/sh
set -euo pipefail

trap 'err=$?; /app/send_telegram.sh "❌ Backup script error (exit $err) at $(date)"' ERR

DOCKER_CONTAINER=${DOCKER_CONTAINER:-supabase-db}
POSTGRES_USER=${POSTGRES_USER:-supabase_admin}
DATABASE_NAME=${DATABASE_NAME:-postgres}

DATE_DIR=$(date +%Y-%m-%d)
TIMESTAMP=$(date +"%H-%M-%p")
BACKUP_FILENAME="supabase-${DATABASE_NAME}-${DATE_DIR}_${TIMESTAMP}.sql"
BACKUP_GZ="${BACKUP_FILENAME}.gz"

LOCAL_BACKUP_DIR="/app/backup"
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_GZ}"

mkdir -p "${LOCAL_BACKUP_DIR}"

TMPFILE="/tmp/${BACKUP_FILENAME}"

echo "Creating pg_dump inside container..."
docker exec "${DOCKER_CONTAINER}" sh -c "
  /usr/bin/pg_dump -U ${POSTGRES_USER} --clean --if-exists ${DATABASE_NAME} > ${TMPFILE}
"

echo "Copying dump out of container..."
docker cp "${DOCKER_CONTAINER}:${TMPFILE}" "${LOCAL_BACKUP_DIR}/${BACKUP_FILENAME}"

echo "Removing temp file inside container..."
docker exec "${DOCKER_CONTAINER}" rm -f "${TMPFILE}"

echo "Compressing..."
gzip -f "${LOCAL_BACKUP_DIR}/${BACKUP_FILENAME}"

# Validate gzip
gzip -t "${LOCAL_BACKUP_PATH}"

# Validate non-empty
if [ ! -s "${LOCAL_BACKUP_PATH}" ]; then
  /app/send_telegram.sh "❌ Backup file is empty, aborting"
  exit 1
fi

echo "Uploading via rclone..."
docker exec supabase-rclone rclone --config /config/rclone/rclone.conf \
  copy "/backup/${BACKUP_GZ}" "dropbox:SupabaseServerBackups/${DATE_DIR}"

/app/send_telegram.sh "✅ Backup complete: ${LOCAL_BACKUP_PATH}"
