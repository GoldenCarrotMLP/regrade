package api

import "time"

type RcloneItem struct {
	Name    string    `json:"Name"`
	IsDir   bool      `json:"IsDir"`
	Size    int64     `json:"Size"`
	ModTime time.Time `json:"ModTime"`
}

type PitrMetadata struct {
	Date                string    `json:"date"`
	BaseBackup          string    `json:"base_backup"`
	BaseBackupTimestamp time.Time `json:"base_backup_timestamp"` // The "Start" gate
	Timeline            int       `json:"timeline"`
	WalStartSegment     string    `json:"wal_start_segment"`
	WalEndSegment       string    `json:"wal_end_segment"`
	WalStartTimestamp   time.Time `json:"wal_start_timestamp"`
	WalEndTimestamp     time.Time `json:"wal_end_timestamp"`
	Continuous          bool      `json:"continuous"`
	MissingSegments     []string  `json:"missing_segments"`
	ValidUntil          time.Time `json:"valid_until"`
	IsArchived          bool      `json:"is_archived"`
}
type DayEntry struct {
	Date      string    `json:"date"`
	Timestamp time.Time `json:"timestamp"`
}

type SnapshotFile struct {
	Filename  string `json:"filename"`
	Size      string `json:"size"`
	Timestamp string `json:"timestamp"`
}

type RedisRequest struct {
	CorrelationID string `json:"correlation_id"`
	Action        string `json:"action"`
	Day           string `json:"day,omitempty"`
}

type RedisResponse struct {
	CorrelationID string      `json:"correlation_id"`
	Ok            bool        `json:"ok"`
	Data          interface{} `json:"data"`
	Error         string      `json:"error,omitempty"`
}