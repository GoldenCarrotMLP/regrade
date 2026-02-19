package api

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"strings"

	"github.com/redis/go-redis/v9"
	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

func StartRedisAPI(tg *telegram.Service) {
	ctx := context.Background()
	addr := os.Getenv("REDIS_HOST")
	if addr == "" { addr = "redis" }
	rdb := redis.NewClient(&redis.Options{Addr: addr + ":6379"})

	channels := []string{
		"pitr.list_days.request",
		"pitr.get_window.request",
		"snapshots.list_days.request",
		"snapshots.list_files.request",
	}

	go func() {
		pubsub := rdb.Subscribe(ctx, channels...)
		log.Printf("📡 [API] Redis Listener Online for %v", channels)

		for msg := range pubsub.Channel() {
			var req RedisRequest
			if err := json.Unmarshal([]byte(msg.Payload), &req); err != nil {
				continue
			}

			go func(r RedisRequest, channel string) {
				var data interface{}
				var err error

				if strings.Contains(channel, "pitr.list_days") {
					data, err = ListPitrDays()
				} else if strings.Contains(channel, "pitr.get_window") {
					data, err = GetContiguousWALRange(r.Day)
				} else if strings.Contains(channel, "snapshots.list_days") {
					data, err = ListSnapshotDays()
				} else if strings.Contains(channel, "snapshots.list_files") {
					data, err = ListSnapshotFiles(r.Day)
				}

				resp := RedisResponse{
					CorrelationID: r.CorrelationID,
					Ok:            err == nil,
					Data:          data,
				}
				if err != nil {
					resp.Error = err.Error()
				}

				respBytes, _ := json.Marshal(resp)
				responseChannel := strings.Replace(channel, ".request", ".response", 1)
				rdb.Publish(ctx, responseChannel, respBytes)
			}(req, msg.Channel)
		}
	}()
}