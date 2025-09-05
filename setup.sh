#!/bin/bash

# ==============================================================================
# Project Setup & Restore Script (v4)
# - Interactively configures Nginx.
# - Automatically fetches secrets from GitHub.
# - Installs dependencies (Docker Compose, gh, jq).
# - Deploys containers and restores the latest database backup.
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
DB_CONTAINER="supabase-db"
POSTGRES_USER="postgres"
POSTGRES_DB="postgres"
RCLONE_REMOTE="dropbox"
RCLONE_BASE_DIR="SupabaseServerBackups"
GITHUB_REPO_URL="GoldenCarrotMLP/regrade" # IMPORTANT: Set this to your "owner/repo"

TEMP_BACKUP_DIR="./temp_backup"

# --- Helper Functions ---
function check_command() {
  if ! command -v $1 &> /dev/null; then
    return 1
  else
    return 0
  fi
}

function install_gh_cli() {
  echo "GitHub CLI 'gh' not found. Attempting to install..."
  if check_command "apt-get"; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt update
    sudo apt install -y gh
  else
    echo "Could not determine package manager. Please install the GitHub CLI 'gh' manually."
    exit 1
  fi
}

# --- Script Execution ---

echo "🚀 Starting Supabase project setup..."

# 1. Check for Prerequisites
echo -e "\n1. Checking for required tools..."
# Simple checks
check_command "docker" || { echo "Error: docker is not installed."; exit 1; }
check_command "nginx" || { echo "Error: nginx is not installed."; exit 1; }
check_command "rclone" || { echo "Error: rclone is not installed."; exit 1; }

# Install gh if missing
check_command "gh" || install_gh_cli
# Install jq if missing (needed for parsing API responses)
check_command "jq" || { echo "jq not found, installing..."; sudo apt-get install -y jq; }

# Install Docker Compose if missing
if ! docker compose version &> /dev/null; then
    echo "Docker Compose not found. Please install it as a Docker plugin first."
    exit 1
fi
echo "✅ All required tools are present."

# 2. Setup Environment File
# (Code from previous version - unchanged)
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

# 3. Interactive Nginx Setup
echo -e "\n3. Nginx Configuration"
read -p "Do you want to configure Nginx automatically? (y/n): " nginx_choice
if [[ "${nginx_choice,,}" == "y" ]]; then
  if [ -d "config/nginx/sites-available" ]; then
    echo "Configuring Nginx... This will require sudo."
    
    # Temporarily modify configs to allow HTTP validation
    # This prevents the "certificate not found" error on a fresh install
    echo "Temporarily modifying configs to allow HTTP validation..."
    sudo find ./config/nginx/sites-available -type f -exec sed -i -r 's/(^\s*listen\s+443\s+ssl.*)/#\1/g' {} +
    sudo find ./config/nginx/sites-available -type f -exec sed -i -r 's/(^\s*ssl_certificate.*)/#\1/g' {} +

    # Copy all site configuration files.
    sudo cp -r ./config/nginx/sites-available/* /etc/nginx/sites-available/
    
    # Optional: Copy the main nginx.conf
    if [ -f "config/nginx/nginx.conf" ]; then
      sudo cp ./config/nginx/nginx.conf /etc/nginx/nginx.conf
    fi

    # Enable all sites
    for site_file in /etc/nginx/sites-available/*; do
      filename=$(basename "$site_file")
      sudo ln -sf "/etc/nginx/sites-available/$filename" "/etc/nginx/sites-enabled/$filename"
    done
    
    # Test and reload Nginx with the temporary (HTTP-only) config
    echo "Testing and reloading Nginx with temporary config..."
    sudo nginx -t && sudo systemctl reload nginx
    
    echo "✅ Nginx is running. You should now generate SSL certificates."
    echo "Run 'sudo certbot --nginx' after the script finishes to secure your sites."
  else
    echo "Warning: Directory 'config/nginx/sites-available' not found. Skipping Nginx setup."
  fi
else
  echo "Skipping Nginx configuration."
fi

# 4. Configure Rclone via GitHub
echo -e "\n4. Configuring rclone..."
RCLONE_CONFIG_PATH="$PWD/temp_rclone.conf"

# Check auth status. If not logged in, prompt the user.
if ! gh auth status &> /dev/null; then
  echo "You are not logged into the GitHub CLI."
  echo "A browser window will open for you to authenticate. This is a one-time setup."
  gh auth login
fi

echo "Fetching rclone configuration from GitHub repository secrets..."
# Use gh api to get the secret, jq to parse the JSON and get the 'body'
RCLONE_SECRET_BODY=$(gh api repos/$GITHUB_REPO_URL/actions/secrets/RCLONE_CONFIG | jq -r .body)

if [ -z "$RCLONE_SECRET_BODY" ]; then
    echo "Error: Could not fetch 'RCLONE_CONFIG' secret from GitHub."
    echo "Please ensure you are logged in with 'gh auth login' and have access to the repo."
    exit 1
fi

echo "$RCLONE_SECRET_BODY" > "$RCLONE_CONFIG_PATH"
echo "✅ rclone configuration fetched and created temporarily."

# 5. Download the Latest Backup
echo -e "\n5. Finding and downloading the latest database backup..."
# ... (rest of the script is the same)
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
docker compose pull
docker compose build web
docker compose up -d db
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
docker compose up -d
echo "✅ All services are running."

# 10. Cleanup
echo -e "\n10. Cleaning up temporary files..."
rm -rf "$TEMP_BACKUP_DIR" "$RCLONE_CONFIG_PATH"
echo "✅ Cleanup complete."

echo -e "\n🎉 Your Supabase environment is up and running!"
echo "If you configured Nginx, remember to run 'sudo certbot --nginx' to enable SSL."