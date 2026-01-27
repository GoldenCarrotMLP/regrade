#!/bin/bash
set -e

ENV_FILE=".env"
USERS_FILE="volumes/authelia/config/users.yml"

# Load only valid KEY=value lines and quote the value
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r key value; do
    # Skip empty lines and comments
    [[ -z "$key" || "$key" =~ ^# ]] && continue

    # Skip invalid variable names
    if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      export "$key=\"$value\""
    fi
  done < "$ENV_FILE"
else
  echo "❌ .env file not found at project root."
  exit 1
fi

# Ensure Authelia container is running
if ! docker ps --format '{{.Names}}' | grep -q '^authelia$'; then
  echo "🚀 Authelia container not running. Starting it..."
  docker compose up -d authelia
  sleep 2
fi

echo "🔐 Add a new Authelia user"

# Prompt for user info
read -p "Username: " USERNAME
read -p "Email: " EMAIL
read -s -p "Password: " PASSWORD
echo

# Ensure directory exists
mkdir -p "$(dirname "$USERS_FILE")"

# If file exists, check for duplicate username
if [ -f "$USERS_FILE" ]; then
  if grep -q "^[[:space:]]*$USERNAME:" "$USERS_FILE"; then
    echo "❌ User '$USERNAME' already exists in users.yml"
    exit 1
  fi
fi

# Generate password hash
echo "🔄 Generating password hash..."
HASH=$(docker exec authelia authelia crypto hash generate --password "$PASSWORD" \
  | grep '^Digest:' \
  | awk '{print $2}' \
  | tr -d '\r')

if [ -z "$HASH" ]; then
  echo "❌ Failed to generate password hash."
  exit 1
fi

# Create or append user entry
if [ ! -f "$USERS_FILE" ]; then
  echo "📄 Creating new users.yml"
  cat > "$USERS_FILE" <<EOF
users:
  $USERNAME:
    displayname: "$USERNAME"
    email: "$EMAIL"
    password: "$HASH"
EOF
  echo "✅ User added to new users.yml"
else
  echo "📄 Appending user to existing users.yml"
  cat >> "$USERS_FILE" <<EOF

  $USERNAME:
    displayname: "$USERNAME"
    email: "$EMAIL"
    password: "$HASH"
EOF
  echo "✅ User appended successfully."
fi

echo "📌 File updated: $USERS_FILE"







