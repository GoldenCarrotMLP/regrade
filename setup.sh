#!/bin/bash

# ==============================================================================
# Project Setup & Restore Script
# Prepares a new environment: .env, Nginx, Docker containers, and database.
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
DB_CONTAINER="supabase-db"
POSTGS_USER="postgres"
POSTGRES_DB="postgres"
RCLONE_REMOTE="dropbox"
RCLONE_BASE_DIR="SupabaseServerBackups"

TEMP_BACKUP_DIR="./temp_backup"

# --- Helper Functions ---
function check_command() {
  if ! command -v $1 &> /dev/null; then
    echo "Error: Required command '$1' is not installed. Please install it before running this script."
    exit 1
  fi
}

# --- Script Execution ---

echo "🚀 Starting Supabase project setup..."

# 1. Check for Prerequisites
echo -e "\n1. Checking for required tools..."
check_command "docker"
check_command "docker-compose"
check_command "rclone"
check_command "nginx"
echo "✅ All tools are installed."

# 2. Setup Environment File
echo -e "\n2. Checking for .env file..."
if [ ! -f ".env" ]; then
  echo "No .env file found. Creating one from .env.example..."
  if [ -f ".env.example" ]; then
    cp .env.example .env
    echo "✅ .env file created successfully."
    echo "‼️ IMPORTANT: Please review the new .env file and fill in any required secrets or custom values."
  else
    echo "Error: .env.example not found! Cannot create the environment file. Aborting."
    exit 1
  fi
else
  echo "✅ .env file already exists. Skipping creation."
fi

# 3. Setup Nginx Configuration
echo -e "\n3. Setting up Nginx configuration..."
# Check for the directory that should contain site configs
if [ -d "config/nginx/sites-available" ]; then
  echo "Found Nginx 'sites-available' directory. This will require sudo."
  
  # Copy all site configuration files. The trailing slash on the source is important.
  sudo cp -r ./config/nginx/sites-available/* /etc/nginx/sites-available/
  
  # Optional: Copy the main nginx.conf if it exists in your repo
  if [ -f "config/nginx/nginx.conf" ]; then
    echo "Found main nginx.conf, copying to /etc/nginx/nginx.conf"
    sudo cp ./config/nginx/nginx.conf /etc/nginx/nginx.conf
  fi

  # Loop through all copied site configs and create symlinks to enable them
  echo "Enabling all copied sites..."
  for site_file in /etc/nginx/sites-available/*; do
    # Using basename to get just the filename
    filename=$(basename "$site_file")
    echo "  -> Enabling $filename"
    sudo ln -sf "/etc/nginx/sites-available/$filename" "/etc/nginx/sites-enabled/$filename"
  done

  # Test the Nginx configuration to ensure it's valid
  echo "Testing Nginx configuration..."
  sudo nginx -t
  
  # Reload Nginx to apply the new configuration
  echo "Reloading Nginx service..."
  sudo systemctl reload nginx
  
  echo "✅ Nginx has been configured and reloaded successfully."
else
  echo "Warning: Directory 'config/nginx/sites-available' not found. Skipping Nginx setup."
fi

# 4. Configure Rclone
echo -e "\n4. Configuring rclone..."
RCLONE_CONFIG_PATH="$PWD/temp_rclone.conf"

if [ -z "$RCLONE_CONFIG" ]; then
    echo "RCLONE_CONFIG environment variable not set."
    echo "Please go to your GitHub repository -> Settings -> Secrets and variables -> Actions."
    echo "Copy the content of the 'RCLONE_CONFIG' secret and paste it here, then press Enter:"
    read -r GITHUB_SECRET
    if [ -z "$GITHUB_SECRET" ]; then echo "Error: No secret pasted. Aborting."; exit 1; fi
    echo "$GITHUB_SECRET" > "$RCLONE_CONFIG_PATH"
else
    echo "Found RCLONE_CONFIG environment variable."
    echo "$RCLONE_CONFIG" > "$RCLONE_CONFIG_PATH"
fi
echo "✅ rclone configuration created temporarily."

# 5. Download the Latest Backup
echo -e "\n5. Finding and downloading the latest database backup..."
mkdir -p "$TEMP_BACKUP_DIR"
LATEST_BACKUP_PATH=$(rclone --config "$RCLONE_CONFIG_PATH" lsf --max-depth 3 -R --files-only "${RCLONE_REMOTE}:${RCLONE_BASE_DIR}" | sort -r | head -n 1)

if [ -z "$LATEST_BACKUP_PATH" ]; then
    echo "Error: No backup files found. Aborting."
    rm -rf "$TEMP_BACKUP_DIR" "$RCLONE_CONFIG_PATH"; exit 1
fi

echo "Latest backup found: $LATEST_BACKUP_PATH"
LOCAL_BACKUP_FILE="$TEMP_BACKUP_DIR/latest.sql.gz"
rclone --config "$RCLONE_CONFIG_PATH" copyto "${RCLONE_REMOTE}:${LATEST_BACKUP_PATH}" "$LOCAL_BACKUP_FILE"
echo "✅ Backup downloaded successfully."

# 6. Build containers and start the database
echo -e "\n6. Building images and starting the database container..."
docker-compose pull
docker-compose build web
docker-compose up -d db
echo "✅ Database container started."

# 7. Wait for the database to be healthy
echo -e "\n7. Waiting for the database to accept connections..."
until docker exec "$DB_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q; do
  echo "Database is unavailable - sleeping for 2 seconds..."
  sleep 2
done
echo "✅ Database is ready."

# 8. Restore the database
echo -e "\n8. Restoring database from backup..."
gunzip < "$LOCAL_BACKUP_FILE" | docker exec -i "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
echo "✅ Database restored successfully."

# 9. Start all remaining services
echo -e "\n9. Starting all remaining project services..."
docker-compose up -d
echo "✅ All services are running."

# 10. Cleanup
echo -e "\n10. Cleaning up temporary files..."
rm -rf "$TEMP_BACKUP_DIR" "$RCLONE_CONFIG_PATH"
echo "✅ Cleanup complete."

echo -e "\n🎉 Your Supabase environment is up and running!"
echo "Check your Nginx config for the public URL."