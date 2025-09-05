#!/bin/bash
#
# This script backs up your custom Supabase Studio API files to a parallel
# directory, preserving the folder structure for easy patching later.

set -e # Exit immediately if a command fails.

# --- Configuration ---
# The source directory of your Supabase installation.
SOURCE_DIR="$HOME/supabase"
# The destination directory for your custom patch files.
DEST_DIR="$HOME/supabase-project"

# List of your modified files, relative to the SOURCE_DIR.
FILES_TO_BACKUP=(
  "apps/studio/components/layouts/ProjectLayout/NavigationBar/NavigationBar.utils.tsx"
  "apps/studio/pages/api/platform/projects/[ref]/content/index.ts"
  "apps/studio/pages/api/platform/projects/[ref]/content/count.ts"
  "apps/studio/pages/api/platform/projects/[ref]/content/item/[id].ts"
  "apps/studio/pages/api/platform/projects/[ref]/content/folders/index.ts"
)

# --- Main Logic ---

echo "Setting up backup directory at $DEST_DIR..."
mkdir -p "$DEST_DIR"

# We must change into the source directory for the --parents flag to work correctly.
cd "$SOURCE_DIR" || exit

echo "Backing up modified files..."

for file in "${FILES_TO_BACKUP[@]}"; do
  # The --parents flag automatically creates the directory structure in the destination.
  cp --parents "$file" "$DEST_DIR"
  echo "  - Copied $file"
done

echo ""
echo "✅ Backup complete!"
echo "Your modified files have been safely copied to $DEST_DIR"