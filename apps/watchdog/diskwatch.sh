#!/bin/sh
set -eu

DEVICE="/"
MIN_FREE_GB=100   # configurable baseline threshold

send_alert() {
  # Get available space in MB (BusyBox-friendly), convert to GB
  avail_mb=$(df -m "$DEVICE" | awk 'NR==2 {print $4}')
  avail_gb=$((avail_mb / 1024))
  used_pct=$(df -h "$DEVICE" | awk 'NR==2 {print $5}' | tr -d '%')

  # Free percentage relative to MIN_FREE_GB
  free_pct=$(( avail_gb * 100 / MIN_FREE_GB ))
  [ "$free_pct" -gt 100 ] && free_pct=100
  [ "$free_pct" -lt 0 ] && free_pct=0

  # Pick scarier message every 5% band
  case $free_pct in
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

  # Send message
  /app/send_telegram.sh "$msg"

  # Return interval in seconds (100% free → 3600s, 1% free → 60s)
  if [ "$free_pct" -gt 1 ]; then
    echo $(( (free_pct * 3540 / 99) + 60 ))
  else
    echo 60
  fi
}

# --- Startup immediate alert ---
interval=$(send_alert)

# --- Continuous loop ---
while true; do
  sleep "$interval"
  interval=$(send_alert)
done