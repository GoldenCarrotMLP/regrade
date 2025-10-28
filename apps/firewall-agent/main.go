package main

import (
    "database/sql"
    "log"
    "os"
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

    // Start listener for ip_whitelist changes
StartWhitelistListener(dbURL, syncer)
StartHostsListener(dbURL, syncer)


    // Launch workers
    go subfinderWorker(db)   // runs in background
    dnsWorker(db, syncer)    // runs in foreground
}
