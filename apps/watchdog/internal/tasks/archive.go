package tasks

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/GoldenCarrotMLP/watchdog/internal/api"
	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

type RcloneItem struct {
	Name    string    `json:"Name"`
	IsDir   bool      `json:"IsDir"`
	Size    int64     `json:"Size"`
	ModTime time.Time `json:"ModTime"`
}

// MAIN ENTRYPOINT: Startup deep consistency check
func RunStartupBackfill(tg *telegram.Service) {
	log.Println("🕵️ [BACKFILL] Starting deep consistency check on Dropbox...")

	cmd := exec.Command("docker", "exec", "supabase-rclone", "rclone",
		"lsf", "--dirs-only", "dropbox:SupabaseServerBackups_WAL/")
	out, err := cmd.Output()
	if err != nil {
		log.Printf("⚠️ [BACKFILL] Dropbox connection failed: %v", err)
		return
	}

	today := time.Now().Format("2006-01-02")
	dates := strings.Split(strings.TrimSpace(string(out)), "\n")

	for _, dateDir := range dates {
		date := strings.TrimSuffix(dateDir, "/")
		if date == "" || date == today {
			continue
		}

		lsCmd := exec.Command("docker", "exec", "supabase-rclone", "rclone",
			"lsjson", fmt.Sprintf("dropbox:SupabaseServerBackups_WAL/%s/", date))
		jsonOut, _ := lsCmd.Output()
		var items []RcloneItem
		json.Unmarshal(jsonOut, &items)

		hasArchive, hasMetadata, hasWalDir, hasBase := false, false, false, false
		var baseTime time.Time

		for _, item := range items {
			if item.Name == "WAL_archive.tar.gz" { hasArchive = true }
			if item.Name == "metadata.json" { hasMetadata = true }
			if item.Name == "base.tar.gz" { 
				hasBase = true 
				baseTime = item.ModTime
			}
			if item.Name == "WAL" && item.IsDir { hasWalDir = true }
		}

		// 0. Perfectly Healthy
		if hasArchive && hasMetadata && hasBase {
			log.Printf("✅ [BACKFILL] %s is healthy.", date)
			continue
		}

		// 1. Missing Metadata, but Archive Exists (Manual Deletion Case)
		if hasArchive && !hasMetadata {
			log.Printf("🔧 [HEAL] %s: Archive exists, metadata missing. Regenerating...", date)
			HealMetadataFromArchive(date, baseTime, tg)
			continue
		}

		// 2. No Archive, No Metadata, but RAW WALs exist (Standard Backfill)
		if !hasArchive && !hasMetadata && hasWalDir {
			log.Printf("🧹 [HEAL] %s: Raw WALs found, starting archive process...", date)
			ArchiveRemoteDay(date, tg)
			continue
		}

		// 3. Completely Empty / No WALs / No Archive (Data Loss Case)
		if !hasArchive && !hasMetadata && !hasWalDir {
			log.Printf("🚨 [HEAL] %s: DATA LOSS DETECTED.", date)
			HandleTotalDataLoss(date, tg)
		}
	}
}

// MAIN ENTRYPOINT: Scheduled Cron at 23:59
func RunArchiveYesterday(tg *telegram.Service) {
	yesterday := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
	ArchiveRemoteDay(yesterday, tg)
}

// CORE LOGIC: Standard Archive Flow
func ArchiveRemoteDay(date string, tg *telegram.Service) {
	remoteRoot := fmt.Sprintf("dropbox:SupabaseServerBackups_WAL/%s", date)
	localBase := fmt.Sprintf("/app/pitr/supabase-%s_base", date)
	localWalDir := filepath.Join(localBase, "WAL")
	localArchive := filepath.Join(localBase, "WAL_archive.tar.gz")
	localMeta := filepath.Join(localBase, "metadata.json")

	os.RemoveAll(localBase)
	os.MkdirAll(localBase, 0755)

	// Fetch base timestamp if not already known
	var baseTime time.Time
	lsBaseCmd := exec.Command("docker", "exec", "supabase-rclone", "rclone", "lsjson", remoteRoot+"/base.tar.gz")
	if out, err := lsBaseCmd.Output(); err == nil {
		var items []RcloneItem
		if err := json.Unmarshal(out, &items); err == nil && len(items) > 0 {
			baseTime = items[0].ModTime
		}
	}

	log.Printf("⬇️ [ARCHIVE] Downloading WALs for %s...", date)
	exec.Command("docker", "exec", "supabase-rclone", "rclone", "copy", remoteRoot+"/WAL", localWalDir).Run()

	// Compute and Save
	meta := scanAndUpload(date, localWalDir, localMeta, remoteRoot, baseTime, tg)

	log.Printf("📦 [ARCHIVE] Compressing...")
	if err := exec.Command("tar", "-czf", localArchive, "-C", localBase, "WAL").Run(); err == nil {
		exec.Command("docker", "exec", "supabase-rclone", "rclone", "copyto", localArchive, remoteRoot+"/WAL_archive.tar.gz").Run()
		exec.Command("docker", "exec", "supabase-rclone", "rclone", "purge", remoteRoot+"/WAL").Run()
	}

	os.RemoveAll(localWalDir)
	os.Remove(localArchive)

	notifySuccess(tg, date, meta)
}

