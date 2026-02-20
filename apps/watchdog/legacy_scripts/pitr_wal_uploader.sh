#!/bin/sh
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
WAL_DIR="${WAL_DIR:-/wal_archive}"
PENDING_DIR="${PENDING_DIR:-/wal_archive_pending}"

REMOTE_ROOT="${REMOTE_ROOT:-dropbox:SupabaseServerBackups_WAL}"

RCLONE_CONTAINER="${RCLONE_CONTAINER:-supabase-rclone}"
RCLONE_CONFIG_PATH="${RCLONE_CONFIG_PATH:-/config/rclone/rclone.conf}"

MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_SLEEP_SECONDS="${RETRY_SLEEP_SECONDS:-5}"
PENDING_BATCH_INTERVAL_SECONDS="${PENDING_BATCH_INTERVAL_SECONDS:-60}"

LOG_PREFIX="${LOG_PREFIX:-[PITR_WAL]}"

# -----------------------------
# Helpers
# -----------------------------
log() {
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "${LOG_PREFIX} ${ts} $*"
}

remote_wal_dir() {
  DATE_DIR="$(date -u +%Y-%m-%d)"
  echo "${REMOTE_ROOT}/${DATE_DIR}/WAL"
}

rclone_copy_dir() {
  local src_dir="$1"
  local dest_remote
  dest_remote="$(remote_wal_dir)"

  log "Batch uploading directory ${src_dir} to ${dest_remote}"

  docker exec "${RCLONE_CONTAINER}" rclone --config "${RCLONE_CONFIG_PATH}" \
    copy "${src_dir}/" "${dest_remote}"
}

rclone_copy_file() {
  local src_file="$1"
  local dest_remote_file="$2"

  docker exec "${RCLONE_CONTAINER}" rclone --config "${RCLONE_CONFIG_PATH}" \
    copyto "${src_file}" "${dest_remote_file}"
}

dir_is_empty() {
  local d="$1"
  [ -d "$d" ] && [ -z "$(ls -A "$d" 2>/dev/null || true)" ]
}

# -----------------------------
# Startup batch upload
# -----------------------------
startup_batch_upload() {
  if [ ! -d "${WAL_DIR}" ]; then
    log "WAL directory ${WAL_DIR} does not exist; creating it"
    mkdir -p "${WAL_DIR}"
  fi

  if dir_is_empty "${WAL_DIR}"; then
    log "Startup: no existing WAL files in ${WAL_DIR}; skipping batch upload"
    return 0
  fi

  log "Startup: found existing WAL files in ${WAL_DIR}; starting batch upload"

  local attempt=1
  while [ "${attempt}" -le "${MAX_RETRIES}" ]; do
    if rclone_copy_dir "${WAL_DIR}"; then
      log "Startup: batch upload successful; removing local WAL files from ${WAL_DIR}"
      rm -f "${WAL_DIR}/"*
      return 0
    fi

    log "Startup: batch upload attempt ${attempt}/${MAX_RETRIES} failed; retrying in ${RETRY_SLEEP_SECONDS}s"
    attempt=$((attempt + 1))
    sleep "${RETRY_SLEEP_SECONDS}"
  done

  log "Startup: batch upload FAILED after ${MAX_RETRIES} attempts; leaving WAL files in place"
  return 1
}

# -----------------------------
# Per-file upload (live mode)
# -----------------------------
upload_one_wal() {
  local fname="$1"
  local src="${WAL_DIR}/${fname}"

  if [ ! -f "${src}" ]; then
    log "File disappeared before upload, skipping: ${fname}"
    return 0
  fi

  local dest_remote
  dest_remote="$(remote_wal_dir)"
  local dest_file="${dest_remote}/${fname}"

  log "Uploading WAL ${fname} to ${dest_remote}"

  local attempt=1
  while [ "${attempt}" -le "${MAX_RETRIES}" ]; do
    if rclone_copy_file "${src}" "${dest_file}"; then
      rm -f "${src}"
      log "Uploaded and removed ${fname}"
      return 0
    fi

    log "Upload attempt ${attempt}/${MAX_RETRIES} failed for ${fname}; retrying in ${RETRY_SLEEP_SECONDS}s"
    attempt=$((attempt + 1))
    sleep "${RETRY_SLEEP_SECONDS}"
  done

  log "ERROR: Failed to upload ${fname} after ${MAX_RETRIES} attempts; moving to pending"
  mkdir -p "${PENDING_DIR}"
  mv "${src}" "${PENDING_DIR}/${fname}"
}

# -----------------------------
# Pending batch uploader
# -----------------------------
batch_pending_loop() {
  mkdir -p "${PENDING_DIR}"

  while true; do
    if ! dir_is_empty "${PENDING_DIR}"; then
      log "Pending: found files in ${PENDING_DIR}; attempting batch upload"

      local attempt=1
      while [ "${attempt}" -le "${MAX_RETRIES}" ]; do
        if rclone_copy_dir "${PENDING_DIR}"; then
          log "Pending: batch upload successful; removing local pending WAL files"
          rm -f "${PENDING_DIR}/"*
          break
        fi

        log "Pending: batch upload attempt ${attempt}/${MAX_RETRIES} failed; retrying in ${RETRY_SLEEP_SECONDS}s"
        attempt=$((attempt + 1))
        sleep "${RETRY_SLEEP_SECONDS}"
      done

      if [ "${attempt}" -gt "${MAX_RETRIES}" ]; then
        log "Pending: batch upload FAILED after ${MAX_RETRIES} attempts; will retry after ${PENDING_BATCH_INTERVAL_SECONDS}s"
      fi
    fi

    sleep "${PENDING_BATCH_INTERVAL_SECONDS}"
  done
}

# -----------------------------
# Live watch loop
# -----------------------------
live_watch() {
  if [ ! -d "${WAL_DIR}" ]; then
    log "WAL directory ${WAL_DIR} does not exist; creating it"
    mkdir -p "${WAL_DIR}"
  fi

  log "Startup batch complete; entering live watch mode on ${WAL_DIR}"

  inotifywait -m -e close_write --format '%f' "${WAL_DIR}" | while read -r fname; do
    # Fire-and-forget per-file upload
    upload_one_wal "${fname}" &
  done
}

# -----------------------------
# Main
# -----------------------------
log "Startup: scanning ${WAL_DIR} for existing WAL files"
startup_batch_upload

log "Starting pending batch uploader loop"
batch_pending_loop &

live_watch
