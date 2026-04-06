package store

import "time"

// Event represents a system event in the event log.
type Event struct {
	ID        int64  `json:"id"`
	Type      string `json:"type"`
	Source    string `json:"source,omitempty"`
	Target    string `json:"target,omitempty"`
	TaskID    *int64 `json:"task_id,omitempty"`
	Data      string `json:"data,omitempty"`
	CreatedAt int64  `json:"created_at"`
}

// LogEvent inserts a new event and returns its ID.
func (s *Store) LogEvent(e *Event) (int64, error) {
	e.CreatedAt = time.Now().Unix()
	res, err := s.db.Exec(
		`INSERT INTO events (type, source, target, task_id, data, created_at)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		e.Type, e.Source, e.Target, e.TaskID, e.Data, e.CreatedAt,
	)
	if err != nil {
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	e.ID = id
	return id, nil
}

// ListEvents returns events, optionally filtered by type, newest first.
// Pass empty eventType to list all. limit controls max rows returned.
func (s *Store) ListEvents(eventType string, limit int) ([]Event, error) {
	query := `SELECT id, type, source, target, task_id, data, created_at FROM events`
	var args []any
	if eventType != "" {
		query += ` WHERE type = ?`
		args = append(args, eventType)
	}
	query += ` ORDER BY created_at DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.ID, &e.Type, &e.Source, &e.Target, &e.TaskID, &e.Data, &e.CreatedAt); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

// ListErrorEvents returns error events (type LIKE 'error_%'), newest first.
// Optional filters: errorType (exact type match), source, taskID (>0), limit.
func (s *Store) ListErrorEvents(errorType string, source string, taskID int64, limit int) ([]Event, error) {
	query := `SELECT id, type, source, target, task_id, data, created_at FROM events WHERE type LIKE 'error_%'`
	var args []any
	if errorType != "" {
		query += ` AND type = ?`
		args = append(args, errorType)
	}
	if source != "" {
		query += ` AND source = ?`
		args = append(args, source)
	}
	if taskID > 0 {
		query += ` AND task_id = ?`
		args = append(args, taskID)
	}
	query += ` ORDER BY created_at DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.ID, &e.Type, &e.Source, &e.Target, &e.TaskID, &e.Data, &e.CreatedAt); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

// ListEventsByTask returns all events for a given task, oldest first.
func (s *Store) ListEventsByTask(taskID int64) ([]Event, error) {
	rows, err := s.db.Query(
		`SELECT id, type, source, target, task_id, data, created_at
		 FROM events WHERE task_id = ? ORDER BY created_at`,
		taskID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.ID, &e.Type, &e.Source, &e.Target, &e.TaskID, &e.Data, &e.CreatedAt); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
}
