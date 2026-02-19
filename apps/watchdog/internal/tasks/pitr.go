package tasks

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"fmt"
	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

func StartWALUploader(tg *telegram.Service) {
	walDir := "/wal_archive"
	remoteRoot := "dropbox:SupabaseServerBackups_WAL"

	log.Println("🚀 [PITR] WAL Uploader started, watching:", walDir)

	go func() {
		ticker := time.NewTicker(10 * time.Second)
		for range ticker.C {
			files, err := os.ReadDir(walDir)
			if err != nil {
				continue
			}

			// Filter out empty directories and hidden files (like .DS_Store)
			var validFiles []os.DirEntry
			for _, f := range files {
				if !f.IsDir() && !strings.HasPrefix(f.Name(), ".") {
					validFiles = append(validFiles, f)
				}
			}

			if len(validFiles) == 0 {
				continue
			}

			dateDir := time.Now().Format("2006-01-02")
			remotePath := fmt.Sprintf("%s/%s/WAL", remoteRoot, dateDir)

			log.Printf("📦 [PITR] Found %d new files (WAL/Metadata), uploading...", len(validFiles))

			// Use 'copy' to be safe. It will create the remote directory if missing.
			cmd := exec.Command("docker", "exec", "supabase-rclone", "rclone", 
				"copy", walDir+"/", remotePath)
			
			if err := cmd.Run(); err != nil {
				log.Printf("❌ [PITR] Upload failed: %v", err)
				continue
			}

			// ONLY delete local files that were there when we started the upload
			// to avoid deleting a file that Postgres just finished writing 1ms ago
			for _, f := range validFiles {
				fullPath := filepath.Join(walDir, f.Name())
				os.Remove(fullPath)
			}
			log.Println("✅ [PITR] Batch uploaded and local storage cleared")
		}
	}()
}