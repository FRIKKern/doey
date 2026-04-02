package store

import (
	"database/sql"
	"time"
)

// Plan represents a saved plan in the store.
type Plan struct {
	ID        int64  `json:"id"`
	Title     string `json:"title"`
	Status    string `json:"status"`
	Body      string `json:"body,omitempty"`
	CreatedAt int64  `json:"created_at"`
	UpdatedAt int64  `json:"updated_at"`
}

func (s *Store) CreatePlan(p *Plan) (int64, error) {
	now := time.Now().Unix()
	p.CreatedAt = now
	p.UpdatedAt = now
	res, err := s.db.Exec(
		`INSERT INTO plans (title, status, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
		p.Title, p.Status, p.Body, p.CreatedAt, p.UpdatedAt,
	)
	if err != nil {
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	p.ID = id
	return id, nil
}

func (s *Store) GetPlan(id int64) (*Plan, error) {
	p := &Plan{}
	err := s.db.QueryRow(
		`SELECT id, title, status, body, created_at, updated_at FROM plans WHERE id = ?`, id,
	).Scan(&p.ID, &p.Title, &p.Status, &p.Body, &p.CreatedAt, &p.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, sql.ErrNoRows
	}
	if err != nil {
		return nil, err
	}
	return p, nil
}

func (s *Store) ListPlans() ([]Plan, error) {
	rows, err := s.db.Query(`SELECT id, title, status, body, created_at, updated_at FROM plans ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var plans []Plan
	for rows.Next() {
		var p Plan
		if err := rows.Scan(&p.ID, &p.Title, &p.Status, &p.Body, &p.CreatedAt, &p.UpdatedAt); err != nil {
			return nil, err
		}
		plans = append(plans, p)
	}
	return plans, rows.Err()
}

func (s *Store) UpdatePlan(p *Plan) error {
	p.UpdatedAt = time.Now().Unix()
	_, err := s.db.Exec(
		`UPDATE plans SET title = ?, status = ?, body = ?, updated_at = ? WHERE id = ?`,
		p.Title, p.Status, p.Body, p.UpdatedAt, p.ID,
	)
	return err
}

func (s *Store) DeletePlan(id int64) error {
	_, err := s.db.Exec(`DELETE FROM plans WHERE id = ?`, id)
	return err
}
