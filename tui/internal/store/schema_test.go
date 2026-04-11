package store

import (
	"database/sql"
	"path/filepath"
	"testing"
)

// TestJSON1Available is insurance against the modernc.org/sqlite build
// being shipped without the JSON1 extension. The 525 violation schema
// stores extra_json as TEXT and downstream readers may rely on
// json_extract(); a hard failure here is preferable to a runtime crash
// in production.
func TestJSON1Available(t *testing.T) {
	s := testStore(t)
	var result string
	if err := s.db.QueryRow(`SELECT json_extract('{"a":1}', '$.a')`).Scan(&result); err != nil {
		t.Fatalf("json_extract: %v", err)
	}
	if result != "1" {
		t.Errorf("json_extract result = %q, want %q", result, "1")
	}
}

// TestEventsColumnCachePartialDB simulates an older binary opening a
// pre-525 database (events table has only the original 7 columns). The
// dynamic SELECT/INSERT builders in events.go must restrict themselves
// to columns present in s.eventsCols and yield zero-value Event fields
// for the missing 525 columns instead of crashing with "no such column".
func TestEventsColumnCachePartialDB(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "partial.db")

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE events (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		type TEXT,
		source TEXT,
		target TEXT,
		task_id INTEGER,
		data TEXT,
		created_at INTEGER
	)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO events (type, source, target, data, created_at)
		VALUES ('test_event', 'w1.1', '', 'body', 12345)`); err != nil {
		t.Fatal(err)
	}

	// Construct a Store directly with an events column cache restricted
	// to the original schema. This bypasses Open() — which would run the
	// 525 migration and add the new columns — to exercise the
	// pre-migration code path.
	s := &Store{
		db:   db,
		path: dbPath,
		eventsCols: map[string]bool{
			"id":         true,
			"type":       true,
			"source":     true,
			"target":     true,
			"task_id":    true,
			"data":       true,
			"created_at": true,
		},
	}
	defer s.Close()

	events, err := s.ListEvents("", 10)
	if err != nil {
		t.Fatalf("ListEvents on partial DB: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("events = %d, want 1", len(events))
	}
	if events[0].Type != "test_event" {
		t.Errorf("type = %q, want test_event", events[0].Type)
	}
	if events[0].Class != "" {
		t.Errorf("class on partial DB should be zero-value, got %q", events[0].Class)
	}
	if events[0].ConsecutiveCount != 0 {
		t.Errorf("consecutive_count on partial DB should be 0, got %d", events[0].ConsecutiveCount)
	}

	// LogEvent on partial DB must also work — new fields silently dropped.
	if _, err := s.LogEvent(&Event{
		Type:     "second_event",
		Source:   "w1.2",
		Class:    "violation_polling",
		Severity: "warn",
	}); err != nil {
		t.Fatalf("LogEvent on partial DB: %v", err)
	}
	all, err := s.ListEvents("", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 2 {
		t.Fatalf("after second insert events = %d, want 2", len(all))
	}

	// ListEventsByClass on partial DB returns empty (no class column).
	byClass, err := s.ListEventsByClass(ViolationPolling, 10)
	if err != nil {
		t.Fatalf("ListEventsByClass on partial DB: %v", err)
	}
	if len(byClass) != 0 {
		t.Errorf("ListEventsByClass on partial DB = %d, want 0", len(byClass))
	}
}

// TestEventsSchemaAfterMigration verifies the 525 migration adds all 10
// new columns + 2 indexes to a freshly-opened store.
func TestEventsSchemaAfterMigration(t *testing.T) {
	s := testStore(t)
	expected := []string{
		"class", "severity", "session", "role", "window_id",
		"wake_reason", "unread_msg_ids", "extra_json",
		"consecutive_count", "window_sec",
	}
	for _, col := range expected {
		if !s.eventsCols[col] {
			t.Errorf("events.%s not present after migration", col)
		}
	}
	for _, idx := range []string{"idx_events_class_created", "idx_events_severity"} {
		var name string
		err := s.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='index' AND name=?`, idx).Scan(&name)
		if err != nil {
			t.Errorf("index %s missing: %v", idx, err)
		}
	}
}

// TestEventCRUDWithViolationFields exercises the round-trip insert and
// SELECT path against the migrated schema.
func TestEventCRUDWithViolationFields(t *testing.T) {
	s := testStore(t)
	if _, err := s.LogEvent(&Event{
		Type:             "violation_polling",
		Source:           "subtaskmaster",
		Class:            ViolationPolling,
		Severity:         "warn",
		Session:          "doey-test",
		Role:             "subtaskmaster",
		WindowID:         "W2",
		WakeReason:       "MSG",
		UnreadMsgIDs:     "1,2,3",
		ExtraJSON:        `{"foo":"bar"}`,
		ConsecutiveCount: 3,
		WindowSec:        45,
	}); err != nil {
		t.Fatalf("LogEvent: %v", err)
	}
	events, err := s.ListEventsByClass(ViolationPolling, 10)
	if err != nil {
		t.Fatalf("ListEventsByClass: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("events = %d, want 1", len(events))
	}
	got := events[0]
	if got.Class != ViolationPolling {
		t.Errorf("class = %q", got.Class)
	}
	if got.Severity != "warn" {
		t.Errorf("severity = %q", got.Severity)
	}
	if got.WakeReason != "MSG" {
		t.Errorf("wake_reason = %q", got.WakeReason)
	}
	if got.ConsecutiveCount != 3 {
		t.Errorf("consecutive_count = %d", got.ConsecutiveCount)
	}
	if got.WindowSec != 45 {
		t.Errorf("window_sec = %d", got.WindowSec)
	}
	if got.UnreadMsgIDs != "1,2,3" {
		t.Errorf("unread_msg_ids = %q", got.UnreadMsgIDs)
	}
	if got.ExtraJSON != `{"foo":"bar"}` {
		t.Errorf("extra_json = %q", got.ExtraJSON)
	}
}
