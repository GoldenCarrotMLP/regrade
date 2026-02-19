package tasks

import (
	"os/exec"
	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

func RunDiskCleanup(tg *telegram.Service) {
	tg.Send("🧹 Starting Disk Cleanup...")
	
	// Execute the same commands your shell script used
	exec.Command("docker", "system", "prune", "-a", "-f").Run()
	exec.Command("docker", "volume", "prune", "-f").Run()
	
	tg.Send("✅ Cleanup Done")
}