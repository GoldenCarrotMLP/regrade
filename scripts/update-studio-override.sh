#!/usr/bin/env bash
set -euo pipefail

SUPABASE_ROOT="$HOME/supabase"
STUDIO_DIR="$SUPABASE_ROOT/apps/studio"
OVERRIDE_DIR="$HOME/regrade/apps/studio-override"

cd "$SUPABASE_ROOT"

# Get modified + untracked files
files=$(git status --porcelain | awk '{print $2}')

for f in $files; do
  # Only process files inside apps/studio
  if [[ "$f" == apps/studio/* ]]; then
    # Strip the leading apps/studio/ so we preserve relative paths
    rel="${f#apps/studio/}"
    src="$STUDIO_DIR/$rel"
    dest="$OVERRIDE_DIR/$rel"

    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "Copied $f -> $dest"
  fi
done