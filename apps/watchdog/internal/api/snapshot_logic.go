package api

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"strings"
	"time"
)

func ListSnapshotDays() ([]DayEntry, error) {
	cmd := exec.Command("docker", "exec", "supabase-rclone", "rclone", 
		"lsjson", "--dirs-only", "dropbox:SupabaseServerBackups")
	
	out, err := cmd.Output()
	if err != nil {
		return []DayEntry{}, nil
	}

	var items []RcloneItem
	if err := json.Unmarshal(out, &items); err != nil {
		return []DayEntry{}, nil
	}

	var days []DayEntry
	for _, item := range items {
		ts := item.ModTime
		
		if ts.Year() <= 2000 {
			if parsed, err := time.Parse("2006-01-02", item.Name); err == nil {
				// Add 5 hours to match your request: T05:00:00Z
				ts = parsed.Add(5 * time.Hour)
			}
		}

		days = append(days, DayEntry{
			Date:      item.Name,
			Timestamp: ts,
		})
	}

	sort.Slice(days, func(i, j int) bool {
		return days[i].Date > days[j].Date
	})

	return days, nil
}




func ListSnapshotFiles(day string) ([]SnapshotFile, error) {
	remotePath := fmt.Sprintf("dropbox:SupabaseServerBackups/%s", day)
	cmd := exec.Command("docker", "exec", "supabase-rclone", "rclone", "lsf", "--format", "ps", remotePath)
	out, err := cmd.Output()
	if err != nil {
		return []SnapshotFile{}, nil
	}

	var files []SnapshotFile
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	for _, line := range lines {
		parts := strings.Fields(line)
		if len(parts) < 2 {
			continue
		}
		
		filename := parts[0]
		timestamp := ""
		if strings.Contains(filename, "_") {
			tsParts := strings.Split(filename, "_")
			timestamp = strings.TrimSuffix(tsParts[len(tsParts)-1], ".sql.gz")
		}

		files = append(files, SnapshotFile{
			Filename:  filename,
			Size:      parts[1],
			Timestamp: timestamp,
		})
	}
	return files, nil
}