// HEALING LOGIC: Metadata Recovery
func HealMetadataFromArchive(date string, baseTime time.Time, tg *telegram.Service) {
	remoteRoot := fmt.Sprintf("dropbox:SupabaseServerBackups_WAL/%s", date)
	localBase := fmt.Sprintf("/app/pitr/supabase-%s_base", date)
	localWalDir := filepath.Join(localBase, "WAL")
	localArchive := filepath.Join(localBase, "WAL_archive.tar.gz")
	localMeta := filepath.Join(localBase, "metadata.json")

	os.MkdirAll(localBase, 0755)
	log.Printf("⬇️ [HEAL] Downloading archive for %s to regenerate metadata...", date)
	exec.Command("docker", "exec", "supabase-rclone", "rclone", "copyto", remoteRoot+"/WAL_archive.tar.gz", localArchive).Run()
	exec.Command("tar", "-xzf", localArchive, "-C", localBase).Run()
	os.Remove(localArchive)

	meta := scanAndUpload(date, localWalDir, localMeta, remoteRoot, baseTime, tg)
	os.RemoveAll(localWalDir)

	tg.Send(fmt.Sprintf("🩹 Metadata consistency restored for %s (extracted from archive).", date))
	notifySuccess(tg, date, meta)
}

// DATA LOSS LOGIC
func HandleTotalDataLoss(date string, tg *telegram.Service) {
	localMeta := fmt.Sprintf("/app/pitr/supabase-%s_base/metadata.json", date)
	remoteRoot := fmt.Sprintf("dropbox:SupabaseServerBackups_WAL/%s", date)

	tg.Send(fmt.Sprintf("🛑 *CRITICAL DATA LOSS:* No WALs or archives found for %s on Dropbox!", date))

	fakeMeta := api.PitrMetadata{
		Date:            date,
		Continuous:      false,
		MissingSegments: []string{"TOTAL_DATA_LOSS_ON_STORAGE"},
		IsArchived:      false,
	}
	saveAndUploadMetadata(date, localMeta, remoteRoot, fakeMeta)
}

// SHARED HELPER: Scan local files and push metadata
func scanAndUpload(date string, localWalDir, localMeta, remoteRoot string, baseTime time.Time, tg *telegram.Service) api.PitrMetadata {
	entries, _ := os.ReadDir(localWalDir)
	walMap := make(map[string]time.Time)
	
	// Fallback time based on the date string (UTC Midnight)
	fallbackTime, _ := time.Parse("2006-01-02", date)

	for _, f := range entries {
		if len(f.Name()) >= 24 {
			info, err := f.Info()
			if err == nil && info.ModTime().Year() > 2000 {
				walMap[f.Name()] = info.ModTime()
			} else {
				// If we can't get a real time, use the fallback
				walMap[f.Name()] = fallbackTime
			}
		}
	}

	// Calculate continuity
	metadata := api.CalculateContinuity(date, walMap, baseTime)
	
	// If baseTime was missing, ensure we don't show Jan 01
	if metadata.BaseBackupTimestamp.IsZero() {
		metadata.BaseBackupTimestamp = fallbackTime
	}
	if metadata.ValidUntil.IsZero() || metadata.ValidUntil.Year() <= 1 {
		metadata.ValidUntil = fallbackTime
	}

	metadata.IsArchived = true
	metadata.BaseBackup = "base.tar.gz"

	// Save and Upload
	os.MkdirAll(filepath.Dir(localMeta), 0755)
	metaJson, _ := json.MarshalIndent(metadata, "", "  ")
	os.WriteFile(localMeta, metaJson, 0644)
	exec.Command("docker", "exec", "supabase-rclone", "rclone", "copyto", localMeta, remoteRoot+"/metadata.json").Run()
	
	return metadata
}


func saveAndUploadMetadata(date, localPath, remoteRoot string, meta api.PitrMetadata) {
	os.MkdirAll(filepath.Dir(localPath), 0755)
	metaJson, _ := json.MarshalIndent(meta, "", "  ")
	os.WriteFile(localPath, metaJson, 0644)
	exec.Command("docker", "exec", "supabase-rclone", "rclone", "copyto", localPath, remoteRoot+"/metadata.json").Run()
}

func notifySuccess(tg *telegram.Service, date string, meta api.PitrMetadata) {
	status := "✅"
	if !meta.Continuous { status = "⚠️" }
	
	// Improved formatting to prevent "Jan 01" display
	validStr := meta.ValidUntil.Format("Jan 02, 15:04 MST")
	if meta.ValidUntil.Year() <= 2000 {
		validStr = "Date only (Time unknown)"
	}

	msg := fmt.Sprintf("%s *PITR Archive Ready: %s*\n"+
		"• Continuous: %v\n"+
		"• Valid Until: %s",
		status, date,
		meta.Continuous,
		validStr,
	)
	tg.Send(msg)
}
