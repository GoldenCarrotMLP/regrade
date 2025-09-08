# 1. Build the image locally

# 2. Get the current Git version
GIT_HASH=$(git rev-parse --short HEAD)
echo "Tagging version: $GIT_HASH"

# 3. Tag the image for release
docker tag supabase-web  tuplasma/regrade-web:$GIT_HASH
docker tag regrade-web tuplasma/regrade-web:latest

# 4. Push to Docker Hub
docker push tuplasma/regrade-web:$GIT_HASH
docker push tuplasma/regrade-web:latest
