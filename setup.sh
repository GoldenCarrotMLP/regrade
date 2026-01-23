#!/bin/sh

TEMPLATE=".env.example"
OUTPUT=".env"

# Function to generate a random secret (URL-safe, good for JWT and passwords)
gen_secret() {
  head -c 64 /dev/urandom | base64 | tr -d '\n' | tr -d '=' | tr '/+' 'AB'
}

echo "Do you have a domain? (leave blank for localhost): "
read DOMAIN
if [ -z "$DOMAIN" ]; then
  DOMAIN="localhost"
  SMTP_PASSWORD=$(gen_secret)
else
  echo "Enter SMTP password: "
  read SMTP_PASSWORD
fi

# Ask if user wants Telegram logging
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

# Ask user for dashboard credentials
echo "Enter dashboard username: "
read DASHBOARD_USERNAME
echo "Enter dashboard password: "
read DASHBOARD_PASSWORD

# Ask for optional API keys
echo "Enter OpenAI API key (optional): "
read OPENAI_API_KEY
echo "Enter Gemini API key (optional): "
read GEMINI_API_KEY

# Auto-generate secrets
POSTGRES_PASSWORD=$(gen_secret)
JWT_SECRET=$(gen_secret)
ANON_KEY=$(gen_secret)
SERVICE_ROLE_KEY=$(gen_secret)
SECRET_KEY_BASE=$(gen_secret)
VAULT_ENC_KEY=$(gen_secret)

# Replace placeholders
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

echo "✅ .env file generated at $OUTPUT"

# Ask if user wants rclone setup
echo "Do you want to set up rclone for backups? (yes/no): "
read RCLONE_CHOICE
if [ "$RCLONE_CHOICE" = "yes" ]; then
  ./rclone_setup.sh
fi
