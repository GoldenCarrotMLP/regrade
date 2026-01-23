#!/bin/sh

OUTPUT="docker-compose.override.yml"

# Detect WSL
if grep -qi microsoft /proc/version; then
  echo "⚙️ WSL detected, generating $OUTPUT..."

  cat > "$OUTPUT" <<'EOF'
services:
  db:
    volumes:
      - ./volumes/db/realtime.sql:/docker-entrypoint-initdb.d/migrations/99-realtime.sql:Z
      - ./volumes/db/webhooks.sql:/docker-entrypoint-initdb.d/init-scripts/98-webhooks.sql:Z
      - ./volumes/db/roles.sql:/docker-entrypoint-initdb.d/init-scripts/99-roles.sql:Z
      - ./volumes/db/jwt.sql:/docker-entrypoint-initdb.d/init-scripts/99-jwt.sql:Z

      # THIS is the overridden line
      - ~/volumes/db/data17:/var/lib/postgresql/data:Z

      - ./volumes/db/_supabase.sql:/docker-entrypoint-initdb.d/migrations/97-_supabase.sql:Z
      - ./volumes/db/logs.sql:/docker-entrypoint-initdb.d/migrations/99-logs.sql:Z
      - ./volumes/db/pooler.sql:/docker-entrypoint-initdb.d/migrations/99-pooler.sql:Z
      - db-config:/etc/postgresql-custom-new
EOF

  echo "✅ $OUTPUT created for WSL"
else
  echo "No WSL detected. Skipping override generation."
fi