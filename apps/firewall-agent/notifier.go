package main

import (
    "log"
    "time"

    "github.com/lib/pq"
)

func StartWhitelistListener(dbURL string, syncer *Syncer) {
    go startListener(dbURL, "ip_whitelist_changed", syncer)
}

func StartHostsListener(dbURL string, syncer *Syncer) {
    go startListener(dbURL, "hosts_changed", syncer)
	
}

func startListener(dbURL, channel string, syncer *Syncer) {
    listener := pq.NewListener(dbURL, 10*time.Second, time.Minute, nil)
    if err := listener.Listen(channel); err != nil {
        log.Fatalf("[listener] failed to LISTEN %s: %v", channel, err)
    }
    log.Printf("[listener] listening for %s", channel)

    for {
        select {
        case n := <-listener.Notify:
            if n != nil {
                log.Printf("[listener] %s triggered, syncing", channel)
                syncer.Sync()
            }
        case <-time.After(90 * time.Second):
            go func() { _ = listener.Ping() }()
        }
    }
}
