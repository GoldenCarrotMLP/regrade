#!/bin/sh
set -euo pipefail

DATE_DIR=$(date +%Y-%m-%d)
BASE_NAME="supabase-${DATE_DIR}_base"
BASE_DIR="/app/pitr/${BASE_NAME}"
REMOTE_ROOT="dropbox:SupabaseServerBackups_WAL/${DATE_DIR}"

mkdir -p "${BASE_DIR}"

echo "Taking base backup..."
docker exec supabase-db pg_basebackup \
  -U supabase_admin \
  -D /tmp/basebackup \
  -Ft -z -X none

echo "Copying base backup out..."
docker cp supabase-db:/tmp/basebackup/base.tar.gz "${BASE_DIR}/${BASE_NAME}.tar.gz"
docker exec supabase-db rm -rf /tmp/basebackup

echo "Uploading base backup..."
docker exec supabase-rclone rclone --config /config/rclone/rclone.conf \
  copy "${BASE_DIR}/${BASE_NAME}.tar.gz" "${REMOTE_ROOT}"
