package monitor

import (
	"os/exec"
	"strings"
	"time"
	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

func WatchContainers(tg *telegram.Service) {
	ticker := time.NewTicker(30 * time.Second)
	for range ticker.C {
		out, _ := exec.Command("docker", "ps", "--format", "{{.Names}} {{.Status}}").CombinedOutput()

		lines := strings.Split(string(out), "\n")
		for _, line := range lines {
			if strings.Contains(line, "(unhealthy)") {
				tg.Send("⚠️ Container Health Alert: " + line)
			}
		}
	}
}