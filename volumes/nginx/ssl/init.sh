#!/bin/sh

# Define paths
AVAILABLE_DIR="/etc/nginx/sites-available"
ENABLED_DIR="/etc/nginx/sites-enabled"

echo "--- Starting Dynamic Nginx Configuration ---"

# 1. Handle the Static Global Redirect File
REDIRECT_FILE="000-redirect-to-https.conf"
if [ -f "$AVAILABLE_DIR/$REDIRECT_FILE" ]; then
    if [ ! -f "$ENABLED_DIR/$REDIRECT_FILE" ]; then
        echo " [COPY] Enabling global redirect: $REDIRECT_FILE"
        cp "$AVAILABLE_DIR/$REDIRECT_FILE" "$ENABLED_DIR/$REDIRECT_FILE"
    else
        echo " [SKIP] $REDIRECT_FILE is already enabled."
    fi
else
    echo " [WARN] $REDIRECT_FILE not found in sites-available."
fi

# 2. Loop through all environment variables starting with SITE_
env | grep '^SITE_' | while IFS='=' read -r var_name var_value; do
    
    var_name=$(echo "$var_name" | tr -d '\r')
    var_value=$(echo "$var_value" | tr -d '\r')

    if [ -z "$var_value" ]; then
        continue
    fi

    TARGET_FILE="$ENABLED_DIR/$var_value"
    TEMPLATE_FILE="$AVAILABLE_DIR/$var_name"

    if [ -f "$TARGET_FILE" ]; then
        echo " [SKIP] Configuration for '$var_value' already exists."
    else
        if [ -f "$TEMPLATE_FILE" ]; then
            echo " [CREATE] Generating config for '$var_value' using template '$var_name'..."
            sed "s|{$var_name}|$var_value|g" "$TEMPLATE_FILE" > "$TARGET_FILE"
            echo "          -> Created $TARGET_FILE"
        else
            echo " [MISSING] Template '$var_name' not found in $AVAILABLE_DIR."
        fi
    fi
done

echo "--- Dynamic Configuration Complete ---"

# 3. Trigger the certificate update script
SCRIPT_CERTS="/etc/nginx/ssl/update-certs.sh"
if [ -f "$SCRIPT_CERTS" ]; then
    echo "--- Executing Update Certs ---"
    chmod +x "$SCRIPT_CERTS" 
    # Use 'sh' to run it or source it with '.'
    sh "$SCRIPT_CERTS"
else
    echo "Error: $SCRIPT_CERTS not found!"
    exit 1
fi