package store

import (
	"database/sql"
	"time"
)

type Task struct {
	ID                 int64  `json:"id"`
	Title              string `json:"title"`
	Status             string `json:"status"`
	Type               string `json:"type,omitempty"`
	Description        string `json:"description,omitempty"`
	CreatedBy          string `json:"created_by,omitempty"`
	AssignedTo         string `json:"assigned_to,omitempty"`
	Team               string `json:"team,omitempty"`
	PlanID             *int64 `json:"plan_id,omitempty"`
	Tags               string `json:"tags,omitempty"`
	AcceptanceCriteria string `json:"acceptance_criteria,omitempty"`
	CurrentPhase       int    `json:"current_phase"`
	TotalPhases        int    `json:"total_phases"`
	CreatedAt          int64  `json:"created_at"`
	UpdatedAt          int64  `json:"updated_at"`
}

type Subtask struct {
	ID     int64  `json:"id"`
	TaskID int64  `json:"task_id"`
	Seq    int    `json:"seq"`
	Title  string `json:"title"`
	Status string `json:"status"`
}

type TaskLogEntry struct {
	ID        int64  `json:"id"`
	TaskID    int64  `json:"task_id"`
	Type      string `json:"type"`
	Author    string `json:"author"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	CreatedAt int64  `json:"created_at"`
}

func (s *Store) CreateTask(t *Task) (int64, error) {
	now := time.Now().Unix()
	t.CreatedAt = now
	t.UpdatedAt = now
	res, err := s.db.Exec(`INSERT INTO tasks
		(title, status, type, description, created_by, assigned_to, team,
		 plan_id, tags, acceptance_criteria, current_phase, total_phases,
		 created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		t.Title, t.Status, t.Type, t.Description, t.CreatedBy, t.AssignedTo, t.Team,
		t.PlanID, t.Tags, t.AcceptanceCriteria, t.CurrentPhase, t.TotalPhases,
		t.CreatedAt, t.UpdatedAt,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) GetTask(id int64) (*Task, error) {
	t := &Task{}
	err := s.db.QueryRow(`SELECT
		id, title, status, type, description, created_by, assigned_to, team,
		plan_id, tags, acceptance_criteria, current_phase, total_phases,
		created_at, updated_at
		FROM tasks WHERE id = ?`, id).Scan(
		&t.ID, &t.Title, &t.Status, &t.Type, &t.Description, &t.CreatedBy, &t.AssignedTo, &t.Team,
		&t.PlanID, &t.Tags, &t.AcceptanceCriteria, &t.CurrentPhase, &t.TotalPhases,
		&t.CreatedAt, &t.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	return t, nil
}

func (s *Store) ListTasks(status string) ([]Task, error) {
	var rows *sql.Rows
	var err error
	if status == "" {
		rows, err = s.db.Query(`SELECT
			id, title, status, type, description, created_by, assigned_to, team,
			plan_id, tags, acceptance_criteria, current_phase, total_phases,
			created_at, updated_at
			FROM tasks ORDER BY created_at DESC`)
	} else {
		rows, err = s.db.Query(`SELECT
			id, title, status, type, description, created_by, assigned_to, team,
			plan_id, tags, acceptance_criteria, current_phase, total_phases,
			created_at, updated_at
			FROM tasks WHERE status = ? ORDER BY created_at DESC`, status)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tasks []Task
	for rows.Next() {
		var t Task
		if err := rows.Scan(
			&t.ID, &t.Title, &t.Status, &t.Type, &t.Description, &t.CreatedBy, &t.AssignedTo, &t.Team,
			&t.PlanID, &t.Tags, &t.AcceptanceCriteria, &t.CurrentPhase, &t.TotalPhases,
			&t.CreatedAt, &t.UpdatedAt,
		); err != nil {
			return nil, err
		}
		tasks = append(tasks, t)
	}
	return tasks, rows.Err()
}

func (s *Store) UpdateTask(t *Task) error {
	t.UpdatedAt = time.Now().Unix()
	_, err := s.db.Exec(`UPDATE tasks SET
		title = ?, status = ?, type = ?, description = ?, created_by = ?,
		assigned_to = ?, team = ?, plan_id = ?, tags = ?, acceptance_criteria = ?,
		current_phase = ?, total_phases = ?, updated_at = ?
		WHERE id = ?`,
		t.Title, t.Status, t.Type, t.Description, t.CreatedBy,
		t.AssignedTo, t.Team, t.PlanID, t.Tags, t.AcceptanceCriteria,
		t.CurrentPhase, t.TotalPhases, t.UpdatedAt,
		t.ID,
	)
	return err
}

func (s *Store) DeleteTask(id int64) error {
	_, err := s.db.Exec(`DELETE FROM tasks WHERE id = ?`, id)
	return err
}

func (s *Store) CreateSubtask(st *Subtask) (int64, error) {
	var maxSeq sql.NullInt64
	err := s.db.QueryRow(`SELECT MAX(seq) FROM subtasks WHERE task_id = ?`, st.TaskID).Scan(&maxSeq)
	if err != nil {
		return 0, err
	}
	if maxSeq.Valid {
		st.Seq = int(maxSeq.Int64) + 1
	} else {
		st.Seq = 1
	}
	res, err := s.db.Exec(`INSERT INTO subtasks (task_id, seq, title, status) VALUES (?, ?, ?, ?)`,
		st.TaskID, st.Seq, st.Title, st.Status,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) ListSubtasks(taskID int64) ([]Subtask, error) {
	rows, err := s.db.Query(`SELECT id, task_id, seq, title, status FROM subtasks WHERE task_id = ? ORDER BY seq`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var subtasks []Subtask
	for rows.Next() {
		var st Subtask
		if err := rows.Scan(&st.ID, &st.TaskID, &st.Seq, &st.Title, &st.Status); err != nil {
			return nil, err
		}
		subtasks = append(subtasks, st)
	}
	return subtasks, rows.Err()
}

func (s *Store) UpdateSubtask(st *Subtask) error {
	_, err := s.db.Exec(`UPDATE subtasks SET title = ?, status = ? WHERE id = ?`,
		st.Title, st.Status, st.ID,
	)
	return err
}

func (s *Store) AddTaskLog(entry *TaskLogEntry) (int64, error) {
	entry.CreatedAt = time.Now().Unix()
	res, err := s.db.Exec(`INSERT INTO task_log (task_id, type, author, title, body, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		entry.TaskID, entry.Type, entry.Author, entry.Title, entry.Body, entry.CreatedAt,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) ListTaskLog(taskID int64) ([]TaskLogEntry, error) {
	rows, err := s.db.Query(`SELECT id, task_id, type, author, title, body, created_at FROM task_log WHERE task_id = ? ORDER BY created_at`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var entries []TaskLogEntry
	for rows.Next() {
		var e TaskLogEntry
		if err := rows.Scan(&e.ID, &e.TaskID, &e.Type, &e.Author, &e.Title, &e.Body, &e.CreatedAt); err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}
