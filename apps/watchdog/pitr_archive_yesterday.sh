#!/bin/sh
set -euo pipefail

YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
BASE_NAME="supabase-${YESTERDAY}_base"
BASE_DIR="/app/pitr/${BASE_NAME}"
WAL_DIR="${BASE_DIR}/WAL"
ARCHIVE="${BASE_DIR}/WAL_archive.sql.gz"
REMOTE_ROOT="dropbox:SupabaseServerBackups_WAL/${YESTERDAY}"

if [ -d "${WAL_DIR}" ]; then
  echo "Archiving WAL for ${YESTERDAY}..."
  tar -czf "${ARCHIVE}" -C "${BASE_DIR}" WAL

  echo "Uploading WAL archive..."
  docker exec supabase-rclone rclone --config /config/rclone/rclone.conf \
    copy "${ARCHIVE}" "${REMOTE_ROOT}"

  echo "Cleaning up..."
  rm -rf "${WAL_DIR}"
fi
