package main

import (
    "context"
    "database/sql"
    "fmt"
    "log"
    "net"
    "os"
    "os/exec"
    "strings"
    "sync"
    "time"

    "github.com/apparentlymart/go-cidr/cidr"
)

type Host struct {
    ID       int
    Hostname string
}

type Subdomain struct {
    ID   int
    Name string
}

// --- Subfinder worker ---

func subfinderWorker(db *sql.DB) {
    ticker := time.NewTicker(10 * time.Minute)
    defer ticker.Stop()

    for {
        if err := discoverAndInsertSubdomains(db); err != nil {
            log.Printf("[subfinder] error: %v", err)
        }
        <-ticker.C
    }
}

func discoverAndInsertSubdomains(db *sql.DB) error {
    ctx := context.Background()
    hosts, err := fetchActiveHosts(ctx, db)
    if err != nil {
        return err
    }

    skipFile, err := os.CreateTemp("", "skip-subdomains-*.txt")
    if err != nil {
        return fmt.Errorf("failed to create skip file: %w", err)
    }
    defer os.Remove(skipFile.Name())

    rows, err := db.QueryContext(ctx, `SELECT subdomain FROM firewall.subdomains`)
    if err != nil {
        return err
    }
    defer rows.Close()
    for rows.Next() {
        var sub string
        if err := rows.Scan(&sub); err != nil {
            return err
        }
        _, _ = skipFile.WriteString(sub + "\n")
    }
    skipFile.Close()

    for _, h := range hosts {
        subs, err := discoverSubdomains(h.Hostname, skipFile.Name())
        if err != nil {
            continue
        }
        for _, sub := range subs {
            res, err := db.ExecContext(ctx, `
                INSERT INTO firewall.subdomains (host_id, subdomain)
                VALUES ($1, $2)
                ON CONFLICT (host_id, subdomain) DO NOTHING
            `, h.ID, sub)
            if err == nil {
                if rows, _ := res.RowsAffected(); rows > 0 {
                    log.Printf("[subfinder] inserted subdomain %s for host %s", sub, h.Hostname)
                }
            }
        }
    }
    return nil
}

func fetchActiveHosts(ctx context.Context, db *sql.DB) ([]Host, error) {
    rows, err := db.QueryContext(ctx, `
        SELECT id, hostname
        FROM firewall.hosts
        WHERE active = true
    `)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var hosts []Host
    for rows.Next() {
        var h Host
        if err := rows.Scan(&h.ID, &h.Hostname); err != nil {
            return nil, err
        }
        hosts = append(hosts, h)
    }
    return hosts, rows.Err()
}

func discoverSubdomains(domain, skipFile string) ([]string, error) {
    cmd := exec.Command("subfinder", "-d", domain, "-silent", "-f", skipFile)
    out, err := cmd.Output()
    if err != nil {
        return nil, fmt.Errorf("subfinder failed for %s: %w", domain, err)
    }

    lines := strings.Split(string(out), "\n")
    results := []string{}
    for _, line := range lines {
        sub := strings.TrimSpace(line)
        if sub != "" {
            results = append(results, sub)
        }
    }
    return results, nil
}

// --- DNS worker ---

func dnsWorker(db *sql.DB, syncer *Syncer) {
    subs, err := fetchAllSubdomains(db)
    if err != nil {
        log.Fatalf("[dns] fetch subdomains failed: %v", err)
    }

    var wg sync.WaitGroup
    delay := 1 * time.Second

    for i, sub := range subs {
        wg.Add(1)
        go func(s Subdomain) {
            defer wg.Done()
            resolveAndInsert(db, s, syncer)
        }(sub)

        time.Sleep(delay)

        if (i+1)%100 == 0 {
            log.Printf("[dns] launched %d workers so far", i+1)
        }
    }

    wg.Wait()
}

