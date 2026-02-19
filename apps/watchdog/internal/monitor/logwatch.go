package monitor

import (
	"fmt"
	"os/exec"
	"strings"
	"time"
	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

func WatchLogs(tg *telegram.Service) {
	containerName := "supabase-db"
	patterns := []string{"invalid record length", "could not read block", "wal corruption", "database files are incompatible", "FATAL", "PANIC"}

	ticker := time.NewTicker(1 * time.Minute)
	for range ticker.C {
		out, err := exec.Command("docker", "logs", "--tail", "200", containerName).CombinedOutput()
		if err != nil {
			continue
		}

		logStr := strings.ToLower(string(out))
		var matches []string

		for _, p := range patterns {
			if strings.Contains(logStr, strings.ToLower(p)) {
				// Exclude noise
				if strings.Contains(logStr, "terminating connection") || strings.Contains(logStr, "database system is starting up") {
					continue
				}
				matches = append(matches, p)
			}
		}

		if len(matches) > 0 {
			tg.Send(fmt.Sprintf("🛑 [LOGWATCH] Potential corruption in %s!\nMatches: %s", containerName, strings.Join(matches, ", ")))
		}
	}
}