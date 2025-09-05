#!/bin/bash

# ==============================================================================
# Project Setup & Restore Script (Gold Standard)
# - Orchestrates a GitHub Action to securely fetch the latest database backup.
# - Interactively configures Nginx.
# - Deploys containers and restores the database.
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
DB_CONTAINER="supabase-db"
POSTGRES_USER="postgres"
POSTGRES_DB="postgres"
GITHUB_REPO="GoldenCarrotMLP/regrade" # IMPORTANT: Set this to your "owner/repo"
WORKFLOW_NAME="create-backup-artifact.yml"
ARTIFACT_NAME="latest-supabase-backup"

TEMP_DIR="./temp_setup"

# --- Helper Functions ---
function check_command() {
  if ! command -v $1 &> /dev/null; then return 1; else return 0; fi
}

function fetch_latest_backup_from_github() {
  echo "Triggering GitHub Action to fetch the latest backup. This may take a few minutes..."
  
  # Trigger the workflow and wait for it to be created
  gh workflow run $WORKFLOW_NAME --ref main
  
  # Give the API a moment to create the run
  echo "Waiting for the workflow run to appear on GitHub..."
  sleep 8
  
  # Get the ID of the most recent run for this workflow
  RUN_ID=$(gh run list --workflow="$WORKFLOW_NAME" -L 1 --json databaseId -q '.[0].databaseId')
  
  if [ -z "$RUN_ID" ]; then
    echo "Error: Could not find a recent workflow run. Please check the Actions tab on GitHub."
    exit 1
  fi
  
  echo "Waiting for workflow run (ID: $RUN_ID) to complete..."
  
  # Wait for the run to finish and check for its success
  gh run watch "$RUN_ID"
  
  echo "Workflow finished. Downloading backup artifact..."
  mkdir -p "$TEMP_DIR"
  
  # Download the artifact produced by the successful run
  gh run download "$RUN_ID" -n "$ARTIFACT_NAME" -D "$TEMP_DIR"
  
  if [ ! -f "$TEMP_DIR/latest_backup.sql.gz" ]; then
    echo "Error: Failed to download the backup artifact."
    exit 1
  fi

  echo "✅ Backup artifact downloaded successfully."
}


# --- Script Execution ---

echo "🚀 Starting Supabase project setup..."

# 1. Prerequisite Checks & GitHub Login
echo -e "\n1. Checking prerequisites..."
check_command "docker" || { echo "Error: docker not found."; exit 1; }
check_command "docker compose" || { echo "Error: docker compose not found. Please install it first."; exit 1; }
check_command "nginx" || { echo "Error: nginx not found."; exit 1; }
check_command "gh" || { echo "Error: GitHub CLI 'gh' not found. Please install it first."; exit 1; }
check_command "jq" || { echo "Error: 'jq' not found. Please install it (e.g., sudo apt install jq)."; exit 1; }

if ! gh auth status &> /dev/null; then
  echo "You are not logged into the GitHub CLI. A browser window will open for a one-time login."
  gh auth login
fi
echo "✅ All required tools are present and you are logged into GitHub."


# 2. Setup Environment File
echo -e "\n2. Checking for .env file..."
if [ ! -f ".env" ]; then
  if [ -f ".env.example" ]; then
    cp .env.example .env
    echo "✅ .env file created from .env.example."
    echo "‼️ IMPORTANT: Please review the .env file and fill in any required values."
  else
    echo "Error: .env.example not found. Cannot create .env file."
    exit 1
  fi
else
    echo "✅ .env file already exists. Skipping creation."
fi

# 3. Interactive Nginx Setup
echo -e "\n3. Nginx Configuration"
read -p "Do you want to configure Nginx automatically? (y/n): " nginx_choice
if [[ "${nginx_choice,,}" == "y" ]]; then
  if [ -d "config/nginx/sites-available" ]; then
    echo "Configuring Nginx... This will require sudo."
    
    # Copy all site configuration files.
    sudo cp -r ./config/nginx/sites-available/* /etc/nginx/sites-available/
    
    # Optional: Copy the main nginx.conf if it exists in your repo
    if [ -f "config/nginx/nginx.conf" ]; then
      sudo cp ./config/nginx/nginx.conf /etc/nginx/nginx.conf
    fi

    # Loop through all copied site configs and create symlinks to enable them
    echo "Enabling all copied sites..."
    for site_file in /etc/nginx/sites-available/*; do
      filename=$(basename "$site_file")
      sudo ln -sf "/etc/nginx/sites-available/$filename" "/etc/nginx/sites-enabled/$filename"
    done
    
    # Reload Nginx. A test is skipped as it may fail without SSL certificates.
    echo "Reloading Nginx service..."
    sudo systemctl reload nginx
    
    echo "✅ Nginx has been configured and reloaded."
    echo "‼️ SSL certificates will need to be generated in a final step."
  else
    echo "Warning: Directory 'config/nginx/sites-available' not found. Skipping Nginx setup."
  fi
else
  echo "Skipping Nginx configuration."
fi

# 4. Fetch the Database Backup
echo -e "\n4. Fetching the database backup via GitHub Actions..."
fetch_latest_backup_from_github # Call the new function
LOCAL_BACKUP_FILE="$TEMP_DIR/latest_backup.sql.gz"

# 5. Build containers and start the database
echo -e "\n5. Building images and starting the database container..."
docker compose up -d db

# 6. Wait for the database to be healthy
echo -e "\n6. Waiting for the database to accept connections..."
until docker exec "$DB_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q; do
  echo "Database is unavailable - sleeping for 2 seconds..."
  sleep 2
done
echo "✅ Database is ready."

# 7. Restore the database
echo -e "\n7. Restoring database from backup..."
gunzip < "$LOCAL_BACKUP_FILE" | docker exec -i "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
echo "✅ Database restored successfully."

# 8. Start all remaining services
echo -e "\n8. Starting all remaining project services..."
docker compose up -d

# 9. Cleanup
echo -e "\n9. Cleaning up temporary files..."
rm -rf "$TEMP_DIR"
echo "✅ Cleanup complete."

echo -e "\n🎉 Your Supabase environment is up and running!"
echo "If you configured Nginx, remember to run 'sudo certbot --nginx' to enable SSL."