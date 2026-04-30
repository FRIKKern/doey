package store

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"
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

// TestSchemaV4Objects verifies schema_version 4 (task #659) — the URL
// table, FTS5 virtual tables, and triggers — exist on a freshly opened DB.
func TestSchemaV4Objects(t *testing.T) {
	s := testStore(t)

	tables := []string{"task_urls", "tasks_fts", "messages_fts"}
	for _, name := range tables {
		var got string
		err := s.db.QueryRow(`SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name=?`, name).Scan(&got)
		if err != nil {
			t.Errorf("table %s missing: %v", name, err)
		}
	}

	indexes := []string{"idx_task_urls_host_ts", "idx_task_urls_task_id", "idx_task_urls_task_field"}
	for _, idx := range indexes {
		var got string
		err := s.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='index' AND name=?`, idx).Scan(&got)
		if err != nil {
			t.Errorf("index %s missing: %v", idx, err)
		}
	}

	triggers := []string{
		"tasks_fts_ai", "tasks_fts_ad", "tasks_fts_au",
		"messages_fts_ai", "messages_fts_ad", "messages_fts_au",
	}
	for _, trg := range triggers {
		var got string
		err := s.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='trigger' AND name=?`, trg).Scan(&got)
		if err != nil {
			t.Errorf("trigger %s missing: %v", trg, err)
		}
	}
}

// TestSchemaV4FTSTriggerRoundTrip writes a task + message and verifies the
// FTS5 shadow tables are kept in sync via the AFTER INSERT/UPDATE/DELETE
// triggers.
func TestSchemaV4FTSTriggerRoundTrip(t *testing.T) {
	s := testStore(t)

	// Task INSERT → tasks_fts row.
	id, err := s.CreateTask(&Task{
		Title:       "build search prototype",
		Description: "wire up sqlite fts5 and a small TUI palette",
		Status:      "active",
	})
	if err != nil {
		t.Fatal(err)
	}
	var hits int
	if err := s.db.QueryRow(`SELECT count(*) FROM tasks_fts WHERE tasks_fts MATCH 'prototype'`).Scan(&hits); err != nil {
		t.Fatal(err)
	}
	if hits != 1 {
		t.Errorf("after INSERT tasks_fts MATCH 'prototype' = %d, want 1", hits)
	}

	// UPDATE → re-indexed under new content (both title and description
	// are rewritten so old tokens drop out of the index).
	if _, err := s.db.Exec(`UPDATE tasks SET title=?, description=? WHERE id=?`,
		"unrelated headline", "now indexed under needle", id); err != nil {
		t.Fatal(err)
	}
	if err := s.db.QueryRow(`SELECT count(*) FROM tasks_fts WHERE tasks_fts MATCH 'needle'`).Scan(&hits); err != nil {
		t.Fatal(err)
	}
	if hits != 1 {
		t.Errorf("after UPDATE tasks_fts MATCH 'needle' = %d, want 1", hits)
	}
	if err := s.db.QueryRow(`SELECT count(*) FROM tasks_fts WHERE tasks_fts MATCH 'prototype'`).Scan(&hits); err != nil {
		t.Fatal(err)
	}
	if hits != 0 {
		t.Errorf("after UPDATE old token still indexed: %d, want 0", hits)
	}

	// DELETE → row removed from FTS.
	if _, err := s.db.Exec(`DELETE FROM tasks WHERE id=?`, id); err != nil {
		t.Fatal(err)
	}
	if err := s.db.QueryRow(`SELECT count(*) FROM tasks_fts WHERE tasks_fts MATCH 'needle'`).Scan(&hits); err != nil {
		t.Fatal(err)
	}
	if hits != 0 {
		t.Errorf("after DELETE tasks_fts row remained: %d, want 0", hits)
	}

	// messages_fts trigger sanity.
	if _, err := s.db.Exec(`INSERT INTO messages (from_pane, to_pane, subject, body, created_at) VALUES (?,?,?,?,?)`,
		"w1.1", "w0", "test", "ping pong haystack", time.Now().Unix()); err != nil {
		t.Fatal(err)
	}
	if err := s.db.QueryRow(`SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'haystack'`).Scan(&hits); err != nil {
		t.Fatal(err)
	}
	if hits != 1 {
		t.Errorf("messages_fts MATCH 'haystack' = %d, want 1", hits)
	}
}

// TestSchemaV4VersionDefault verifies the schema_version column DEFAULT
// is bumped to 4 — rows inserted without an explicit schema_version pick
// up the new default.
func TestSchemaV4VersionDefault(t *testing.T) {
	s := testStore(t)
	res, err := s.db.Exec(`INSERT INTO tasks (title, status) VALUES ('x', 'active')`)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	var v int
	if err := s.db.QueryRow(`SELECT schema_version FROM tasks WHERE id=?`, id).Scan(&v); err != nil {
		t.Fatal(err)
	}
	if v != 4 {
		t.Errorf("schema_version DEFAULT = %d, want 4", v)
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
