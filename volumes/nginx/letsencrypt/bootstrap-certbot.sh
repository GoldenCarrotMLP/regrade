#!/bin/sh
set -eu

LE_BASE="/etc/letsencrypt/live"
ACCOUNTS_DIR="/etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory"

echo "[certbot-bootstrap] Scanning /etc/nginx/sites-enabled for domains..."

# Extract all server_name values
DOMAINS=$(grep -Rho "server_name[[:space:]]\+[^;]\+" /etc/nginx/sites-enabled \
  | awk '{print $2}' \
  | grep -v '^_$' \
  | sort -u)

echo "[certbot-bootstrap] Found domains:"
echo "$DOMAINS"

###############################################
# 1. AUTO-SELECT FIRST ACME ACCOUNT
###############################################
if [ -d "$ACCOUNTS_DIR" ]; then
  FIRST_ACCOUNT=$(ls "$ACCOUNTS_DIR" | head -n 1 || true)

  if [ -n "${FIRST_ACCOUNT:-}" ]; then
    echo "[certbot-bootstrap] Auto-selecting ACME account: $FIRST_ACCOUNT"
    mkdir -p /etc/letsencrypt
    echo "account = $FIRST_ACCOUNT" > /etc/letsencrypt/cli.ini
  else
    echo "[certbot-bootstrap] No ACME accounts found — Certbot will create one automatically."
  fi
else
  echo "[certbot-bootstrap] No ACME accounts directory found — Certbot will create one automatically."
fi

###############################################
# 2. INITIAL CERTIFICATE ISSUANCE
###############################################
for domain in $DOMAINS; do
  if [ ! -d "${LE_BASE}/${domain}" ]; then
    echo "[certbot-bootstrap] No cert for ${domain}, requesting initial certificate..."

    certbot certonly --non-interactive --agree-tos \
      --webroot -w /var/www/certbot \
      -d "${domain}" || true

  else
    echo "[certbot-bootstrap] Cert already exists for ${domain}, skipping initial issuance."
  fi
done

echo "[certbot-bootstrap] Initial pass done. Entering renewal loop..."

###############################################
# 3. RENEWAL LOOP (runs forever)
###############################################
while true; do
  certbot renew --webroot -w /var/www/certbot \
    --deploy-hook 'touch /etc/letsencrypt/RENEWED' || true

  sleep 12h
done