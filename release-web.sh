#!/usr/bin/env bash
set -euo pipefail

# Exit cleanly if interrupted (Ctrl+C)
trap 'echo "Script interrupted. Exiting..."; exit 1' INT

# 1. Build the image locally
docker compose build web

# 2. Get the current Git version
GIT_HASH=$(git rev-parse --short HEAD)
echo "Tagging version: $GIT_HASH"

# 3. Tag the image for release
docker tag supabase-web tuplasma/regrade-web:$GIT_HASH
docker tag supabase-web tuplasma/regrade-web:latest

# 4. Push to Docker Hub
docker push tuplasma/regrade-web:$GIT_HASH
docker push tuplasma/regrade-web:latest

# 5. Restart the web service to use the new image
docker compose down web && docker compose up -d web
