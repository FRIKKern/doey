package store

import (
	"database/sql"
	"time"
)

// Team represents a Doey team window.
type Team struct {
	WindowID     string `json:"window_id"`
	Name         string `json:"name"`
	Type         string `json:"type"`
	WorktreePath string `json:"worktree_path,omitempty"`
	PaneCount    int    `json:"pane_count"`
	CreatedAt    int64  `json:"created_at"`
}

// PaneStatus represents the status of a single pane within a team.
type PaneStatus struct {
	PaneID    string `json:"pane_id"`
	WindowID  string `json:"window_id"`
	Role      string `json:"role"`
	Status    string `json:"status"`
	TaskID    *int64 `json:"task_id,omitempty"`
	TaskTitle string `json:"task_title,omitempty"`
	Agent     string `json:"agent,omitempty"`
	UpdatedAt int64  `json:"updated_at"`
}

func (s *Store) UpsertTeam(t *Team) error {
	if t.CreatedAt == 0 {
		t.CreatedAt = time.Now().Unix()
	}
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO teams (window_id, name, type, worktree_path, pane_count, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		t.WindowID, t.Name, t.Type, t.WorktreePath, t.PaneCount, t.CreatedAt,
	)
	return err
}

func (s *Store) GetTeam(windowID string) (*Team, error) {
	t := &Team{}
	err := s.db.QueryRow(
		`SELECT window_id, name, type, worktree_path, pane_count, created_at FROM teams WHERE window_id = ?`, windowID,
	).Scan(&t.WindowID, &t.Name, &t.Type, &t.WorktreePath, &t.PaneCount, &t.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, sql.ErrNoRows
	}
	if err != nil {
		return nil, err
	}
	return t, nil
}

func (s *Store) ListTeams() ([]Team, error) {
	rows, err := s.db.Query(`SELECT window_id, name, type, worktree_path, pane_count, created_at FROM teams`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var teams []Team
	for rows.Next() {
		var t Team
		if err := rows.Scan(&t.WindowID, &t.Name, &t.Type, &t.WorktreePath, &t.PaneCount, &t.CreatedAt); err != nil {
			return nil, err
		}
		teams = append(teams, t)
	}
	return teams, rows.Err()
}

func (s *Store) DeleteTeam(windowID string) error {
	_, err := s.db.Exec(`DELETE FROM teams WHERE window_id = ?`, windowID)
	return err
}

func (s *Store) UpsertPaneStatus(ps *PaneStatus) error {
	ps.UpdatedAt = time.Now().Unix()
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO pane_status (pane_id, window_id, role, status, task_id, task_title, agent, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		ps.PaneID, ps.WindowID, ps.Role, ps.Status, ps.TaskID, ps.TaskTitle, ps.Agent, ps.UpdatedAt,
	)
	return err
}

func (s *Store) GetPaneStatus(paneID string) (*PaneStatus, error) {
	ps := &PaneStatus{}
	err := s.db.QueryRow(
		`SELECT pane_id, window_id, role, status, task_id, task_title, agent, updated_at FROM pane_status WHERE pane_id = ?`, paneID,
	).Scan(&ps.PaneID, &ps.WindowID, &ps.Role, &ps.Status, &ps.TaskID, &ps.TaskTitle, &ps.Agent, &ps.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, sql.ErrNoRows
	}
	if err != nil {
		return nil, err
	}
	return ps, nil
}

func (s *Store) ListPaneStatuses(windowID string) ([]PaneStatus, error) {
	var rows *sql.Rows
	var err error
	if windowID == "" {
		rows, err = s.db.Query(
			`SELECT pane_id, window_id, role, status, task_id, task_title, agent, updated_at FROM pane_status ORDER BY window_id, pane_id`)
	} else {
		rows, err = s.db.Query(
			`SELECT pane_id, window_id, role, status, task_id, task_title, agent, updated_at FROM pane_status WHERE window_id = ? ORDER BY pane_id`, windowID)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var statuses []PaneStatus
	for rows.Next() {
		var ps PaneStatus
		if err := rows.Scan(&ps.PaneID, &ps.WindowID, &ps.Role, &ps.Status, &ps.TaskID, &ps.TaskTitle, &ps.Agent, &ps.UpdatedAt); err != nil {
			return nil, err
		}
		statuses = append(statuses, ps)
	}
	return statuses, rows.Err()
}
