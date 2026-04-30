package search

import (
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

// newQueryTestDB creates a SQLite DB with just enough schema (tasks, messages,
// tasks_fts/messages_fts virtual tables, sync triggers, task_urls) to drive
// the query layer without pulling in the store package (avoids any future
// circular-import risk).
func newQueryTestDB(t *testing.T) *sql.DB {
	t.Helper()
	dir := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(dir, "q.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	stmts := []string{
		`CREATE TABLE tasks (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			title TEXT NOT NULL,
			shortname TEXT,
			description TEXT,
			updated_at INTEGER
		)`,
		`CREATE TABLE messages (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			subject TEXT,
			body TEXT,
			task_id INTEGER,
			created_at INTEGER
		)`,
		`CREATE TABLE task_urls (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			task_id INTEGER NOT NULL,
			url TEXT NOT NULL,
			host TEXT NOT NULL,
			kind TEXT NOT NULL,
			field TEXT NOT NULL,
			ts TEXT NOT NULL
		)`,
		`CREATE VIRTUAL TABLE tasks_fts USING fts5(
			task_id UNINDEXED, title, description, shortname,
			tokenize="porter unicode61"
		)`,
		`CREATE VIRTUAL TABLE messages_fts USING fts5(
			msg_id UNINDEXED, body, tokenize="porter unicode61"
		)`,
		`CREATE TRIGGER tasks_fts_ai AFTER INSERT ON tasks BEGIN
			INSERT INTO tasks_fts(rowid, task_id, title, description, shortname)
			VALUES (NEW.id, NEW.id, COALESCE(NEW.title,''), COALESCE(NEW.description,''), COALESCE(NEW.shortname,''));
		END`,
		`CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN
			INSERT INTO messages_fts(rowid, msg_id, body)
			VALUES (NEW.id, NEW.id, COALESCE(NEW.body,''));
		END`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("schema: %v", err)
		}
	}
	return db
}

func TestParseSince(t *testing.T) {
	cases := []struct {
		in     string
		zero   bool
		within time.Duration // expected age from now (for relative)
	}{
		{"", true, 0},
		{"6h", false, 6 * time.Hour},
		{"30d", false, 30 * 24 * time.Hour},
		{"2w", false, 14 * 24 * time.Hour},
		{"45m", false, 45 * time.Minute},
	}
	for _, c := range cases {
		got, err := parseSince(c.in)
		if err != nil {
			t.Errorf("parseSince(%q): %v", c.in, err)
			continue
		}
		if c.zero {
			if !got.IsZero() {
				t.Errorf("parseSince(%q) = %v, want zero", c.in, got)
			}
			continue
		}
		age := time.Since(got)
		// allow 5s slack
		if age < c.within-5*time.Second || age > c.within+5*time.Second {
			t.Errorf("parseSince(%q) age = %v, want ~%v", c.in, age, c.within)
		}
	}

	// absolute date
	got, err := parseSince("2024-01-15")
	if err != nil {
		t.Fatalf("parseSince(2024-01-15): %v", err)
	}
	if got.Year() != 2024 || got.Month() != 1 || got.Day() != 15 {
		t.Errorf("parseSince(2024-01-15) = %v", got)
	}

	// invalid
	if _, err := parseSince("garbage"); err == nil {
		t.Errorf("parseSince(garbage): want error")
	}
}

