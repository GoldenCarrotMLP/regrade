#!/bin/sh

# --- Check if docker compose is installed ---
if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
  echo "⚠️ Docker Compose not found. Installing..."

  sudo apt update
  sudo apt install -y ca-certificates curl gnupg

  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Add Docker's official repository
  . /etc/os-release
  echo \
"Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc" | sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null

  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# --- Ensure root mount is shared so rslave works ---
if ! findmnt -o PROPAGATION / | grep -q shared; then
  echo "⚠️ Root mount is not shared. Fixing..."
  sudo mount --make-rshared /
fi

TEMPLATE="/.env.example"
OUTPUT="/.env"

# --- Check if docker compose is installed ---
if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
  echo "⚠️ Docker Compose not found. Installing..."
  sudo apt update
  sudo apt install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo \
"Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc" | sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# --- Ensure root mount is shared so rslave works ---
if ! findmnt -o PROPAGATION / | grep -q shared; then
  echo "⚠️ Root mount is not shared. Fixing..."
  sudo mount --make-rshared /
fi

# Functions for secrets and JWTs
gen_secret() {
  head -c 64 /dev/urandom | base64 | tr -d '\n' | tr -d '=' | tr '/+' 'AB'
}

gen_jwt() {
  ROLE=$1
  SECRET=$2
  IAT=$(date +%s)
  EXP=$((IAT + 315360000)) # ~10 years validity
  HEADER='{"alg":"HS256","typ":"JWT"}'
  PAYLOAD="{\"role\":\"$ROLE\",\"iss\":\"supabase\",\"iat\":$IAT,\"exp\":$EXP}"
  HEADER_B64=$(printf '%s' "$HEADER" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  PAYLOAD_B64=$(printf '%s' "$PAYLOAD" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  DATA="$HEADER_B64.$PAYLOAD_B64"
  SIGNATURE=$(printf '%s' "$DATA" | openssl dgst -sha256 -hmac "$SECRET" -binary | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  echo "$DATA.$SIGNATURE"
}

# Prompts
echo "Do you have a domain? (leave blank for localhost): "
read DOMAIN
if [ -z "$DOMAIN" ]; then
  DOMAIN="localhost"
  SMTP_PASSWORD=$(gen_secret)
else
  echo "Enter SMTP password: "
  read SMTP_PASSWORD
fi

echo "Do you want to enable Telegram logging? (yes/no): "
read TELEGRAM_CHOICE
if [ "$TELEGRAM_CHOICE" = "yes" ]; then
  echo "Enter Telegram bot token: "
  read TELEGRAM_BOT_TOKEN
  echo "Enter Telegram chat id (numbers only): "
  read TELEGRAM_CHAT_ID
else
  TELEGRAM_BOT_TOKEN=""
  TELEGRAM_CHAT_ID=""
fi

echo "Enter dashboard username: "
read DASHBOARD_USERNAME
echo "Enter dashboard password: "
read DASHBOARD_PASSWORD

echo "Enter OpenAI API key (optional): "
read OPENAI_API_KEY
echo "Enter Gemini API key (optional): "
read GEMINI_API_KEY

# Generate secrets
POSTGRES_PASSWORD=$(gen_secret)
JWT_SECRET=$(gen_secret)
ANON_KEY=$(gen_jwt "anon" "$JWT_SECRET")
SERVICE_ROLE_KEY=$(gen_jwt "service_role" "$JWT_SECRET")
SECRET_KEY_BASE=$(gen_secret)
VAULT_ENC_KEY=$(gen_secret)
RCLONE_REMOTE="dropbox"

echo "Generating secrets and writing $OUTPUT..."

sed \
  -e "s/{POSTGRES_PASSWORD_PLACEHOLDER}/$POSTGRES_PASSWORD/" \
  -e "s/{JWT_SECRET_PLACEHOLDER}/$JWT_SECRET/" \
  -e "s/{ANON_KEY_PLACEHOLDER}/$ANON_KEY/" \
  -e "s/{SERVICE_ROLE_KEY_PLACEHOLDER}/$SERVICE_ROLE_KEY/" \
  -e "s/{DASHBOARD_USERNAME_PLACEHOLDER}/$DASHBOARD_USERNAME/" \
  -e "s/{DASHBOARD_PASSWORD_PLACEHOLDER}/$DASHBOARD_PASSWORD/" \
  -e "s/{SECRET_KEY_BASE_PLACEHOLDER}/$SECRET_KEY_BASE/" \
  -e "s/{VAULT_ENC_KEY_PLACEHOLDER}/$VAULT_ENC_KEY/" \
  -e "s/{SITE_URL_PLACEHOLDER || http:\/\/localhost:3000}/http:\/\/$DOMAIN:3000/" \
  -e "s/{API_EXTERNAL_URL_PLACEHOLDER || http:\/\/localhost:8000}/http:\/\/$DOMAIN:8000/" \
  -e "s/{DOMAIN_PLACEHOLDER || localhost}/$DOMAIN/" \
  -e "s/{SMTP_PASSWORD_PLACEHOLDER}/$SMTP_PASSWORD/" \
  -e "s/{OpenAI_API_KEY_PLACEHOLDER}/$OPENAI_API_KEY/" \
  -e "s/{GEMINI_API_KEY_PLACEHOLDER}/$GEMINI_API_KEY/" \
  -e "s/{TELEGRAM_BOT_TOKEN_PLACEHOLDER}/$TELEGRAM_BOT_TOKEN/" \
  -e "s/{TELEGRAM_CHAT_ID_PLACEHOLDER}/$TELEGRAM_CHAT_ID/" \
  -e "s/{RCLONE_REMOTE_PLACEHOLDER}/$RCLONE_REMOTE/" \
  "$TEMPLATE" > "$OUTPUT"

echo "✅ $OUTPUT generated"

# Run overrides and rclone setup
echo "Checking for platform overrides..."
scripts/platform-overrides.sh

echo "Do you want to set up rclone for backups? (yes/no): "
read RCLONE_CHOICE
if [ "$RCLONE_CHOICE" = "yes" ]; then
  scripts/rclone_setup.sh
else
  echo "Setup complete."
fi
