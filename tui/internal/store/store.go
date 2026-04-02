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
	if err := ensureSchema(db); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db, path: dbPath}, nil
}

// Close closes the database connection.
func (s *Store) Close() error {
	return s.db.Close()
}

// DB exposes the underlying *sql.DB for advanced queries.
func (s *Store) DB() *sql.DB {
	return s.db
}
