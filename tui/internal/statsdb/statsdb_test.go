package statsdb

import (
	"path/filepath"
	"testing"
	"time"
)

func TestOpen_CreatesSchemaAndMetaRow(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nested", "stats.db")

	db, err := Open(path, ModeRW)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	// events table exists
	var count int
	if err := db.SQL().QueryRow(
		`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='events'`,
	).Scan(&count); err != nil || count != 1 {
		t.Fatalf("events table missing: count=%d err=%v", count, err)
	}

	// schema_meta has schema_version=1
	var ver string
	if err := db.SQL().QueryRow(
		`SELECT value FROM schema_meta WHERE key='schema_version'`,
	).Scan(&ver); err != nil {
		t.Fatalf("schema_version row missing: %v", err)
	}
	if ver != "1" {
		t.Fatalf("schema_version=%q, want 1", ver)
	}

	// all four indexes present
	wantIdx := map[string]bool{"idx_ts": false, "idx_type": false, "idx_sid": false, "idx_cat": false}
	rows, err := db.SQL().Query(
		`SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='events'`,
	)
	if err != nil {
		t.Fatalf("query indexes: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatalf("scan: %v", err)
		}
		if _, ok := wantIdx[n]; ok {
			wantIdx[n] = true
		}
	}
	for k, seen := range wantIdx {
		if !seen {
			t.Errorf("missing index %s", k)
		}
	}
}

func TestOpen_Idempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stats.db")

	for i := 0; i < 3; i++ {
		db, err := Open(path, ModeRW)
		if err != nil {
			t.Fatalf("Open #%d: %v", i, err)
		}
		if err := db.Close(); err != nil {
			t.Fatalf("Close #%d: %v", i, err)
		}
	}

	// Still exactly one schema_version row
	db, err := Open(path, ModeRW)
	if err != nil {
		t.Fatalf("final Open: %v", err)
	}
	defer db.Close()
	var n int
	if err := db.SQL().QueryRow(
		`SELECT COUNT(*) FROM schema_meta WHERE key='schema_version'`,
	).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 1 {
		t.Fatalf("schema_version rows=%d, want 1", n)
	}
}

func TestOpen_SafeAgainstPreExistingViolationsTable(t *testing.T) {
	// Task #525 coordination: if a `violations` table already exists
	// in stats.db, Open must not error and must not drop it.
	path := filepath.Join(t.TempDir(), "stats.db")

	db, err := Open(path, ModeRW)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := db.SQL().Exec(
		`CREATE TABLE violations (id INTEGER PRIMARY KEY, kind TEXT)`,
	); err != nil {
		t.Fatalf("seed violations: %v", err)
	}
	if _, err := db.SQL().Exec(
		`INSERT INTO violations(kind) VALUES ('seed')`,
	); err != nil {
		t.Fatalf("seed row: %v", err)
	}
	db.Close()

	db2, err := Open(path, ModeRW)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer db2.Close()
	var n int
	if err := db2.SQL().QueryRow(`SELECT COUNT(*) FROM violations`).Scan(&n); err != nil {
		t.Fatalf("violations table lost: %v", err)
	}
	if n != 1 {
		t.Fatalf("violations row count=%d, want 1", n)
	}
}

func TestEmit_RoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stats.db")
	db, err := Open(path, ModeRW)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	ev := Event{
		Timestamp: time.Now().UnixMilli(),
		Category:  "session",
		Type:      "session_start",
		SessionID: "abc-123",
		Project:   "/home/user/proj",
		Payload:   map[string]string{"role": "worker", "window": "2"},
	}
	if err := db.Emit(ev); err != nil {
		t.Fatalf("Emit: %v", err)
	}

	var (
		cat, typ, sid, proj, payload string
		ts                           int64
	)
	if err := db.SQL().QueryRow(
		`SELECT timestamp, category, type, session_id, project, payload
		 FROM events ORDER BY id DESC LIMIT 1`,
	).Scan(&ts, &cat, &typ, &sid, &proj, &payload); err != nil {
		t.Fatalf("readback: %v", err)
	}
	if cat != "session" || typ != "session_start" || sid != "abc-123" || proj != "/home/user/proj" {
		t.Errorf("fields mismatch: cat=%q typ=%q sid=%q proj=%q", cat, typ, sid, proj)
	}
	// encodePayload sorts keys — so role comes before window.
	want := `{"role":"worker","window":"2"}`
	if payload != want {
		t.Errorf("payload=%q, want %q", payload, want)
	}
}

func TestEmit_EmptyPayload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stats.db")
	db, err := Open(path, ModeRW)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	if err := db.Emit(Event{
		Timestamp: 1, Category: "task", Type: "x",
	}); err != nil {
		t.Fatalf("Emit: %v", err)
	}
	var payload string
	if err := db.SQL().QueryRow(
		`SELECT payload FROM events ORDER BY id DESC LIMIT 1`,
	).Scan(&payload); err != nil {
		t.Fatalf("readback: %v", err)
	}
	if payload != "" {
		t.Errorf("empty-payload row payload=%q, want empty", payload)
	}
}
