FROM golang:1.24-bookworm AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
COPY . .
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -o watchdog ./cmd/watchdog/main.go

FROM alpine:latest
RUN apk add --no-cache docker-cli rclone gzip redis

WORKDIR /app
# Create directories for volumes
RUN mkdir -p /app/backup /app/pitr /wal_archive

COPY --from=builder /app/watchdog .
COPY legacy_scripts/*.sh /app/legacy_scripts/

# The uploader expects scripts in legacy_scripts/ based on our tasks code
RUN chmod +x /app/watchdog /app/legacy_scripts/*.sh

CMD ["./watchdog"]