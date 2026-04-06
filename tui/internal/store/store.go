package store

import (
	"database/sql"

	_ "modernc.org/sqlite"
)

// Store wraps a SQLite database connection.
type Store struct {
	db   *sql.DB
	path string
}

// Open opens a SQLite database at dbPath, enables WAL mode, and ensures the schema exists.
func Open(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec("PRAGMA foreign_keys=ON"); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.Exec("PRAGMA busy_timeout=5000"); err != nil {
		db.Close()
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if err := ensureSchema(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureMigrations(db); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db, path: dbPath}, nil
}

// ensureMigrations adds columns that may be missing from older databases.
func ensureMigrations(db *sql.DB) error {
	cols := []string{
		"notes TEXT",
		"blockers TEXT",
		"related_files TEXT",
		"hypotheses TEXT",
		"decision_log TEXT",
		"result TEXT",
		"files TEXT",
		"commits TEXT",
		"schema_version INTEGER DEFAULT 3",
		"review_verdict TEXT",
		"review_findings TEXT",
		"review_timestamp TEXT",
	}
	for _, col := range cols {
		// Ignore errors — column may already exist.
		db.Exec("ALTER TABLE tasks ADD COLUMN " + col)
	}
	// Proof-of-completion columns (task #275).
	proofCols := []string{
		"proof_type TEXT DEFAULT ''",
		"proof_content TEXT DEFAULT ''",
		"verification_status TEXT DEFAULT 'unverified'",
		"build_status TEXT DEFAULT ''",
	}
	for _, col := range proofCols {
		db.Exec("ALTER TABLE tasks ADD COLUMN " + col)
	}
	// Subtask review columns (task #275).
	subtaskReviewCols := []string{
		"review_verdict TEXT DEFAULT ''",
		"review_evidence TEXT DEFAULT ''",
		"reviewer TEXT DEFAULT ''",
	}
	for _, col := range subtaskReviewCols {
		db.Exec("ALTER TABLE subtasks ADD COLUMN " + col)
	}
	// Success criteria + structured proof-of-success (task #332).
	successCols := []string{
		"success_criteria TEXT DEFAULT ''",
		"proof_of_success TEXT DEFAULT ''",
	}
	for _, col := range successCols {
		db.Exec("ALTER TABLE tasks ADD COLUMN " + col)
	}
	// Add routed column to messages (may already exist).
	db.Exec("ALTER TABLE messages ADD COLUMN routed INTEGER DEFAULT 0")
	return nil
}

// Close closes the database connection.
func (s *Store) Close() error {
	return s.db.Close()
}

// DB exposes the underlying *sql.DB for advanced queries.
func (s *Store) DB() *sql.DB {
	return s.db
}
