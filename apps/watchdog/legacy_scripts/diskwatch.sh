#!/bin/sh
set -eu

DEVICE="/"
MIN_FREE_GB=100

MAX_INTERVAL=$((1000 * 60))   # 1000 minutes in seconds
MIN_INTERVAL=60               # 1 minute

log() {
  echo "[DISKWATCH] $*" >&2
}

get_avail_gb() {
  line=$(df -m "$DEVICE" 2>/dev/null | awk 'NR==2 {print $4}')
  case "$line" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo $((line / 1024)) ;;
  esac
}

get_used_pct() {
  used=$(df -h "$DEVICE" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
  case "$used" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$used" ;;
  esac
}

pick_message() {
  free_pct="$1"
  avail_gb="$2"
  used_pct="$3"

  case "$free_pct" in
    9[5-9]|100) msg="⚠️ [DISKWATCH] Stable but shrinking — ${avail_gb}GB free (${used_pct}% used)." ;;
    9[0-4])     msg="🚨 [DISKWATCH] Danger zone — ${avail_gb}GB free (${used_pct}% used)." ;;
    8[5-9])     msg="🔥 [DISKWATCH] Critical — ${avail_gb}GB free (${used_pct}% used)." ;;
    8[0-4])     msg="💣 [DISKWATCH] Severe — ${avail_gb}GB free (${used_pct}% used)." ;;
    7[5-9])     msg="☠️ [DISKWATCH] Collapse approaching — ${avail_gb}GB free (${used_pct}% used)." ;;
    7[0-4])     msg="💀 [DISKWATCH] Disaster near — ${avail_gb}GB free (${used_pct}% used)." ;;
    6[5-9])     msg="🩸 [DISKWATCH] Catastrophic risk — ${avail_gb}GB free (${used_pct}% used)." ;;
    6[0-4])     msg="🕱 [DISKWATCH] Terminal — ${avail_gb}GB free (${used_pct}% used)." ;;
    5[5-9])     msg="🔥🔥 [DISKWATCH] Inferno — ${avail_gb}GB free (${used_pct}% used)." ;;
    5[0-4])     msg="⚡ [DISKWATCH] Collapse imminent — ${avail_gb}GB free (${used_pct}% used)." ;;
    4[5-9])     msg="☢️ [DISKWATCH] Meltdown risk — ${avail_gb}GB free (${used_pct}% used)." ;;
    4[0-4])     msg="🧨 [DISKWATCH] Explosion incoming — ${avail_gb}GB free (${used_pct}% used)." ;;
    3[5-9])     msg="🕳 [DISKWATCH] Abyss — ${avail_gb}GB free (${used_pct}% used)." ;;
    3[0-4])     msg="🪦 [DISKWATCH] Endgame — ${avail_gb}GB free (${used_pct}% used)." ;;
    2[5-9])     msg="🧟 [DISKWATCH] Zombie server — ${avail_gb}GB free (${used_pct}% used)." ;;
    2[0-4])     msg="🕷 [DISKWATCH] Nightmare — ${avail_gb}GB free (${used_pct}% used)." ;;
    1[5-9])     msg="🩹 [DISKWATCH] Last breaths — ${avail_gb}GB free (${used_pct}% used)." ;;
    1[0-4])     msg="💀 [DISKWATCH] FINAL WARNING — ${avail_gb}GB free (${used_pct}% used)." ;;
    *)          msg="💀 [DISKWATCH] TOTAL FAILURE — <1% of threshold free. Shutdown unavoidable." ;;
  esac

  echo "$msg"
}

compute_interval() {
  avail_gb="$1"

  # No alerts above threshold
  if [ "$avail_gb" -gt "$MIN_FREE_GB" ]; then
    echo 0
    return
  fi

  # Clamp below 1 GB
  if [ "$avail_gb" -le 1 ]; then
    echo "$MIN_INTERVAL"
    return
  fi

  # Linear interpolation
  interval=$(
    awk -v a="$avail_gb" -v min="$MIN_INTERVAL" -v max="$MAX_INTERVAL" -v thr="$MIN_FREE_GB" '
      BEGIN {
        interval = min + (a - 1) * (max - min) / (thr - 1)
        if (interval < min) interval = min
        if (interval > max) interval = max
        printf("%d", interval)
      }
    '
  )

  echo "$interval"
}

send_alert() {
  avail_gb=$(get_avail_gb)
  used_pct=$(get_used_pct)

  # Compute interval
  interval=$(compute_interval "$avail_gb")

  # If interval = 0 → above threshold → silent mode
  if [ "$interval" -eq 0 ]; then
    echo 0
    return
  fi

  # Compute free_pct for message selection
  free_pct=$(( avail_gb * 100 / MIN_FREE_GB ))
  [ "$free_pct" -gt 100 ] && free_pct=100
  [ "$free_pct" -lt 0 ] && free_pct=0

  msg=$(pick_message "$free_pct" "$avail_gb" "$used_pct")
  
  # --- FIX IS HERE: Redirect output to /dev/null ---
  /app/send_telegram.sh "$msg" >/dev/null 2>&1

  echo "$interval"
}

# --- Main loop ---
while true; do
  interval=$(send_alert)

  # Validate interval is a number before sleeping
  case "$interval" in
      ''|*[!0-9]*) 
          # If something goes wrong, default to 10 minutes to prevent crash loop
          log "Error computing interval, got: $interval. Defaulting to 600s."
          sleep 600 
          ;;
      *) 
          if [ "$interval" -eq 0 ]; then
            sleep 600
          else
            sleep "$interval"
          fi
          ;;
  esac
done