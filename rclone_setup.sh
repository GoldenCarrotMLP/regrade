#!/bin/sh

CONTAINER_NAME="supabase-rclone"

# Check if container exists
if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
  echo "✅ rclone container is already running."
else
  echo "🚀 Starting rclone container..."
  docker compose up -d rclone
fi

# Run rclone config inside the container
echo "Booting into rclone setup..."
docker exec -it $CONTAINER_NAME rclone config