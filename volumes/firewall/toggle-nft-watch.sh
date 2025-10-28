#!/bin/bash

WATCH_DIR="/home/anderson/regrade/volumes/firewall"
CMD="inotifywait -m -e close_write $WATCH_DIR"

# Look for an existing watcher process
PIDS=$(pgrep -f "$CMD")

if [ -n "$PIDS" ]; then
  echo "Watcher is running (PIDs: $PIDS). Stopping it..."
  kill $PIDS   # <-- note: no quotes, so it splits into separate args
else
  echo "Starting watcher on $WATCH_DIR..."
  nohup bash -c "$CMD | while read -r path action file; do
    echo \"[\$(date)] \$file changed, reloading nftables\"
    sudo nft -f /etc/nftables.conf
  done" >/tmp/nft-watch.log 2>&1 &
  echo "Watcher started (logging to /tmp/nft-watch.log)"
fi
