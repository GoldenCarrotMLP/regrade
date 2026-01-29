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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../.env.example"
OUTPUT="$SCRIPT_DIR/../.env"
HOSTS_OUTPUT="$SCRIPT_DIR/../hosts.txt"

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

# --- Domain Configuration ---
DOMAIN=""
while [ -z "$DOMAIN" ]; do
  echo "Enter your main domain name (e.g., myapp.com): "
  read DOMAIN
  if [ -z "$DOMAIN" ]; then
    echo "❌ Domain is required."
  fi
done

# Calculate Autofill Defaults
DEFAULT_DEV_DOMAIN="dev.$DOMAIN"
DEFAULT_AUTHELIA_DOMAIN="auth.$DOMAIN"
DEFAULT_API_DOMAIN="api.$DOMAIN"
DEFAULT_SMTP_HOST="mail.$DOMAIN"
DEFAULT_STUDIO_DOMAIN="studio.$DOMAIN"

echo ""
echo "-------------------------------------------------------"
echo "We can autofill the subdomains for you based on '$DOMAIN':"
echo "-------------------------------------------------------"
echo "DEV_DOMAIN             -> $DEFAULT_DEV_DOMAIN"
echo "AUTHELIA_DOMAIN        -> $DEFAULT_AUTHELIA_DOMAIN"
echo "API_DOMAIN             -> $DEFAULT_API_DOMAIN"
echo "SMTP_HOST              -> $DEFAULT_SMTP_HOST"
echo "SUPABASE_STUDIO_DOMAIN -> $DEFAULT_STUDIO_DOMAIN"
echo "-------------------------------------------------------"
echo "Do you want to use these values? (yes/no): "
read AUTOFILL_CHOICE

if [ "$AUTOFILL_CHOICE" = "yes" ] || [ "$AUTOFILL_CHOICE" = "y" ]; then
  DEV_DOMAIN=$DEFAULT_DEV_DOMAIN
  AUTHELIA_DOMAIN=$DEFAULT_AUTHELIA_DOMAIN
  API_DOMAIN=$DEFAULT_API_DOMAIN
  SMTP_HOST=$DEFAULT_SMTP_HOST
  SUPABASE_STUDIO_DOMAIN=$DEFAULT_STUDIO_DOMAIN
else
  echo "Enter DEV_DOMAIN (default: $DEFAULT_DEV_DOMAIN): "
  read INPUT
  DEV_DOMAIN=${INPUT:-$DEFAULT_DEV_DOMAIN}

  echo "Enter AUTHELIA_DOMAIN (default: $DEFAULT_AUTHELIA_DOMAIN): "
  read INPUT
  AUTHELIA_DOMAIN=${INPUT:-$DEFAULT_AUTHELIA_DOMAIN}

  echo "Enter API_DOMAIN (default: $DEFAULT_API_DOMAIN): "
  read INPUT
  API_DOMAIN=${INPUT:-$DEFAULT_API_DOMAIN}

  echo "Enter SMTP_HOST (default: $DEFAULT_SMTP_HOST): "
  read INPUT
  SMTP_HOST=${INPUT:-$DEFAULT_SMTP_HOST}

  echo "Enter SUPABASE_STUDIO_DOMAIN (default: $DEFAULT_STUDIO_DOMAIN): "
  read INPUT
  SUPABASE_STUDIO_DOMAIN=${INPUT:-$DEFAULT_STUDIO_DOMAIN}
fi

# Generate Additional Redirect URLs based on selections
ADDITIONAL_REDIRECT_URLS="https://$DEV_DOMAIN,https://$AUTHELIA_DOMAIN,https://$API_DOMAIN,https://$SUPABASE_STUDIO_DOMAIN,https://$DOMAIN"

# --- Other Configurations ---

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
DASHBOARD_EMAIL="admin@$DOMAIN" # Auto-generating email based on domain

echo "Enter OpenAI API key (optional): "
read OPENAI_API_KEY
echo "Enter Gemini API key (optional): "
read GEMINI_API_KEY

# Generate secrets
echo "Generating cryptographic secrets..."
POSTGRES_PASSWORD=$(gen_secret)
JWT_SECRET=$(gen_secret)
ANON_KEY=$(gen_jwt "anon" "$JWT_SECRET")
SERVICE_ROLE_KEY=$(gen_jwt "service_role" "$JWT_SECRET")
SECRET_KEY_BASE=$(gen_secret)
VAULT_ENC_KEY=$(gen_secret)

# Additional secrets found in .env.example
AUTHELIA_ENCRYPTION_KEY=$(gen_secret)
AUTHELIA_SESSION_SECRET=$(gen_secret)
LOGFLARE_PUBLIC_ACCESS_TOKEN=$(gen_secret)
LOGFLARE_PRIVATE_ACCESS_TOKEN=$(gen_secret)
SMTP_PASS=$(gen_secret) # Auto-generated as requested

