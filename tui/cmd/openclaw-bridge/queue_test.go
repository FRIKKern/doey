package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestQueueAppend(t *testing.T) {
	dir := t.TempDir()
	qp := filepath.Join(dir, "inbound-queue.jsonl")
	lp := filepath.Join(dir, "openclaw-nonces.jsonl")
	q := NewQueueWriter(qp, lp)

	events := []Event{
		{ID: "1", SenderID: "alice", Body: "hello", Ts: 1, HMAC: "deadbeef", Nonce: "0123456789abcdef"},
		{ID: "2", SenderID: "bob", Body: "world", Ts: 2, HMAC: "feedface", Nonce: "fedcba9876543210"},
	}
	for _, ev := range events {
		if err := q.Append(ev); err != nil {
			t.Fatalf("append: %v", err)
		}
	}

	f, err := os.Open(qp)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	got := []Event{}
	for sc.Scan() {
		var ev Event
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		got = append(got, ev)
	}
	if sc.Err() != nil {
		t.Fatal(sc.Err())
	}
	if len(got) != len(events) {
		t.Fatalf("line count = %d, want %d", len(got), len(events))
	}
	for i := range events {
		if got[i] != events[i] {
			t.Fatalf("row %d mismatch:\n got=%+v\nwant=%+v", i, got[i], events[i])
		}
	}
}

func TestQueueConcurrentAppend(t *testing.T) {
	dir := t.TempDir()
	qp := filepath.Join(dir, "inbound-queue.jsonl")
	lp := filepath.Join(dir, "openclaw-nonces.jsonl")
	q := NewQueueWriter(qp, lp)

	const goroutines = 10
	const perGoroutine = 100
	var wg sync.WaitGroup
	wg.Add(goroutines)
	for g := 0; g < goroutines; g++ {
		go func(g int) {
			defer wg.Done()
			for i := 0; i < perGoroutine; i++ {
				ev := Event{
					ID:       fmt.Sprintf("g%d-i%d", g, i),
					SenderID: "tester",
					Body:     fmt.Sprintf("body-%d-%d", g, i),
					Ts:       int64(g*1000 + i),
					HMAC:     "00",
					Nonce:    "0000000000000000",
				}
				if err := q.Append(ev); err != nil {
					t.Errorf("append: %v", err)
					return
				}
			}
		}(g)
	}
	wg.Wait()

	f, err := os.Open(qp)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	count := 0
	for sc.Scan() {
		var ev Event
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			t.Fatalf("corrupted line %d: %v\nraw=%q", count, err, sc.Text())
		}
		count++
	}
	if sc.Err() != nil {
		t.Fatal(sc.Err())
	}
	if count != goroutines*perGoroutine {
		t.Fatalf("line count = %d, want %d", count, goroutines*perGoroutine)
	}
}

func TestQueueRememberNonceRotate(t *testing.T) {
	dir := t.TempDir()
	qp := filepath.Join(dir, "inbound-queue.jsonl")
	lp := filepath.Join(dir, "openclaw-nonces.jsonl")
	q := NewQueueWriter(qp, lp)

	// Write 1000 entries — should fit in the active ledger.
	for i := 0; i < ledgerMaxEntries; i++ {
		n, err := GenerateNonce()
		if err != nil {
			t.Fatal(err)
		}
		if err := q.RememberNonce(n, int64(i)); err != nil {
			t.Fatalf("remember %d: %v", i, err)
		}
	}
	if _, err := os.Stat(lp + ".prev"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf(".prev should not exist yet, got err=%v", err)
	}

	// Entry #1001 must trigger a rotation.
	n, err := GenerateNonce()
	if err != nil {
		t.Fatal(err)
	}
	if err := q.RememberNonce(n, 999_999); err != nil {
		t.Fatalf("remember overflow: %v", err)
	}

	// .prev must now exist with 1000 entries; active must have 1.
	prevCount, err := countLines(lp + ".prev")
	if err != nil {
		t.Fatal(err)
	}
	if prevCount != ledgerMaxEntries {
		t.Fatalf(".prev line count = %d, want %d", prevCount, ledgerMaxEntries)
	}
	activeCount, err := countLines(lp)
	if err != nil {
		t.Fatal(err)
	}
	if activeCount != 1 {
		t.Fatalf("active line count = %d, want 1", activeCount)
	}
}

func TestQueueRememberNonceRejectsInvalid(t *testing.T) {
	dir := t.TempDir()
	q := NewQueueWriter(filepath.Join(dir, "q"), filepath.Join(dir, "l"))
	if err := q.RememberNonce("notvalid", 1); err == nil {
		t.Fatal("expected error for invalid nonce")
	}
}

// stubVerifier is used to exercise Drain without depending on a real HMAC secret.
type stubVerifier struct {
	allow bool
}

func (s stubVerifier) Verify(body string, ts int64, hmacHex string) error {
	if s.allow {
		return nil
	}
	return ErrHMACMismatch
}

func TestQueueDrainSuccess(t *testing.T) {
	dir := t.TempDir()
	qp := filepath.Join(dir, "q.jsonl")
	lp := filepath.Join(dir, "l.jsonl")
	q := NewQueueWriter(qp, lp)

	sink := make(chan Event, 4)
	sink <- Event{ID: "a", SenderID: "s", Body: "b1", Ts: 1, HMAC: "00"}
	sink <- Event{ID: "b", SenderID: "s", Body: "b2", Ts: 2, HMAC: "00"}
	close(sink)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := Drain(ctx, sink, stubVerifier{allow: true}, q); err != nil {
		t.Fatalf("drain: %v", err)
	}

	queueLines, _ := countLines(qp)
	if queueLines != 2 {
		t.Fatalf("queue lines = %d, want 2", queueLines)
	}
	ledgerLines, _ := countLines(lp)
	if ledgerLines != 2 {
		t.Fatalf("ledger lines = %d, want 2", ledgerLines)
	}

	// Verify each queue row has a valid nonce assigned.
	f, err := os.Open(qp)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var ev Event
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			t.Fatal(err)
		}
		if !validNonce(ev.Nonce) {
			t.Fatalf("event %s missing valid nonce: %q", ev.ID, ev.Nonce)
		}
	}
}

func TestQueueDrainDropsBadHMAC(t *testing.T) {
	dir := t.TempDir()
	qp := filepath.Join(dir, "q.jsonl")
	lp := filepath.Join(dir, "l.jsonl")
	q := NewQueueWriter(qp, lp)

	sink := make(chan Event, 2)
	sink <- Event{ID: "bad", Body: "b", Ts: 1, HMAC: "00"}
	close(sink)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = Drain(ctx, sink, stubVerifier{allow: false}, q)

	if n, _ := countLines(qp); n != 0 {
		t.Fatalf("queue should be empty for dropped events, got %d", n)
	}
	if n, _ := countLines(lp); n != 0 {
		t.Fatalf("ledger should be empty when nothing enqueued, got %d", n)
	}
}
