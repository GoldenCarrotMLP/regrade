package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/robfig/cron/v3"
	"github.com/GoldenCarrotMLP/watchdog/internal/api"
	"github.com/GoldenCarrotMLP/watchdog/internal/monitor"
	"github.com/GoldenCarrotMLP/watchdog/internal/tasks"
	"github.com/GoldenCarrotMLP/watchdog/internal/telegram"
	"github.com/GoldenCarrotMLP/watchdog/internal/worker"
)

func main() {
	tg := telegram.New()
	tg.StartWorker()
	tg.Send("🤖 Watchdog Go-Edition online at " + time.Now().Format(time.RFC822))

	api.StartRedisAPI(tg)
	worker.StartWorkers(tg)
	tasks.StartWALUploader(tg)

	go monitor.WatchDisk(tg)
	go monitor.WatchContainers(tg)
	go monitor.WatchLogs(tg)

	c := cron.New()

	// 1. Logical Backups (Standard snapshots)
	c.AddFunc("0,30 14-23 * * 1-5", func() { tasks.RunFullBackup(tg) })

	// 2. Physical Base Backup (Critical for PITR) - 00:01 UTC
	c.AddFunc("1 0 * * *", func() { tasks.RunDailyBaseBackup(tg) })

	// 3. Archive Yesterday's WALs - 23:59 UTC
	c.AddFunc("5 0 * * *", func() { tasks.RunArchiveYesterday(tg) })

	c.Start()

	// --- STARTUP CHECKS ---
	log.Println("🚀 Watchdog initialized.")

	// A. Ensure we have a Logical Backup (Standard)
	go tasks.RunFullBackup(tg)

	// B. Ensure we have a Physical Base Backup for TODAY (PITR)
	// This ensures if you restart at 10AM, you don't wait 14 hours for a base.
	go tasks.CheckAndRunStartupBaseBackup(tg)

	// C. Check for missing archives from past days
	go tasks.RunStartupBackfill(tg)

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	<-sigChan
	log.Println("🛑 Shutdown signal received")
}