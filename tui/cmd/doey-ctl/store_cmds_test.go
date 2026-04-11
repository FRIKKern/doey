package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/doey-cli/doey/tui/internal/store"
)

// TestDoeyCtlEventLogNewFlags exercises the eventLog handler end-to-end:
// pre-creates a tempdir .doey/doey.db, invokes the handler with the 10
// new task #525 flags, then round-trips through store.ListEventsByClass
// to confirm the values were persisted via the new schema columns.
func TestDoeyCtlEventLogNewFlags(t *testing.T) {
	dir := t.TempDir()
	doeyDir := filepath.Join(dir, ".doey")
	if err := os.MkdirAll(doeyDir, 0o755); err != nil {
		t.Fatal(err)
	}
	dbPath := filepath.Join(doeyDir, "doey.db")

	// Pre-create the DB so eventLog's tryOpenStore finds it.
	s, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()

	// Reset global jsonOutput (test isolation — other tests in this
	// package may flip it via flag binding).
	jsonOutput = false

	eventLog([]string{
		"--project-dir", dir,
		"--class", store.ViolationPolling,
		"--severity", "warn",
		"--session", "doey-test",
		"--role", "subtaskmaster",
		"--window-id", "W2",
		"--wake-reason", "MSG",
		"--consecutive", "3",
		"--window-sec", "45",
		"--unread-msg-ids", "1,2,3",
		"--extra-json", `{"foo":"bar"}`,
	})

	s2, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()

	events, err := s2.ListEventsByClass(store.ViolationPolling, 10)
	if err != nil {
		t.Fatalf("ListEventsByClass: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("events = %d, want 1", len(events))
	}
	e := events[0]
	if e.Class != store.ViolationPolling {
		t.Errorf("class = %q, want %q", e.Class, store.ViolationPolling)
	}
	if e.Type != store.ViolationPolling {
		t.Errorf("type = %q, want %q (--class fallback path)", e.Type, store.ViolationPolling)
	}
	if e.Severity != "warn" {
		t.Errorf("severity = %q, want warn", e.Severity)
	}
	if e.Session != "doey-test" {
		t.Errorf("session = %q", e.Session)
	}
	if e.Role != "subtaskmaster" {
		t.Errorf("role = %q", e.Role)
	}
	if e.WindowID != "W2" {
		t.Errorf("window_id = %q", e.WindowID)
	}
	if e.WakeReason != "MSG" {
		t.Errorf("wake_reason = %q", e.WakeReason)
	}
	if e.ConsecutiveCount != 3 {
		t.Errorf("consecutive_count = %d, want 3", e.ConsecutiveCount)
	}
	if e.WindowSec != 45 {
		t.Errorf("window_sec = %d, want 45", e.WindowSec)
	}
	if e.UnreadMsgIDs != "1,2,3" {
		t.Errorf("unread_msg_ids = %q", e.UnreadMsgIDs)
	}
	if e.ExtraJSON != `{"foo":"bar"}` {
		t.Errorf("extra_json = %q", e.ExtraJSON)
	}
}
