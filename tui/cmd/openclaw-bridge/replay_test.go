package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFilterReplayBatchEmpty(t *testing.T) {
	kept, old, cap := FilterReplayBatch(nil, time.Now(), time.Hour, 50)
	if len(kept) != 0 || old != 0 || cap != 0 {
		t.Fatalf("empty batch: kept=%d old=%d cap=%d", len(kept), old, cap)
	}
}

func TestFilterReplayBatchWindow(t *testing.T) {
	now := time.Unix(10_000_000, 0)
	cutoff := now.Add(-time.Hour).Unix() // 10_000_000 - 3600
	events := []Event{
		{ID: "old1", Ts: cutoff - 100},
		{ID: "old2", Ts: cutoff - 1},
		{ID: "fresh1", Ts: cutoff},
		{ID: "fresh2", Ts: cutoff + 50},
		{ID: "fresh3", Ts: now.Unix()},
	}
	kept, old, cap := FilterReplayBatch(events, now, time.Hour, 50)
	if old != 2 {
		t.Fatalf("skippedOld = %d, want 2", old)
	}
	if cap != 0 {
		t.Fatalf("skippedCap = %d, want 0", cap)
	}
	if len(kept) != 3 {
		t.Fatalf("kept = %d, want 3", len(kept))
	}
	for _, ev := range kept {
		if ev.Ts < cutoff {
			t.Fatalf("kept event %q older than cutoff: ts=%d cutoff=%d", ev.ID, ev.Ts, cutoff)
		}
	}
}

func TestFilterReplayBatchMaxCap(t *testing.T) {
	now := time.Unix(20_000_000, 0)
	events := make([]Event, 100)
	for i := range events {
		events[i] = Event{ID: "e", Ts: now.Unix() - int64(99-i)} // ascending Ts: 99..0 seconds ago
	}
	kept, old, cap := FilterReplayBatch(events, now, time.Hour, 50)
	if old != 0 {
		t.Fatalf("unexpected old skip: %d", old)
	}
	if cap != 50 {
		t.Fatalf("skippedCap = %d, want 50", cap)
	}
	if len(kept) != 50 {
		t.Fatalf("kept = %d, want 50", len(kept))
	}
	// Most recent 50 means seconds-ago 49..0; oldest kept Ts must be now-49.
	want := now.Unix() - 49
	if kept[0].Ts != want {
		t.Fatalf("oldest kept Ts = %d, want %d", kept[0].Ts, want)
	}
	if kept[len(kept)-1].Ts != now.Unix() {
		t.Fatalf("newest kept Ts = %d, want %d", kept[len(kept)-1].Ts, now.Unix())
	}
}

func TestFilterReplayBatchCombined(t *testing.T) {
	now := time.Unix(30_000_000, 0)
	cutoff := now.Add(-time.Hour).Unix()
	var events []Event
	// 20 old (must drop)
	for i := 0; i < 20; i++ {
		events = append(events, Event{ID: "old", Ts: cutoff - int64(i+1)})
	}
	// 80 fresh (cap to 50, drop oldest 30 by ts)
	for i := 0; i < 80; i++ {
		events = append(events, Event{ID: "fresh", Ts: cutoff + int64(i+1)})
	}
	kept, old, cap := FilterReplayBatch(events, now, time.Hour, 50)
	if old != 20 {
		t.Fatalf("skippedOld = %d, want 20", old)
	}
	if cap != 30 {
		t.Fatalf("skippedCap = %d, want 30", cap)
	}
	if len(kept) != 50 {
		t.Fatalf("kept = %d, want 50", len(kept))
	}
}

func TestCursorWriteRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "openclaw-cursor")

	if got := LoadProcessedCursor(path); got != nil {
		t.Fatalf("missing file: want nil, got %+v", got)
	}

	cw := NewCursorWriter(path)
	if err := cw.Write(ProcessedCursor{LastEventID: "evt-42", LastEventTs: 1700000000}); err != nil {
		t.Fatalf("write: %v", err)
	}
	got := LoadProcessedCursor(path)
	if got == nil {
		t.Fatal("read after write returned nil")
	}
	if got.LastEventID != "evt-42" || got.LastEventTs != 1700000000 {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}

func TestCursorMalformedGracefulDegrade(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "openclaw-cursor")
	if err := os.WriteFile(path, []byte("not json {{{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := LoadProcessedCursor(path); got != nil {
		t.Fatalf("malformed file: want nil for graceful degrade, got %+v", got)
	}
}

func TestCursorEmptyPathNoOp(t *testing.T) {
	cw := NewCursorWriter("")
	if cw != nil {
		t.Fatalf("empty path should yield nil writer, got %+v", cw)
	}
	// nil writer Write must be a no-op.
	var nilCW *CursorWriter
	if err := nilCW.Write(ProcessedCursor{LastEventID: "x", LastEventTs: 1}); err != nil {
		t.Fatalf("nil writer should no-op, got err=%v", err)
	}
}

func TestDrainPersistsCursor(t *testing.T) {
	dir := t.TempDir()
	qp := filepath.Join(dir, "q.jsonl")
	lp := filepath.Join(dir, "l.jsonl")
	cp := filepath.Join(dir, "openclaw-cursor")
	q := NewQueueWriter(qp, lp)
	cw := NewCursorWriter(cp)

	sink := make(chan Event, 3)
	sink <- Event{ID: "e1", Body: "b1", Ts: 1000, HMAC: "00"}
	sink <- Event{ID: "e2", Body: "b2", Ts: 2000, HMAC: "00"}
	sink <- Event{ID: "e3", Body: "b3", Ts: 3000, HMAC: "00"}
	close(sink)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := Drain(ctx, sink, stubVerifier{allow: true}, q, cw); err != nil {
		t.Fatalf("drain: %v", err)
	}

	got := LoadProcessedCursor(cp)
	if got == nil {
		t.Fatal("cursor file not written")
	}
	if got.LastEventID != "e3" || got.LastEventTs != 3000 {
		t.Fatalf("cursor at end of drain: %+v, want {e3,3000}", got)
	}

	// File must be valid single-line JSON (consumers may parse with jq/awk).
	raw, err := os.ReadFile(cp)
	if err != nil {
		t.Fatal(err)
	}
	var c ProcessedCursor
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatalf("on-disk file not valid json: %v\nraw=%q", err, raw)
	}
}
