package store

import "database/sql"

// ConfigEntry represents a key-value configuration setting.
type ConfigEntry struct {
	Key    string `json:"key"`
	Value  string `json:"value"`
	Source string `json:"source,omitempty"`
}

func (s *Store) SetConfig(key, value, source string) error {
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO config (key, value, source) VALUES (?, ?, ?)`,
		key, value, source,
	)
	return err
}

func (s *Store) GetConfig(key string) (string, error) {
	var value string
	err := s.db.QueryRow(`SELECT value FROM config WHERE key = ?`, key).Scan(&value)
	if err == sql.ErrNoRows {
		return "", sql.ErrNoRows
	}
	if err != nil {
		return "", err
	}
	return value, nil
}

func (s *Store) ListConfig() ([]ConfigEntry, error) {
	rows, err := s.db.Query(`SELECT key, value, source FROM config ORDER BY key`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var entries []ConfigEntry
	for rows.Next() {
		var e ConfigEntry
		if err := rows.Scan(&e.Key, &e.Value, &e.Source); err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

func (s *Store) DeleteConfig(key string) error {
	_, err := s.db.Exec(`DELETE FROM config WHERE key = ?`, key)
	return err
}
