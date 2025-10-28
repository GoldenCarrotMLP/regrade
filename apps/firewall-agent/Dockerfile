# Stage 1: Build Go binary
FROM golang:1.24 AS builder
WORKDIR /app

COPY . .

RUN [ ! -f go.mod ] && go mod init firewall-agent || true
RUN go get github.com/lib/pq

# Build all Go files into one binary
RUN go build -o resolver .

# Stage 2: Final runtime container
FROM debian:stable-slim
WORKDIR /app

# Install curl, unzip, CA certs, and nftables if you want rules applied here
RUN apt-get update && apt-get install -y curl unzip ca-certificates nftables \
    && rm -rf /var/lib/apt/lists/*

# Install Subfinder
RUN curl -L -o subfinder.zip https://github.com/projectdiscovery/subfinder/releases/download/v2.9.0/subfinder_2.9.0_linux_amd64.zip \
    && unzip subfinder.zip \
    && mv subfinder /usr/local/bin/subfinder \
    && chmod +x /usr/local/bin/subfinder \
    && rm subfinder.zip

COPY --from=builder /app/resolver /usr/local/bin/resolver

ENTRYPOINT ["resolver"]
