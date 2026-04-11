package statsdb

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	_ "modernc.org/sqlite"
)

// DB wraps a *sql.DB connection to a stats.db file. The zero value is
// not usable — always call Open.
type DB struct {
	db   *sql.DB
	path string
	mode Mode
}

// Open mkdirs the parent of path, opens a modernc.org/sqlite connection
// with the appropriate DSN for mode, applies PRAGMAs, and runs the
// idempotent schema bootstrap. Re-opening an existing DB is a no-op on
// schema and must not error.
//
// Task #525 note: this function MUST remain safe when a `violations`
// table already exists. All CREATE statements use IF NOT EXISTS; nothing
// is dropped.
func Open(path string, mode Mode) (*DB, error) {
	if path == "" {
		return nil, fmt.Errorf("statsdb: empty path")
	}
	if mode == ModeRW {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, fmt.Errorf("statsdb: mkdir parent: %w", err)
		}
	}

	dsn := buildDSN(path, mode)
	sqlDB, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("statsdb: open: %w", err)
	}
	// Serialize writes. modernc.org/sqlite is safe with multiple conns
	// under WAL, but per-call Exec on a single conn avoids lock churn
	// and matches tui/internal/store's policy.
	sqlDB.SetMaxOpenConns(1)

	// Explicit PRAGMAs in addition to DSN form, so we don't rely on the
	// DSN dialect alone. Safe to re-run on an existing DB.
	if mode == ModeRW {
		for _, p := range []string{
			"PRAGMA journal_mode=WAL",
			"PRAGMA busy_timeout=5000",
			"PRAGMA synchronous=NORMAL",
			"PRAGMA foreign_keys=ON",
		} {
			if _, err := sqlDB.Exec(p); err != nil {
				sqlDB.Close()
				return nil, fmt.Errorf("statsdb: %s: %w", p, err)
			}
		}
	}

	d := &DB{db: sqlDB, path: path, mode: mode}
	if mode == ModeRW {
		if err := d.bootstrapSchema(); err != nil {
			sqlDB.Close()
			return nil, err
		}
	}
	return d, nil
}

func buildDSN(path string, mode Mode) string {
	switch mode {
	case ModeRO:
		return "file:" + path +
			"?_pragma=journal_mode(wal)&_pragma=query_only(true)&mode=ro"
	default:
		return "file:" + path +
			"?_pragma=journal_mode(wal)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(on)"
	}
}

// bootstrapSchema creates the events table, indexes, and schema_meta row
// if they don't already exist. It never drops anything.
func (d *DB) bootstrapSchema() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS events (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			timestamp  INTEGER NOT NULL,
			category   TEXT    NOT NULL,
			type       TEXT    NOT NULL,
			session_id TEXT,
			project    TEXT,
			payload    TEXT
		)`,
		`CREATE INDEX IF NOT EXISTS idx_ts   ON events(timestamp)`,
		`CREATE INDEX IF NOT EXISTS idx_type ON events(type)`,
		`CREATE INDEX IF NOT EXISTS idx_sid  ON events(session_id)`,
		`CREATE INDEX IF NOT EXISTS idx_cat  ON events(category)`,
		`CREATE TABLE IF NOT EXISTS schema_meta (
			key   TEXT PRIMARY KEY,
			value TEXT
		)`,
	}
	for _, s := range stmts {
		if _, err := d.db.Exec(s); err != nil {
			return fmt.Errorf("statsdb: bootstrap %q: %w", firstLine(s), err)
		}
	}
	// Insert-or-ignore the schema_version row. Never UPDATE — keeps
	// this path strictly additive.
	if _, err := d.db.Exec(
		`INSERT OR IGNORE INTO schema_meta(key, value) VALUES ('schema_version', ?)`,
		fmt.Sprintf("%d", SchemaVersion),
	); err != nil {
		return fmt.Errorf("statsdb: set schema_version: %w", err)
	}
	return nil
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// Emit inserts a single event row. Unknown payload-key filtering is the
// emitter's job (shell wrapper / Go subcommand); Emit trusts its input.
// Payload is serialized as compact JSON with sorted keys so test
// assertions are stable.
func (d *DB) Emit(ev Event) error {
	if d == nil || d.db == nil {
		return fmt.Errorf("statsdb: Emit on closed DB")
	}
	payload := encodePayload(ev.Payload)
	_, err := d.db.Exec(
		`INSERT INTO events(timestamp, category, type, session_id, project, payload)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		ev.Timestamp, ev.Category, ev.Type, ev.SessionID, ev.Project, payload,
	)
	return err
}

func encodePayload(p map[string]string) string {
	if len(p) == 0 {
		return ""
	}
	// Sort for deterministic output.
	keys := make([]string, 0, len(p))
	for k := range p {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	ordered := make([][2]string, 0, len(keys))
	for _, k := range keys {
		ordered = append(ordered, [2]string{k, p[k]})
	}
	// Hand-roll a compact object to preserve key order (json.Marshal of
	// a map is already sorted by modernc but this is explicit).
	var b strings.Builder
	b.WriteByte('{')
	for i, kv := range ordered {
		if i > 0 {
			b.WriteByte(',')
		}
		kj, _ := json.Marshal(kv[0])
		vj, _ := json.Marshal(kv[1])
		b.Write(kj)
		b.WriteByte(':')
		b.Write(vj)
	}
	b.WriteByte('}')
	return b.String()
}

// Close releases the underlying connection.
func (d *DB) Close() error {
	if d == nil || d.db == nil {
		return nil
	}
	err := d.db.Close()
	d.db = nil
	return err
}

// Path returns the filesystem path of the opened database.
func (d *DB) Path() string { return d.path }

// DB exposes the underlying *sql.DB for test assertions only. Production
// callers should go through Emit.
func (d *DB) SQL() *sql.DB { return d.db }
