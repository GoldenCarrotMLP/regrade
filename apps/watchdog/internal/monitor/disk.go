package monitor

import (
	"fmt"
	"syscall"
	"log"
	"time"

	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
)

// WatchDisk replaces diskwatch.sh
func WatchDisk(tg *telegram.Service) {
	const minFreeGB = 100
	ticker := time.NewTicker(1 * time.Minute)

	for range ticker.C {
		var stat syscall.Statfs_t
		if err := syscall.Statfs("/", &stat); err != nil {
			log.Println("Error checking disk:", err)
			continue
		}

		// Available blocks * size / 1024^3
		freeGB := (stat.Bavail * uint64(stat.Bsize)) / (1024 * 1024 * 1024)
		usedPct := 100 - ((stat.Bavail * 100) / stat.Blocks)

		if freeGB < minFreeGB {
			// Simple logic: no more awkward awk math
			msg := fmt.Sprintf("🚨 [DISKWATCH] Low Space: %dGB free (%d%% used)", freeGB, usedPct)
			tg.Send(msg)
			
			// Dynamic backoff can be implemented here easily using time.Sleep
			if freeGB < 10 {
				time.Sleep(10 * time.Minute) // Panic mode: alert often
			} else {
				time.Sleep(1 * time.Hour)    // Warning mode: alert hourly
			}
		}
	}
}