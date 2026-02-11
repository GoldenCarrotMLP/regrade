FROM alpine:latest

RUN apk add --no-cache curl dcron docker-cli redis

WORKDIR /app

COPY backup.sh healthcheck.sh send_telegram.sh diskwatch.sh entry.sh logwatch.sh free_disk_space.sh redis-listener.sh pgmq-worker.sh /app/
COPY cron.d/watchdog /etc/cron.d/watchdog

RUN chmod +x /app/*.sh && chmod 0644 /etc/cron.d/watchdog

CMD ["/app/entry.sh"]