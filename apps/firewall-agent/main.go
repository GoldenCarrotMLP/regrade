package main

import (
    "context"
    "database/sql"
    "log"
    "os"
    "os/signal"
    "syscall"
    "time"

    _ "github.com/lib/pq"
)

func main() {
    dbURL := os.Getenv("DATABASE_URL")
    if dbURL == "" {
        log.Fatal("DATABASE_URL not set")
    }

    db, err := sql.Open("postgres", dbURL)
    if err != nil {
        log.Fatalf("DB connection failed: %v", err)
    }
    defer db.Close()

    if err := db.Ping(); err != nil {
        log.Fatalf("DB ping failed: %v", err)
    }

    log.Println("Firewall agent started")

    // Create syncer with 10s debounce
    syncer := NewSyncer(db, 10*time.Second)

    // Run an initial sync immediately at startup
    if err := syncer.Sync(); err != nil {
        log.Printf("[syncer] initial sync error: %v", err)
    }

    // Start listeners
    StartWhitelistListener(dbURL, syncer)
    StartHostsListener(dbURL, syncer)

    // Launch workers in background
    go subfinderWorker(db)
    go dnsWorker(db, syncer)
    go collapseWorker(db)

    // Block until interrupted (graceful shutdown)
    sigs := make(chan os.Signal, 1)
    signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
    <-sigs

    log.Println("Shutting down firewall agent...")
    // If you need cleanup, add it here (cancel contexts, close channels, etc.)
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    _ = db.Close()
    <-ctx.Done()
}