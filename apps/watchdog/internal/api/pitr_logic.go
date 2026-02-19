package api

import (
	"encoding/json"
	"fmt"
	"log"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// In-memory cache for historical metadata
var (
	metadataCache = make(map[string]PitrMetadata)
	cacheMutex    sync.RWMutex
)

// ListPitrDays queries Dropbox for all available recovery folders
func ListPitrDays() ([]DayEntry, error) {
	cmd := exec.Command("docker", "exec", "supabase-rclone", "rclone",
		"lsjson", "--dirs-only", "dropbox:SupabaseServerBackups_WAL/")

	out, err := cmd.Output()
	if err != nil {
		log.Printf("⚠️ [API] Failed to list days from Dropbox: %v", err)
		return []DayEntry{}, nil
	}

	var items []RcloneItem
	if err := json.Unmarshal(out, &items); err != nil {
		return []DayEntry{}, nil
	}

	var days []DayEntry
	for _, item := range items {
		ts := item.ModTime
		// Fix: If Dropbox has no timestamp (Year 2000), parse from name and add 5h for TZ safety
		if ts.Year() <= 2000 {
			if parsed, err := time.Parse("2006-01-02", item.Name); err == nil {
				ts = parsed.Add(5 * time.Hour)
			}
		}
		days = append(days, DayEntry{Date: item.Name, Timestamp: ts})
	}

	sort.Slice(days, func(i, j int) bool {
		return days[i].Date > days[j].Date
	})
	return days, nil
}

// GetContiguousWALRange logic: Cache -> Dropbox Metadata -> Live Dropbox Scan
func GetContiguousWALRange(day string) (PitrMetadata, error) {
	today := time.Now().Format("2006-01-02")

	// 1. Check Memory Cache (Only for past days)
	if day != today {
		cacheMutex.RLock()
		cached, exists := metadataCache[day]
		cacheMutex.RUnlock()
		if exists {
			return cached, nil
		}
	}

	remoteRoot := fmt.Sprintf("dropbox:SupabaseServerBackups_WAL/%s", day)

	// 2. Query Dropbox to check what files exist
	lsCmd := exec.Command("docker", "exec", "supabase-rclone", "rclone", "lsjson", remoteRoot+"/")
	jsonOut, err := lsCmd.Output()
	if err != nil {
		return PitrMetadata{Date: day}, fmt.Errorf("day folder not found on Dropbox")
	}

	var items []RcloneItem
	json.Unmarshal(jsonOut, &items)

	var hasMetadata bool
	var hasBase bool
	var baseTime time.Time

	for _, item := range items {
		if item.Name == "metadata.json" {
			hasMetadata = true
		}
		if item.Name == "base.tar.gz" {
			hasBase = true
			baseTime = item.ModTime
		}
	}

	// 3. If metadata.json exists on Dropbox, read it directly into memory
	if hasMetadata {
		log.Printf("📥 [API] Fetching metadata.json from Dropbox for %s", day)
		catCmd := exec.Command("docker", "exec", "supabase-rclone", "rclone", "cat", remoteRoot+"/metadata.json")
		catOut, err := catCmd.Output()
		if err == nil {
			var m PitrMetadata
			if err := json.Unmarshal(catOut, &m); err == nil {
				// Store in memory cache for future requests
				cacheMutex.Lock()
				metadataCache[day] = m
				cacheMutex.Unlock()
				return m, nil
			}
		}
	}

	// 4. Live Mode (Today or missing metadata): Scan raw WALs on Dropbox
	if !hasBase {
		return PitrMetadata{Date: day, BaseBackup: "NOT_FOUND"}, fmt.Errorf("base.tar.gz missing")
	}

	log.Printf("📡 [API] Calculating live window from Dropbox WALs for %s...", day)
	walMap := make(map[string]time.Time)
	walCmd := exec.Command("docker", "exec", "supabase-rclone", "rclone", "lsjson", remoteRoot+"/WAL/")
	walOut, err := walCmd.Output()
	if err == nil {
		var walItems []RcloneItem
		json.Unmarshal(walOut, &walItems)
		for _, item := range walItems {
			walMap[item.Name] = item.ModTime
		}
	}

	m := CalculateContinuity(day, walMap, baseTime)
	m.IsArchived = false

	// Cache historical days to stop hitting Dropbox, but skip caching "Today"
	if day != today && m.Continuous {
		cacheMutex.Lock()
		metadataCache[day] = m
		cacheMutex.Unlock()
	}

	return m, nil
}

// CalculateContinuity maps WAL names to a sequence and checks for holes
func CalculateContinuity(day string, walMap map[string]time.Time, baseTime time.Time) PitrMetadata {
	var cleanList []string
	for name, modTime := range walMap {
		// Filter non-WAL files
		if strings.HasSuffix(name, ".backup") || strings.HasSuffix(name, ".history") {
			continue
		}
		// Only look at WALs compatible with this base backup (ModTime >= BaseTime)
		if !baseTime.IsZero() && modTime.Before(baseTime.Add(-1*time.Second)) {
			continue
		}

		baseName := name
		if strings.Contains(name, ".partial") {
			baseName = name[:24]
		}
		if len(baseName) == 24 {
			cleanList = append(cleanList, baseName)
		}
	}
	sort.Strings(cleanList)

	meta := PitrMetadata{
		Date:                day,
		BaseBackupTimestamp: baseTime,
		Continuous:          true,
		MissingSegments:     []string{},
		IsArchived:          false,
		BaseBackup:          "base.tar.gz",
	}

	if len(cleanList) == 0 {
		if !baseTime.IsZero() {
			meta.ValidUntil = baseTime
			meta.WalStartTimestamp = baseTime
			meta.WalEndTimestamp = baseTime
		}
		return meta
	}

	tl, _ := strconv.ParseInt(cleanList[0][:8], 16, 64)
	meta.Timeline = int(tl)
	meta.WalStartSegment = cleanList[0]
	meta.WalEndSegment = cleanList[len(cleanList)-1]
	meta.WalStartTimestamp = findTimestamp(cleanList[0], walMap)
	meta.WalEndTimestamp = findTimestamp(cleanList[len(cleanList)-1], walMap)
	meta.ValidUntil = meta.WalEndTimestamp

	current := cleanList[0]
	for i := 1; i < len(cleanList); i++ {
		expected := nextWALName(current)
		if cleanList[i] != expected {
			meta.Continuous = false
			meta.MissingSegments = append(meta.MissingSegments, expected)
			meta.WalEndSegment = current
			meta.ValidUntil = findTimestamp(current, walMap)
			return meta
		}
		current = cleanList[i]
	}

	return meta
}

func findTimestamp(normalizedName string, walMap map[string]time.Time) time.Time {
	for originalName, t := range walMap {
		if strings.HasPrefix(originalName, normalizedName) {
			return t
		}
	}
	return time.Time{}
}

func nextWALName(name string) string {
	prefix := name[:16]
	suffix := name[16:]
	var val uint64
	fmt.Sscanf(suffix, "%X", &val)
	val++
	return fmt.Sprintf("%s%08X", prefix, val)
}