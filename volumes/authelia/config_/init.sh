#!/bin/sh
set -e

echo "🔧 Generating Authelia configuration.yml..."

TEMPLATE="/tmp/configuration.yml"
OUTPUT="/config/configuration.yml"
USERS_FILE="/config/users.yml"

###############################################
# 1. CHECK IF users.yml IS A DIRECTORY
###############################################
if [ -d "$USERS_FILE" ]; then
  echo "❌ ERROR: /config/users.yml is a directory."
  echo "Fix this on the HOST:"
  echo "  rm -rf volumes/authelia/config/users.yml"
  echo "  touch volumes/authelia/config/users.yml"
  exit 1
fi

###############################################
# 2. ENSURE users.yml EXISTS AND HAS ROOT KEY
###############################################
if [ ! -f "$USERS_FILE" ]; then
  echo "📄 Creating new users.yml"
  echo "users:" > "$USERS_FILE"
fi

# Ensure file starts with "users:"
FIRST_LINE=$(head -n 1 "$USERS_FILE" | tr -d '\r\n')
if [ "$FIRST_LINE" != "users:" ]; then
  echo "📄 Fixing users.yml root key"
  CONTENT=$(cat "$USERS_FILE")
  echo "users:" > "$USERS_FILE"
  echo "$CONTENT" >> "$USERS_FILE"
fi

###############################################
# 3. ADD DASHBOARD USER IF MISSING
###############################################
if grep -q "^[[:space:]]*${DASHBOARD_USERNAME}:" "$USERS_FILE"; then
  echo "ℹ️  Dashboard user '${DASHBOARD_USERNAME}' already exists."
else
  echo "🔐 Adding dashboard user '${DASHBOARD_USERNAME}'..."

HASH=$(authelia crypto hash generate --password "$DASHBOARD_PASSWORD" \
  | grep '^Digest:' \
  | awk '{print $2}' \
  | tr -d '\r')

if [ -z "$HASH" ]; then
  echo "❌ ERROR: Failed to generate password hash."
  exit 1
fi

cat >> "$USERS_FILE" <<EOF

  ${DASHBOARD_USERNAME}:
    displayname: "${DASHBOARD_USERNAME}"
    email: "${DASHBOARD_EMAIL}"
    password: "${HASH}"
EOF

echo "✅ Dashboard user added."
fi

###############################################
# 4. GENERATE configuration.yml FROM TEMPLATE
###############################################
# Dynamically replace all {{VAR}} placeholders with matching environment variables
generate_config() {
  while IFS= read -r line; do
    # Find all placeholders in the line
    while echo "$line" | grep -q "{{[A-Za-z0-9_]\+}}"; do
      placeholder=$(echo "$line" | grep -o "{{[A-Za-z0-9_]\+}}" | head -n 1)
      varname=$(echo "$placeholder" | tr -d '{}' )

      # Get env value
      value=$(env | grep "^${varname}=" | sed "s/^${varname}=//")

      if [ -z "$value" ]; then
        echo "❌ ERROR: Environment variable '$varname' is not set but is required by template."
        exit 1
      fi

      # Replace placeholder with value
      line=$(echo "$line" | sed "s|$placeholder|$value|g")
    done

    echo "$line"
  done < "$TEMPLATE" > "$OUTPUT"
}

generate_config
echo "✅ configuration.yml generated."

###############################################
# 5. START AUTHELIA
###############################################
exec /app/entrypoint.sh