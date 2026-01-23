#!/bin/sh
set -eu

LE_BASE="/etc/letsencrypt/live"

echo "[certbot-bootstrap] Scanning /etc/nginx/sites-enabled for domains..."

DOMAINS=$(grep -Rho "server_name[[:space:]]\+[^;]\+" /etc/nginx/sites-enabled \
  | awk '{print $2}' \
  | grep -v '^_$' \
  | sort -u)

echo "[certbot-bootstrap] Found domains:"
echo "$DOMAINS"

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

while true; do
  certbot renew --webroot -w /var/www/certbot \
    --deploy-hook 'touch /etc/letsencrypt/RENEWED' || true
  sleep 12h
done
