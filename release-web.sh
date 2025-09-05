# (One time) Login to Docker Hub
docker login -u "tuplasma"

# 1. Build the image locally

# 2. Get the current Git version
GIT_HASH=$(git rev-parse --short HEAD)
echo "Tagging version: $GIT_HASH"

# 3. Tag the image for release
sudo docker tag supabase-web  tuplasma/regrade-web:$GIT_HASH
sudo docker tag regrade-web tuplasma/regrade-web:latest

# 4. Push to Docker Hub
sudo docker push tuplasma/regrade-web:$GIT_HASH
sudo docker push tuplasma/regrade-web:latest
