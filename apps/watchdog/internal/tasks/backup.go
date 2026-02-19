package tasks

import (
	"log"
	"os/exec"
	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

// RunFullBackup handles logical pg_dump snapshots to Dropbox
func RunFullBackup(tg *telegram.Service) {
	log.Println("📂 [BACKUP] Starting logical snapshot (pg_dump)...")
	
	cmd := exec.Command("/bin/sh", "/app/legacy_scripts/backup.sh")
	output, err := cmd.CombinedOutput()
	
	if err != nil {
		log.Printf("❌ [BACKUP] Execution Error: %v\nOutput: %s", err, string(output))
		tg.Send("⚠️ Watchdog failed to execute the logical backup script. Check container logs.")
		return
	}
	
	// Success is now silent on Telegram
	log.Println("✅ [BACKUP] Snapshot finished successfully.")
}