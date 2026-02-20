package monitor

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

// Docker API structs to parse the JSON response
type containerInfo struct {
	Id     string   `json:"Id"`
	Names  []string `json:"Names"`
	State  string   `json:"State"`  // e.g. running, exited
	Status string   `json:"Status"` // e.g. Up 2 hours
	Health *struct {
		Status string `json:"Status"` // e.g. healthy, unhealthy, starting
	} `json:"Health,omitempty"`
}

func WatchContainers(tg *telegram.Service) {
	log.Println("🔍 [MONITOR] Docker socket health watcher started (20s interval)")

	// Create an HTTP client that talks to the Unix socket
	httpClient := &http.Client{
		Transport: &http.Transport{
			DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
				return net.Dial("unix", "/var/run/docker.sock")
			},
		},
		Timeout: 10 * time.Second,
	}

	ticker := time.NewTicker(20 * time.Second)
	for range ticker.C {
		// 1. Get all containers (all=1 includes stopped containers)
		resp, err := httpClient.Get("http://localhost/containers/json?all=1")
		if err != nil {
			log.Printf("❌ [DOCKER] Socket Error: %v", err)
			tg.Send(fmt.Sprintf("🛑 Watchdog: Docker API error at %s", time.Now().Format(time.Kitchen)))
			continue
		}

		var containers []containerInfo
		if err := json.NewDecoder(resp.Body).Decode(&containers); err != nil {
			log.Printf("❌ [DOCKER] JSON Decode Error: %v", err)
			resp.Body.Close()
			continue
		}
		resp.Body.Close()

		// 2. Loop through containers and mimic shell script logic
		for _, c := range containers {
			name := "unknown"
			if len(c.Names) > 0 {
				name = strings.TrimPrefix(c.Names[0], "/")
			}

			// A. Check Container State (equivalent to the shell case "$state" in ...)
			switch c.State {
			case "exited", "dead", "created", "paused":
				log.Printf("🚨 [DOCKER] %s is %s", name, c.State)
				tg.Send(fmt.Sprintf("🛑 Container %s is %s at %s", name, c.State, time.Now().Format(time.Kitchen)))
				continue // If it's not running, no point checking health
			}

			// B. Check Health Status (equivalent to the shell case "$health" in ...)
			if c.Health != nil {
				switch c.Health.Status {
				case "unhealthy":
					log.Printf("⚠️ [DOCKER] %s is UNHEALTHY", name)
					tg.Send(fmt.Sprintf("⚠️ Container %s health check failed at %s", name, time.Now().Format(time.Kitchen)))
				case "starting":
					// Optional: log it, but usually don't alert unless it stays starting forever
					log.Printf("⏳ [DOCKER] %s is still starting", name)
				}
			}
		}
	}
}