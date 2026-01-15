#!/bin/sh
set -eu

LE_BASE="/etc/letsencrypt/live"
SSL_BASE="/etc/nginx/ssl"
FALLBACK="${SSL_BASE}/fallback"
ACME_ROOT="/var/www/certbot/.well-known/acme-challenge"

# --- Health file creation (truthful readiness signal) ---
mkdir -p "$ACME_ROOT"
echo "ok" > "${ACME_ROOT}/health"

echo "[cert-init] ACME health file created at ${ACME_ROOT}/health"

# Ensure fallback cert exists
if [ ! -f "${FALLBACK}.fullchain.pem" ] || [ ! -f "${FALLBACK}.privkey.pem" ]; then
  echo "[cert-init] ERROR: fallback certificate missing!"
  exit 1
fi

echo "[cert-init] Scanning /etc/nginx/sites-enabled for domains..."

DOMAINS=$(grep -Rho "server_name[[:space:]]\+[^;]\+" /etc/nginx/sites-enabled \
  | awk '{print $2}' \
  | grep -v '^_$' \
  | sort -u)

echo "$DOMAINS"

for domain in $DOMAINS; do
  echo "[cert-init] Processing $domain"

  LE_FULLCHAIN="${LE_BASE}/${domain}/fullchain.pem"
  LE_PRIVKEY="${LE_BASE}/${domain}/privkey.pem"

  TARGET_FULLCHAIN="${SSL_BASE}/${domain}.fullchain.pem"
  TARGET_PRIVKEY="${SSL_BASE}/${domain}.privkey.pem"

  if [ -f "$LE_FULLCHAIN" ] && [ -f "$LE_PRIVKEY" ]; then
    ln -sf "$LE_FULLCHAIN" "$TARGET_FULLCHAIN"
    ln -sf "$LE_PRIVKEY"   "$TARGET_PRIVKEY"
  else
    ln -sf "${FALLBACK}.fullchain.pem" "$TARGET_FULLCHAIN"
    ln -sf "${FALLBACK}.privkey.pem"   "$TARGET_PRIVKEY"
  fi
done

# Reload nginx if running
if pgrep nginx >/dev/null 2>&1; then
  nginx -s reload || true
fi

echo "[cert-init] Done."
