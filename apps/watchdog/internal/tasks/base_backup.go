package tasks

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

// CheckAndRunStartupBaseBackup checks if today has a base backup. If not, runs one.
func CheckAndRunStartupBaseBackup(tg *telegram.Service) {
	// 1. Ensure the DB allows replication from supabase_admin via IPv4 loopback
	log.Println("🛠️ [BASE] Ensuring replication permissions in pg_hba.conf...")
	
	// We use the path /etc/postgresql/pg_hba.conf which the DB reported as the active one.
	// We add a 'host' rule for 127.0.0.1 to match the -h 127.0.0.1 flag used later.
	hbaFix := `
		HBA_FILE="/etc/postgresql/pg_hba.conf"
		if ! grep -q "host replication supabase_admin 127.0.0.1/32" "$HBA_FILE"; then
			echo "host replication supabase_admin 127.0.0.1/32 trust" >> "$HBA_FILE"
			psql -U supabase_admin -d postgres -c "SELECT pg_reload_conf();"
			echo "✅ [BASE] pg_hba.conf updated and reloaded."
		fi
	`
	exec.Command("docker", "exec", "supabase-db", "sh", "-c", hbaFix).Run()

	// 2. Check if today's backup already exists on Dropbox
	today := time.Now().Format("2006-01-02")
	remoteFile := fmt.Sprintf("dropbox:SupabaseServerBackups_WAL/%s/base.tar.gz", today)

	log.Printf("🔍 [BASE] Checking for %s base backup on Dropbox...", today)
	cmd := exec.Command("docker", "exec", "supabase-rclone", "rclone", "lsf", remoteFile)
	out, _ := cmd.Output()

	if strings.TrimSpace(string(out)) == "" {
		log.Println("🚨 [BASE] TODAY HAS NO BACKUP. Starting immediate generation...")
		tg.Send("🚨 Alert: Today has no base backup. Starting one immediately.")
		RunDailyBaseBackup(tg)
	} else {
		log.Println("✅ [BASE] Today is already initialized on Dropbox.")
	}
}

// RunDailyBaseBackup creates a physical replication slot backup (pg_basebackup)
func RunDailyBaseBackup(tg *telegram.Service) {
	today := time.Now().Format("2006-01-02")
	
	// Paths inside the DB container
	dbTempDir := "/tmp/basebackup_gen"
	
	// Path inside the Watchdog container
	localPath := fmt.Sprintf("/app/backup/base_%s.tar.gz", today)
	
	// Path inside the Rclone container (maps to the same host volume)
	rcloneSourcePath := fmt.Sprintf("/backup/base_%s.tar.gz", today)
	
	// Remote Destination
	remoteDest := fmt.Sprintf("dropbox:SupabaseServerBackups_WAL/%s/base.tar.gz", today)

	log.Println("🐘 [BASE] Starting pg_basebackup (this may take a few minutes)...")

	// 1. Cleanup previous attempts inside DB container
	exec.Command("docker", "exec", "supabase-db", "rm", "-rf", dbTempDir).Run()

	// 2. Run pg_basebackup
	// Added -h 127.0.0.1 to force IPv4 loopback (matching our HBA fix)
	cmd := exec.Command("docker", "exec", "supabase-db", 
		"pg_basebackup", 
		"-h", "127.0.0.1", 
		"-U", "supabase_admin", 
		"-D", dbTempDir, 
		"-Ft", "-z", "-X", "none")
	
	if out, err := cmd.CombinedOutput(); err != nil {
		log.Printf("❌ [BASE] pg_basebackup failed: %s", string(out))
		tg.Send("❌ Physical Base Backup Failed! check watchdog logs.")
		return
	}

	// 3. Copy out of DB container into the shared backup volume
	log.Println("⬇️ [BASE] Copying backup from DB container to watchdog volume...")
	cpCmd := exec.Command("docker", "cp", fmt.Sprintf("supabase-db:%s/base.tar.gz", dbTempDir), localPath)
	if err := cpCmd.Run(); err != nil {
		log.Printf("❌ [BASE] Docker CP failed: %v", err)
		tg.Send("❌ Failed to copy base backup out of DB container.")
		return
	}

	// 4. Cleanup DB container temp files immediately
	exec.Command("docker", "exec", "supabase-db", "rm", "-rf", dbTempDir).Run()

	// 5. Upload to Dropbox via the rclone container
	log.Printf("⬆️ [BASE] Uploading to Dropbox path: %s", remoteDest)
	
	// IMPORTANT: We tell rclone to look at rcloneSourcePath (/backup/...) 
	// because rclone's container sees the volume there.
	upCmd := exec.Command("docker", "exec", "supabase-rclone", "rclone", 
		"--config", "/config/rclone/rclone.conf",
		"copyto", rcloneSourcePath, remoteDest)
	
	if out, err := upCmd.CombinedOutput(); err != nil {
		log.Printf("❌ [BASE] Rclone upload failed: %s", string(out))
		tg.Send("❌ Base Backup Upload Failed.")
		return
	}

	// 6. Cleanup local file in the watchdog container
	os.Remove(localPath)

	log.Printf("✅ [BASE] Successfully archived base backup for %s", today)
	tg.Send(fmt.Sprintf("✅ Daily Base Backup completed and uploaded for %s.", today))
}