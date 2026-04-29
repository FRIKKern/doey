package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"sync"
)

// Event is the canonical inbound event shape used across openclaw-bridge.
// The gateway emits {id, sender_id, body, ts, hmac}; Drain assigns Nonce
// locally before appending to the queue.
type Event struct {
	ID       string `json:"msg_id"`
	SenderID string `json:"sender_id"`
	Body     string `json:"body"`
	Ts       int64  `json:"ts"`
	HMAC     string `json:"hmac"`
	Nonce    string `json:"nonce,omitempty"`
}

// Verifier is the inbound message verifier interface; HMACVerifier (hmac.go)
// implements it.
type Verifier interface {
	Verify(body string, ts int64, hmacHex string) error
}

const ledgerMaxEntries = 1000

// QueueWriter appends inbound events to a JSONL file and tracks issued nonces in a
// rotating ledger. Single-writer; the bridge daemon holds a global lock so cross-process
// contention is impossible. The internal mutex covers in-process goroutine concurrency.
type QueueWriter struct {
	path       string
	ledgerPath string
	mu         sync.Mutex

	// in-memory ledger row count to amortize line counting on append.
	ledgerCount int
	ledgerInit  bool
}

// NewQueueWriter constructs a writer for the given queue and nonce-ledger paths.
func NewQueueWriter(queuePath, nonceLedgerPath string) *QueueWriter {
	return &QueueWriter{path: queuePath, ledgerPath: nonceLedgerPath}
}

// Append writes one Event as a single JSON line atomically.
func (q *QueueWriter) Append(ev Event) error {
	line, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("queue marshal: %w", err)
	}
	line = append(line, '\n')

	q.mu.Lock()
	defer q.mu.Unlock()

	f, err := os.OpenFile(q.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("queue open: %w", err)
	}
	defer f.Close()
	if _, err := f.Write(line); err != nil {
		return fmt.Errorf("queue write: %w", err)
	}
	return nil
}

// RememberNonce appends {"nonce":"<hex16>","ts":<unix>} to the ledger, rotating
// to <ledgerPath>.prev when the active file would exceed ledgerMaxEntries.
func (q *QueueWriter) RememberNonce(nonce string, ts int64) error {
	if !validNonce(nonce) {
		return errors.New("ledger: invalid nonce")
	}
	row := struct {
		Nonce string `json:"nonce"`
		Ts    int64  `json:"ts"`
	}{Nonce: nonce, Ts: ts}
	line, err := json.Marshal(row)
	if err != nil {
		return fmt.Errorf("ledger marshal: %w", err)
	}
	line = append(line, '\n')

	q.mu.Lock()
	defer q.mu.Unlock()

	if !q.ledgerInit {
		n, err := countLines(q.ledgerPath)
		if err != nil {
			return fmt.Errorf("ledger count: %w", err)
		}
		q.ledgerCount = n
		q.ledgerInit = true
	}

	if q.ledgerCount >= ledgerMaxEntries {
		// Rotate: rename active → .prev (overwrite), reset counter.
		prev := q.ledgerPath + ".prev"
		if _, err := os.Stat(q.ledgerPath); err == nil {
			if err := os.Rename(q.ledgerPath, prev); err != nil {
				return fmt.Errorf("ledger rotate: %w", err)
			}
		}
		q.ledgerCount = 0
	}

	f, err := os.OpenFile(q.ledgerPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("ledger open: %w", err)
	}
	defer f.Close()
	if _, err := f.Write(line); err != nil {
		return fmt.Errorf("ledger write: %w", err)
	}
	q.ledgerCount++
	return nil
}

func countLines(path string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		n++
	}
	if err := sc.Err(); err != nil {
		return 0, err
	}
	return n, nil
}

// Drain consumes events from sink, verifies HMAC, frames with a fresh nonce,
// records the nonce, and appends to the queue. On verification failure the
// event is logged to stderr and dropped. After each successful Append, the
// processed-cursor (if cw is non-nil) is updated so a subsequent reconnect can
// bound replay to events newer than this point. Returns when ctx is canceled
// or sink is closed.
func Drain(ctx context.Context, sink <-chan Event, v Verifier, q *QueueWriter, cw *CursorWriter) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case ev, ok := <-sink:
			if !ok {
				return nil
			}
			if err := v.Verify(ev.Body, ev.Ts, ev.HMAC); err != nil {
				log.Printf("openclaw-bridge: drop event id=%s sender=%s: %v", ev.ID, ev.SenderID, err)
				continue
			}
			nonce, err := GenerateNonce()
			if err != nil {
				log.Printf("openclaw-bridge: nonce generation failed: %v", err)
				continue
			}
			ev.Nonce = nonce
			if err := q.RememberNonce(nonce, ev.Ts); err != nil {
				log.Printf("openclaw-bridge: ledger append failed: %v", err)
				continue
			}
			if err := q.Append(ev); err != nil {
				log.Printf("openclaw-bridge: queue append failed: %v", err)
				continue
			}
			if err := cw.Write(ProcessedCursor{LastEventID: ev.ID, LastEventTs: ev.Ts}); err != nil {
				log.Printf("openclaw-bridge: processed-cursor write failed (non-fatal): %v", err)
			}
		}
	}
}