RCLONE_REMOTE="dropbox"

echo "Writing configuration to $OUTPUT..."

# Using | as delimiter for sed to avoid issues with / in URLs
sed \
  -e "s|{POSTGRES_PASSWORD_PLACEHOLDER}|$POSTGRES_PASSWORD|" \
  -e "s|{JWT_SECRET_PLACEHOLDER}|$JWT_SECRET|" \
  -e "s|{ANON_KEY_PLACEHOLDER}|$ANON_KEY|" \
  -e "s|{SERVICE_ROLE_KEY_PLACEHOLDER}|$SERVICE_ROLE_KEY|" \
  -e "s|{DASHBOARD_USERNAME_PLACEHOLDER}|$DASHBOARD_USERNAME|" \
  -e "s|{Dashboard_PASSWORD_PLACEHOLDER}|$DASHBOARD_PASSWORD|" \
  -e "s|{DASHBOARD_EMAIL_PLACEHOLDER}|$DASHBOARD_EMAIL|" \
  -e "s|{SECRET_KEY_BASE_PLACEHOLDER}|$SECRET_KEY_BASE|" \
  -e "s|{VAULT_ENC_KEY_PLACEHOLDER}|$VAULT_ENC_KEY|" \
  -e "s|{AUTHELIA_ENCRYPTION_KEY_PLACEHOLDER}|$AUTHELIA_ENCRYPTION_KEY|" \
  -e "s|{AUTHELIA_SESSION_SECRET_PLACEHOLDER}|$AUTHELIA_SESSION_SECRET|" \
  -e "s|{DOMAIN_PLACEHOLDER}|$DOMAIN|" \
  -e "s|{DEV_DOMAIN_PLACEHOLDER}|$DEV_DOMAIN|" \
  -e "s|{AUTHELIA_DOMAIN_PLACEHOLDER}|$AUTHELIA_DOMAIN|" \
  -e "s|{API_DOMAIN_PLACEHOLDER}|$API_DOMAIN|" \
  -e "s|{SMTP_HOST_PLACEHOLDER}|$SMTP_HOST|" \
  -e "s|{SUPABASE_STUDIO_DOMAIN_PLACEHOLDER}|$SUPABASE_STUDIO_DOMAIN|" \
  -e "s|{ADDITIONAL_REDIRECT_URLS_PLACEHOLDER}|$ADDITIONAL_REDIRECT_URLS|" \
  -e "s|{SMTP_PASS_PLACEHOLDER}|$SMTP_PASS|" \
  -e "s|{OPENAI_API_KEY_PLACEHOLDER}|$OPENAI_API_KEY|" \
  -e "s|{GEMINI_API_KEY_PLACEHOLDER}|$GEMINI_API_KEY|" \
  -e "s|{TELEGRAM_BOT_TOKEN_PLACEHOLDER}|$TELEGRAM_BOT_TOKEN|" \
  -e "s|{TELEGRAM_CHAT_ID_PLACEHOLDER}|$TELEGRAM_CHAT_ID|" \
  -e "s|{LOGFLARE_PUBLIC_ACCESS_TOKEN_PLACEHOLDER}|$LOGFLARE_PUBLIC_ACCESS_TOKEN|" \
  -e "s|{LOGFLARE_PRIVATE_ACCESS_TOKEN_PLACEHOLDER}|$LOGFLARE_PRIVATE_ACCESS_TOKEN|" \
  -e "s|{GOOGLE_PROJECT_ID_PLACEHOLDER}||" \
  -e "s|{GOOGLE_PROJECT_NUMBER_PLACEHOLDER}||" \
  "$TEMPLATE" > "$OUTPUT"

echo "✅ $OUTPUT generated"

# --- Generate hosts.txt ---
echo "Generating $HOSTS_OUTPUT for local development..."
echo "# Copy the line below to your /etc/hosts (Linux/Mac) or C:\\Windows\\System32\\drivers\\etc\\hosts (Windows)" > "$HOSTS_OUTPUT"
echo "127.0.0.1 $DOMAIN $DEV_DOMAIN $AUTHELIA_DOMAIN $API_DOMAIN $SMTP_HOST $SUPABASE_STUDIO_DOMAIN" >> "$HOSTS_OUTPUT"
echo "✅ $HOSTS_OUTPUT generated"

# Run overrides and rclone setup
if [ -f "scripts/platform-overrides.sh" ]; then
    echo "Checking for platform overrides..."
    scripts/platform-overrides.sh
fi

echo "Do you want to set up rclone for backups? (yes/no): "
read RCLONE_CHOICE
if [ "$RCLONE_CHOICE" = "yes" ]; then
    if [ -f "scripts/rclone_setup.sh" ]; then
        scripts/rclone_setup.sh
    else
        echo "⚠️  scripts/rclone_setup.sh not found."
    fi
else
  echo "Setup complete."
fi