func fetchAllSubdomains(db *sql.DB) ([]Subdomain, error) {
    rows, err := db.Query(`
        SELECT id, subdomain
        FROM firewall.subdomains
        WHERE active = true
        ORDER BY resolved_at NULLS FIRST, resolved_at ASC
    `)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var subs []Subdomain
    for rows.Next() {
        var s Subdomain
        if err := rows.Scan(&s.ID, &s.Name); err != nil {
            return nil, err
        }
        subs = append(subs, s)
    }
    return subs, rows.Err()
}

func resolveAndInsert(db *sql.DB, sub Subdomain, syncer *Syncer) {
    ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
    defer cancel()

    ips, err := net.DefaultResolver.LookupIP(ctx, "ip4", sub.Name)
    if err != nil {
        _, _ = db.Exec(`UPDATE firewall.subdomains SET active = false, resolved_at = NOW() WHERE id = $1`, sub.ID)
        return
    }

    for _, ip := range ips {
        cidr := fmt.Sprintf("%s/32", ip.String())

        // containment check
        var exists bool
        err := db.QueryRow(`
            SELECT EXISTS (
                SELECT 1 FROM firewall.resolved_ips
                WHERE subdomain_id = $1
                  AND ip >>= $2::cidr
            )`, sub.ID, cidr).Scan(&exists)
        if err != nil {
            log.Printf("[dns] containment check failed for %s: %v", cidr, err)
            continue
        }
        if exists {
            continue
        }

        res, err := db.Exec(`
            INSERT INTO firewall.resolved_ips (subdomain_id, ip, last_resolved)
            VALUES ($1, $2, NOW())
            ON CONFLICT (subdomain_id, ip)
            DO UPDATE SET last_resolved = EXCLUDED.last_resolved
        `, sub.ID, cidr)
        if err == nil {
            if rows, _ := res.RowsAffected(); rows > 0 {
                syncer.Sync()
            }
        } else {
            log.Printf("[dns] insert failed for %s: %v", cidr, err)
        }
    }

    _, _ = db.Exec(`UPDATE firewall.subdomains SET resolved_at = NOW() WHERE id = $1`, sub.ID)
}

// --- Collapse worker ---

func collapseWorker(db *sql.DB) {
    ticker := time.NewTicker(30 * time.Minute)
    defer ticker.Stop()

    for {
        subs, err := fetchAllSubdomains(db)
        if err != nil {
            log.Printf("[collapse] fetch subdomains failed: %v", err)
            <-ticker.C
            continue
        }

        for _, sub := range subs {
            if err := collapseSubdomainRanges(db, sub.ID); err != nil {
                log.Printf("[collapse] error collapsing %s: %v", sub.Name, err)
            }
        }

        <-ticker.C
    }
}

func collapseSubdomainRanges(db *sql.DB, subdomainID int) error {
    rows, err := db.Query(`SELECT ip::text FROM firewall.resolved_ips WHERE subdomain_id=$1`, subdomainID)
    if err != nil {
        return err
    }
    defer rows.Close()

    var nets []*net.IPNet
    for rows.Next() {
        var s string
        rows.Scan(&s)
        _, n, _ := net.ParseCIDR(s)
        nets = append(nets, n)
    }

    if len(nets) == 0 {
        return nil
    }

    collapsed := cidr.MergeCIDRs(nets)

    var limited []*net.IPNet
    for _, n := range collapsed {
        ones, bits := n.Mask.Size()
        if bits == 32 && ones < 16 {
            base := n.IP.Mask(net.CIDRMask(16, 32))
            _, c, _ := net.ParseCIDR(base.String() + "/16")
            limited = append(limited, c)
        } else {
            limited = append(limited, n)
        }
    }

    tx, _ := db.Begin()
    _, _ = tx.Exec(`DELETE FROM firewall.resolved_ips WHERE subdomain_id=$1`, subdomainID)
    for _, c := range limited {
        _, err := tx.Exec(`
            INSERT INTO firewall.resolved_ips (subdomain_id, ip, last_resolved)
            VALUES ($1, $2, NOW())
        `, subdomainID, c.String())
        if err != nil {
            tx.Rollback()
            return err
        }
    }
    return tx.Commit()
}
