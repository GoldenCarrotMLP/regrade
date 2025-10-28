package main

import (
    "context"
    "database/sql"
    "fmt"
    "log"
    "os"
    "strings"
    "time"
)

type Syncer struct {
    db    *sql.DB
    delay time.Duration
}

func NewSyncer(db *sql.DB, delay time.Duration) *Syncer {
    return &Syncer{db: db, delay: delay}
}

func (s *Syncer) Sync() error {
    ctx := context.Background()

    // whitelist_ips: only from active hosts
    whitelist, err := collectIPs(ctx, s.db, `
        SELECT r.ip
        FROM firewall.resolved_ips r
        JOIN firewall.subdomains s ON r.subdomain_id = s.id
        JOIN firewall.hosts h ON s.host_id = h.id
        WHERE h.active = true
        ORDER BY r.ip`)
    if err != nil {
        return err
    }

    // override_bypass
    bypass, err := collectIPs(ctx, s.db, `
        SELECT ip::text FROM firewall.ip_whitelist
        WHERE active = true ORDER BY ip`)
    if err != nil {
        return err
    }

    // override_block
    block, err := collectIPs(ctx, s.db, `
        SELECT ip::text FROM firewall.ip_whitelist
        WHERE active = false ORDER BY ip`)
    if err != nil {
        return err
    }

    if err := writeSetFile("/app/volumes/firewall/websites_whitelist.nft", "whitelist_ips", whitelist); err != nil {
        return err
    }
    if err := writeSetFile("/app/volumes/firewall/override_bypass.nft", "override_bypass", bypass); err != nil {
        return err
    }
    if err := writeSetFile("/app/volumes/firewall/override_block.nft", "override_block", block); err != nil {
        return err
    }

    log.Printf("[syncer] updated sets: whitelist=%d, bypass=%d, block=%d", len(whitelist), len(bypass), len(block))
    return nil
}

func collectIPs(ctx context.Context, db *sql.DB, query string) ([]string, error) {
    rows, err := db.QueryContext(ctx, query)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var ips []string
    for rows.Next() {
        var ip string
        if err := rows.Scan(&ip); err != nil {
            return nil, err
        }
        ips = append(ips, ip)
    }
    return ips, rows.Err()
}

func writeSetFile(path, setName string, elems []string) error {
    var b strings.Builder
    fmt.Fprintf(&b, "set %s {\n", setName)
    fmt.Fprintln(&b, "    type ipv4_addr")
    fmt.Fprintln(&b, "    flags interval")
    fmt.Fprintln(&b, "    elements = {")

    if len(elems) == 0 {
        fmt.Fprintln(&b, "0.0.0.0/32")
    } else {
        for i, ip := range elems {
            sep := ","
            if i == len(elems)-1 {
                sep = ""
            }
            fmt.Fprintf(&b, "        %s%s\n", ip, sep)
        }
    }

    fmt.Fprintln(&b, "    }")
    fmt.Fprintln(&b, "}")

    newContent := b.String()
    oldContent, err := os.ReadFile(path)
    if err == nil && string(oldContent) == newContent {
        return nil // no change
    }
    return os.WriteFile(path, []byte(newContent), 0644)
}
