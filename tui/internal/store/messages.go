package store

import "time"

// Message represents an inter-pane message.
type Message struct {
	ID        int64  `json:"id"`
	FromPane  string `json:"from_pane"`
	ToPane    string `json:"to_pane"`
	Subject   string `json:"subject"`
	Body      string `json:"body,omitempty"`
	TaskID    *int64 `json:"task_id,omitempty"`
	Read      bool   `json:"read"`
	CreatedAt int64  `json:"created_at"`
}

// SendMessage inserts a new message and returns its ID.
func (s *Store) SendMessage(m *Message) (int64, error) {
	m.CreatedAt = time.Now().Unix()
	m.Read = false
	res, err := s.db.Exec(
		`INSERT INTO messages (from_pane, to_pane, subject, body, task_id, read, created_at)
		 VALUES (?, ?, ?, ?, ?, 0, ?)`,
		m.FromPane, m.ToPane, m.Subject, m.Body, m.TaskID, m.CreatedAt,
	)
	if err != nil {
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	m.ID = id
	return id, nil
}

// ListMessages returns messages for a pane, optionally only unread, newest first.
// If toPane is empty, returns all messages.
func (s *Store) ListMessages(toPane string, unreadOnly bool) ([]Message, error) {
	var query string
	var args []any
	if toPane == "" {
		query = `SELECT id, from_pane, to_pane, subject, body, task_id, read, created_at
		          FROM messages`
		if unreadOnly {
			query += ` WHERE read = 0`
		}
	} else {
		query = `SELECT id, from_pane, to_pane, subject, body, task_id, read, created_at
		          FROM messages WHERE to_pane = ?`
		args = append(args, toPane)
		if unreadOnly {
			query += ` AND read = 0`
		}
	}
	query += ` ORDER BY created_at DESC`

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []Message
	for rows.Next() {
		var m Message
		var readInt int
		if err := rows.Scan(&m.ID, &m.FromPane, &m.ToPane, &m.Subject, &m.Body, &m.TaskID, &readInt, &m.CreatedAt); err != nil {
			return nil, err
		}
		m.Read = readInt != 0
		msgs = append(msgs, m)
	}
	return msgs, rows.Err()
}

// MarkRead marks a single message as read.
func (s *Store) MarkRead(id int64) error {
	_, err := s.db.Exec(`UPDATE messages SET read = 1 WHERE id = ?`, id)
	return err
}

// MarkAllRead marks all messages to a pane as read.
func (s *Store) MarkAllRead(toPane string) error {
	_, err := s.db.Exec(`UPDATE messages SET read = 1 WHERE to_pane = ?`, toPane)
	return err
}

// ListUnrouted returns unrouted messages for a pane (used by doey-router).
func (s *Store) ListUnrouted(toPane string) ([]Message, error) {
	query := `SELECT id, from_pane, to_pane, subject, body, task_id, read, created_at
	          FROM messages WHERE to_pane = ? AND routed = 0 ORDER BY created_at DESC`
	rows, err := s.db.Query(query, toPane)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []Message
	for rows.Next() {
		var m Message
		var readInt int
		if err := rows.Scan(&m.ID, &m.FromPane, &m.ToPane, &m.Subject, &m.Body, &m.TaskID, &readInt, &m.CreatedAt); err != nil {
			return nil, err
		}
		m.Read = readInt != 0
		msgs = append(msgs, m)
	}
	return msgs, rows.Err()
}

// MarkRouted marks a message as processed by the router (without affecting read status).
func (s *Store) MarkRouted(id int64) error {
	_, err := s.db.Exec(`UPDATE messages SET routed = 1 WHERE id = ?`, id)
	return err
}

// DeleteMessage removes a message by ID.
func (s *Store) DeleteMessage(id int64) error {
	_, err := s.db.Exec(`DELETE FROM messages WHERE id = ?`, id)
	return err
}

// CountUnread returns the number of unread messages for a pane.
func (s *Store) CountUnread(toPane string) (int, error) {
	var count int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE to_pane = ? AND read = 0`, toPane).Scan(&count)
	return count, err
}