func TestURLSearch(t *testing.T) {
	db := newQueryTestDB(t)

	now := time.Now().UTC()
	mustExec(t, db, `INSERT INTO tasks (id, title, shortname, description, updated_at) VALUES (?, ?, ?, ?, ?)`,
		1, "Wire the Figma board", "figma-wire", "see https://figma.com/file/abc", now.Unix())
	mustExec(t, db, `INSERT INTO tasks (id, title, shortname, description, updated_at) VALUES (?, ?, ?, ?, ?)`,
		2, "GitHub PR review", "gh-review", "https://github.com/foo/bar", now.Unix())

	// Use the actual extractor so the test exercises StoreURLs end-to-end.
	if err := StoreURLs(db, 1, "description", "see https://figma.com/file/abc"); err != nil {
		t.Fatal(err)
	}
	if err := StoreURLs(db, 2, "description", "https://github.com/foo/bar and https://api.github.com/x"); err != nil {
		t.Fatal(err)
	}

	// idempotency: re-run, must not duplicate
	if err := StoreURLs(db, 2, "description", "https://github.com/foo/bar and https://api.github.com/x"); err != nil {
		t.Fatal(err)
	}
	var cnt int
	if err := db.QueryRow(`SELECT count(*) FROM task_urls WHERE task_id=2`).Scan(&cnt); err != nil {
		t.Fatal(err)
	}
	if cnt != 2 {
		t.Errorf("idempotent re-extract: count=%d, want 2", cnt)
	}

	// pattern match: figma
	res, err := URLSearch(db, URLSearchOpts{Pattern: "figma"})
	if err != nil {
		t.Fatal(err)
	}
	if len(res) != 1 {
		t.Fatalf("figma search: %d results, want 1", len(res))
	}
	if res[0].TaskID != 1 || !strings.Contains(res[0].MatchedURL, "figma.com") {
		t.Errorf("figma result: %+v", res[0])
	}
	if res[0].Title != "Wire the Figma board" {
		t.Errorf("title join lost: %q", res[0].Title)
	}

	// kind filter
	res, err = URLSearch(db, URLSearchOpts{Kind: "github"})
	if err != nil {
		t.Fatal(err)
	}
	if len(res) != 2 {
		t.Errorf("github kind: %d results, want 2", len(res))
	}

	// limit clamp
	res, err = URLSearch(db, URLSearchOpts{Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	if len(res) != 1 {
		t.Errorf("limit=1: got %d", len(res))
	}
}

func TestTextSearch_Tasks(t *testing.T) {
	db := newQueryTestDB(t)
	now := time.Now().UTC()

	mustExec(t, db, `INSERT INTO tasks (id, title, shortname, description, updated_at) VALUES (?, ?, ?, ?, ?)`,
		1, "implement auth flow", "auth", "JWT-based login pipeline", now.Unix())
	mustExec(t, db, `INSERT INTO tasks (id, title, shortname, description, updated_at) VALUES (?, ?, ?, ?, ?)`,
		2, "ship dashboard", "dash", "render the live dashboard", now.Unix())
	mustExec(t, db, `INSERT INTO tasks (id, title, shortname, description, updated_at) VALUES (?, ?, ?, ?, ?)`,
		3, "auth refactor", "auth-rf", "consolidate auth handlers", now.Unix()-7*24*3600)

	res, err := TextSearch(db, TextSearchOpts{Query: "auth", Type: "task"})
	if err != nil {
		t.Fatal(err)
	}
	if len(res) != 2 {
		t.Fatalf("auth match: %d, want 2", len(res))
	}
	for _, r := range res {
		if !strings.Contains(strings.ToLower(r.Snippet), "<b>") {
			t.Errorf("expected highlighted snippet, got %q", r.Snippet)
		}
		if r.TaskID == 0 || r.Title == "" {
			t.Errorf("missing task fields: %+v", r)
		}
	}

	// since filter — only the recent ones should pass
	since := time.Now().Add(-24 * time.Hour)
	res, err = TextSearch(db, TextSearchOpts{Query: "auth", Type: "task", Since: since})
	if err != nil {
		t.Fatal(err)
	}
	if len(res) != 1 || res[0].TaskID != 1 {
		t.Errorf("since filter: %+v", res)
	}

	// limit clamp default + max
	if got := clampLimit(0); got != defaultLimit {
		t.Errorf("clampLimit(0)=%d", got)
	}
	if got := clampLimit(9999); got != maxLimit {
		t.Errorf("clampLimit(9999)=%d", got)
	}

	// empty query rejected
	if _, err := TextSearch(db, TextSearchOpts{Query: ""}); err == nil {
		t.Errorf("empty query: want error")
	}
}

func TestTextSearch_Messages(t *testing.T) {
	db := newQueryTestDB(t)
	now := time.Now().UTC().Unix()
	mustExec(t, db, `INSERT INTO messages (id, subject, body, task_id, created_at) VALUES (?, ?, ?, ?, ?)`,
		1, "ping", "please review the auth handler", 42, now)
	mustExec(t, db, `INSERT INTO messages (id, subject, body, task_id, created_at) VALUES (?, ?, ?, ?, ?)`,
		2, "meta", "unrelated content", 0, now)

	res, err := TextSearch(db, TextSearchOpts{Query: "auth", Type: "message"})
	if err != nil {
		t.Fatal(err)
	}
	if len(res) != 1 {
		t.Fatalf("messages auth: %d, want 1", len(res))
	}
	if res[0].TaskID != 42 || res[0].Title != "ping" {
		t.Errorf("message hit: %+v", res[0])
	}
	if !strings.Contains(res[0].Snippet, "<b>") {
		t.Errorf("expected snippet highlight: %q", res[0].Snippet)
	}
}

func mustExec(t *testing.T, db *sql.DB, q string, args ...any) {
	t.Helper()
	if _, err := db.Exec(q, args...); err != nil {
		t.Fatalf("exec %q: %v", q, err)
	}
}
