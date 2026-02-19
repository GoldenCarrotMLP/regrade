package worker

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/GoldenCarrotMLP/watchdog/internal/tasks"
	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

func StartWorkers(tg *telegram.Service) {
	ctx := context.Background()

	// 1. Redis Listener (Keep this, it's working)
	redisHost := os.Getenv("REDIS_HOST")
	if redisHost == "" {
		redisHost = "redis"
	}
	rdb := redis.NewClient(&redis.Options{Addr: redisHost + ":6379"})

	go func() {
		pubsub := rdb.Subscribe(ctx, "disk.cleanup.request", "notify.telegram")
		log.Printf("📥 [WORKER] Redis listener active on %s", redisHost)

		for msg := range pubsub.Channel() {
			switch msg.Channel {
			case "disk.cleanup.request":
				log.Println("🧹 [REDIS] Cleanup request received")
				tasks.RunDiskCleanup(tg)
			case "notify.telegram":
				tg.Send(msg.Payload)
			}
		}
	}()

	// 2. PGMQ Worker (The Docker Exec version)
	go runPGMQPoller(tg)
}

func runPGMQPoller(tg *telegram.Service) {
	log.Println("📥 [PGMQ] Worker started (Polling via Docker Exec)")

	queues := []string{"ticket_insert_events", "ticket_status_reset_events"}
	container := "supabase-db" // Adjust if your container name is different

	for {
		for _, q := range queues {
			// 1. Read from Queue
			// select msg_id, message->>'message' ...
			query := fmt.Sprintf("select msg_id, message->>'message' from pgmq.read('%s', 30, 50);", q)
			
			cmd := exec.Command("docker", "exec", container, "psql", "-U", "supabase_admin", "-d", "postgres", "-Atc", query)
			out, err := cmd.Output()
			
			if err != nil {
				// Log verbose error only if it's NOT just an empty result or standard noise
				// log.Printf("⚠️ [PGMQ] Read error: %v", err)
				time.Sleep(1 * time.Second)
				continue
			}

			outputStr := strings.TrimSpace(string(out))
			if outputStr == "" {
				continue
			}

			// 2. Process Lines
			lines := strings.Split(outputStr, "\n")
			for _, line := range lines {
				if line == "" {
					continue
				}

				// Split "123|Hello World" -> "123", "Hello World"
				// strings.Cut splits on the *first* pipe, safe if message contains pipes
				msgID, msgBody, found := strings.Cut(line, "|")
				if !found {
					continue
				}

				log.Printf("📩 [PGMQ] Processing MsgID: %s from Queue: %s", msgID, q)

				// 3. Send to Telegram
				tg.Send(msgBody)

				// 4. Delete Message
				// select pgmq.delete('queue', id)
				delQuery := fmt.Sprintf("select pgmq.delete('%s', %s);", q, msgID)
				exec.Command("docker", "exec", container, "psql", "-U", "supabase_admin", "-d", "postgres", "-Atc", delQuery).Run()
			}
		}

		// Sleep 1 second before next poll cycle (same as sleep 1 in shell script)
		time.Sleep(1 * time.Second)
	}
}