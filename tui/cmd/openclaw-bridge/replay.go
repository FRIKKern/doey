package main

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"sort"
	"sync"
	"time"
)

// Replay caps. The bridge applies these to the first non-empty batch after a
// (re)connect — i.e. when draining the gateway's buffered backlog. Subsequent
// batches in steady-state pass through untouched.
const (
	ReplayMaxEvents = 50
	ReplayWindow    = time.Hour
)

// ProcessedCursor records the most recent event the Drain pipeline
// successfully appended to the inbound queue. Persisted as a single-line JSON
// document at /tmp/doey/<project>/openclaw-cursor. Missing/malformed file is
// treated as "no replay state" so older bridge versions (and fresh installs)
// degrade gracefully to no-replay.
type ProcessedCursor struct {
	LastEventID string `json:"last_event_id"`
	LastEventTs int64  `json:"last_event_ts_unix"`
}

// CursorWriter persists ProcessedCursor atomically (tmp + fsync + rename). The
// in-memory mutex protects concurrent writers; in practice Drain is the only
// caller.
type CursorWriter struct {
	path string
	mu   sync.Mutex
}

// NewCursorWriter returns nil when path is empty so callers can disable
// persistence by passing an empty path.
func NewCursorWriter(path string) *CursorWriter {
	if path == "" {
		return nil
	}
	return &CursorWriter{path: path}
}

func (w *CursorWriter) Write(c ProcessedCursor) error {
	if w == nil || w.path == "" {
		return nil
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	w.mu.Lock()
	defer w.mu.Unlock()
	return writeAtomic(w.path, b)
}

// LoadProcessedCursor returns the persisted cursor or nil if the file is
// missing/unreadable/malformed. Non-ENOENT read errors are logged but
// non-fatal: bridge falls back to no-replay semantics (graceful degrade per
// subtask #3 instruction 5).
func LoadProcessedCursor(path string) *ProcessedCursor {
	if path == "" {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("openclaw-bridge: processed-cursor unreadable: %v", err)
		}
		return nil
	}
	var c ProcessedCursor
	if err := json.Unmarshal(b, &c); err != nil {
		log.Printf("openclaw-bridge: processed-cursor malformed (graceful skip): %v", err)
		return nil
	}
	return &c
}

// FilterReplayBatch trims a batch of events to the replay caps:
//   1. Drop events with Ts older than now-window (skippedOld).
//   2. Cap the survivors to maxEvents most-recent (skippedCap).
//
// Returned slice preserves Ts-ascending order of the kept events. maxEvents<=0
// disables the count cap (window cap still applies).
func FilterReplayBatch(events []Event, now time.Time, window time.Duration, maxEvents int) (kept []Event, skippedOld, skippedCap int) {
	if len(events) == 0 {
		return nil, 0, 0
	}
	cutoff := now.Add(-window).Unix()
	kept = make([]Event, 0, len(events))
	for _, ev := range events {
		if ev.Ts < cutoff {
			skippedOld++
			continue
		}
		kept = append(kept, ev)
	}
	if maxEvents > 0 && len(kept) > maxEvents {
		sort.SliceStable(kept, func(i, j int) bool { return kept[i].Ts < kept[j].Ts })
		skippedCap = len(kept) - maxEvents
		kept = kept[skippedCap:]
	}
	return kept, skippedOld, skippedCap
}
