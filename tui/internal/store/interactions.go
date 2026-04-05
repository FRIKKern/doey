package store

import "time"

// Interaction represents an entry in the boss interaction log.
type Interaction struct {
	ID          int64  `json:"id"`
	SessionName string `json:"session_name,omitempty"`
	TaskID      *int64 `json:"task_id,omitempty"`
	MessageText string `json:"message_text"`
	MessageType string `json:"message_type"` // command, question, feedback, status, other
	Source      string `json:"source"`       // user, taskmaster, worker
	Context     string `json:"context,omitempty"`
	CreatedAt   int64  `json:"created_at"`
}

// LogInteraction inserts a new interaction and returns its ID.
func (s *Store) LogInteraction(i Interaction) (int64, error) {
	i.CreatedAt = time.Now().Unix()
	res, err := s.db.Exec(
		`INSERT INTO interaction_log (session_name, task_id, message_text, message_type, source, context, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		i.SessionName, i.TaskID, i.MessageText, i.MessageType, i.Source, i.Context, i.CreatedAt,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// ListInteractions returns recent interactions, newest first.
func (s *Store) ListInteractions(limit int) ([]Interaction, error) {
	rows, err := s.db.Query(
		`SELECT id, session_name, task_id, message_text, message_type, source, context, created_at
		 FROM interaction_log ORDER BY created_at DESC LIMIT ?`, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanInteractions(rows)
}

// ListInteractionsByTask returns interactions for a given task, newest first.
func (s *Store) ListInteractionsByTask(taskID int64) ([]Interaction, error) {
	rows, err := s.db.Query(
		`SELECT id, session_name, task_id, message_text, message_type, source, context, created_at
		 FROM interaction_log WHERE task_id = ? ORDER BY created_at DESC`, taskID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanInteractions(rows)
}

// ListInteractionsByType returns interactions filtered by message type, newest first.
func (s *Store) ListInteractionsByType(msgType string, limit int) ([]Interaction, error) {
	rows, err := s.db.Query(
		`SELECT id, session_name, task_id, message_text, message_type, source, context, created_at
		 FROM interaction_log WHERE message_type = ? ORDER BY created_at DESC LIMIT ?`, msgType, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanInteractions(rows)
}

// SearchInteractions searches interaction text with LIKE, newest first.
func (s *Store) SearchInteractions(query string, limit int) ([]Interaction, error) {
	rows, err := s.db.Query(
		`SELECT id, session_name, task_id, message_text, message_type, source, context, created_at
		 FROM interaction_log WHERE message_text LIKE '%' || ? || '%' ORDER BY created_at DESC LIMIT ?`, query, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanInteractions(rows)
}

// InteractionStats returns counts grouped by message_type.
func (s *Store) InteractionStats() (map[string]int, error) {
	rows, err := s.db.Query(`SELECT message_type, COUNT(*) FROM interaction_log GROUP BY message_type`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	stats := make(map[string]int)
	for rows.Next() {
		var typ string
		var count int
		if err := rows.Scan(&typ, &count); err != nil {
			return nil, err
		}
		stats[typ] = count
	}
	return stats, rows.Err()
}

func scanInteractions(rows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
}) ([]Interaction, error) {
	var list []Interaction
	for rows.Next() {
		var i Interaction
		if err := rows.Scan(&i.ID, &i.SessionName, &i.TaskID, &i.MessageText, &i.MessageType, &i.Source, &i.Context, &i.CreatedAt); err != nil {
			return nil, err
		}
		list = append(list, i)
	}
	return list, rows.Err()
}
