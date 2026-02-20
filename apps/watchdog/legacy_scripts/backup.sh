#!/bin/sh
set -euo pipefail

trap 'err=$?; /app/send_telegram.sh "?? Backup script error (exit $err) at $(date)"' ERR

DOCKER_CONTAINER=${DOCKER_CONTAINER:-supabase-db}
POSTGRES_USER=${POSTGRES_USER:-supabase_admin}
DATABASE_NAME=${DATABASE_NAME:-postgres}

DATE_DIR=$(date +%Y-%m-%d)
TIMESTAMP=$(date +"%H-%M-%p")
BACKUP_FILENAME="supabase-${DATABASE_NAME}-${DATE_DIR}_${TIMESTAMP}.sql"
BACKUP_GZ="${BACKUP_FILENAME}.gz"

LOCAL_BACKUP_DIR="/app/backup"
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_GZ}"
REMOTE_PATH="dropbox:SupabaseServerBackups/${DATE_DIR}"

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
  /app/send_telegram.sh "? Backup file is empty, aborting"
  exit 1
fi

echo "Uploading via rclone..."
docker exec supabase-rclone rclone --config /config/rclone/rclone.conf \
  copy "/backup/${BACKUP_GZ}" "${REMOTE_PATH}"

# --- VERIFICATION PHASE ---
echo "Verifying upload..."

MAX_RETRIES=3
VERIFIED=0

for i in $(seq 1 $MAX_RETRIES); do
  # Check if specific file exists on remote
  # rclone lsf returns the filename if it exists, nothing if not
  CHECK=$(docker exec supabase-rclone rclone --config /config/rclone/rclone.conf \
    lsf "${REMOTE_PATH}/${BACKUP_GZ}" || true)

  if [ "$CHECK" = "$BACKUP_GZ" ]; then
    echo "Verification successful."
    VERIFIED=1
    break
  fi

  echo "Verification attempt $i/$MAX_RETRIES failed. Retrying in 10s..."
  sleep 10
done

if [ "$VERIFIED" -eq 0 ]; then
  /app/send_telegram.sh "??? Backup upload FAILED verification after $MAX_RETRIES attempts. File: $BACKUP_GZ"
  exit 1
fi

# Success is now silent (no telegram message)
echo "Backup pipeline finished successfully."