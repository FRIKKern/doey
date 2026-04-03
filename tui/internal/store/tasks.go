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
	Notes              string `json:"notes,omitempty"`
	Blockers           string `json:"blockers,omitempty"`
	RelatedFiles       string `json:"related_files,omitempty"`
	Hypotheses         string `json:"hypotheses,omitempty"`
	DecisionLog        string `json:"decision_log,omitempty"`
	Result             string `json:"result,omitempty"`
	Files              string `json:"files,omitempty"`
	Commits            string `json:"commits,omitempty"`
	SchemaVersion      int    `json:"schema_version"`
	ReviewVerdict      string `json:"review_verdict,omitempty"`
	ReviewFindings     string `json:"review_findings,omitempty"`
	ReviewTimestamp    string `json:"review_timestamp,omitempty"`
	CreatedAt          int64  `json:"created_at"`
	UpdatedAt          int64  `json:"updated_at"`
}

type Subtask struct {
	ID          int64  `json:"id"`
	TaskID      int64  `json:"task_id"`
	Seq         int    `json:"seq"`
	Title       string `json:"title"`
	Status      string `json:"status"`
	Assignee    string `json:"assignee,omitempty"`
	Worker      string `json:"worker,omitempty"`
	CreatedAt   int64  `json:"created_at,omitempty"`
	CompletedAt int64  `json:"completed_at,omitempty"`
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
	if t.CreatedAt == 0 {
		t.CreatedAt = now
	}
	if t.UpdatedAt == 0 {
		t.UpdatedAt = now
	}

	// When t.ID is set, preserve it (e.g., syncing from file-based tasks).
	// SQLite allows explicit INTEGER PRIMARY KEY values with AUTOINCREMENT.
	if t.ID != 0 {
		_, err := s.db.Exec(`INSERT INTO tasks
			(id, title, status, type, description, created_by, assigned_to, team,
			 plan_id, tags, acceptance_criteria, current_phase, total_phases,
			 notes, blockers, related_files, hypotheses, decision_log, result,
			 files, commits, schema_version, review_verdict, review_findings,
			 review_timestamp, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			t.ID, t.Title, t.Status, t.Type, t.Description, t.CreatedBy, t.AssignedTo, t.Team,
			t.PlanID, t.Tags, t.AcceptanceCriteria, t.CurrentPhase, t.TotalPhases,
			t.Notes, t.Blockers, t.RelatedFiles, t.Hypotheses, t.DecisionLog, t.Result,
			t.Files, t.Commits, t.SchemaVersion, t.ReviewVerdict, t.ReviewFindings,
			t.ReviewTimestamp, t.CreatedAt, t.UpdatedAt,
		)
		if err != nil {
			return 0, err
		}
		return t.ID, nil
	}

	res, err := s.db.Exec(`INSERT INTO tasks
		(title, status, type, description, created_by, assigned_to, team,
		 plan_id, tags, acceptance_criteria, current_phase, total_phases,
		 notes, blockers, related_files, hypotheses, decision_log, result,
		 files, commits, schema_version, review_verdict, review_findings,
		 review_timestamp, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		t.Title, t.Status, t.Type, t.Description, t.CreatedBy, t.AssignedTo, t.Team,
		t.PlanID, t.Tags, t.AcceptanceCriteria, t.CurrentPhase, t.TotalPhases,
		t.Notes, t.Blockers, t.RelatedFiles, t.Hypotheses, t.DecisionLog, t.Result,
		t.Files, t.Commits, t.SchemaVersion, t.ReviewVerdict, t.ReviewFindings,
		t.ReviewTimestamp, t.CreatedAt, t.UpdatedAt,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// scanTask scans a task row into a Task struct, handling NULL text columns
// via sql.NullString so that NULL becomes "".
func scanTask(scanner interface{ Scan(...any) error }) (Task, error) {
	var t Task
	var (
		typ, desc, createdBy, assignedTo, team          sql.NullString
		tags, acceptCrit, notes, blockers, relFiles     sql.NullString
		hypotheses, decisionLog, result, files, commits sql.NullString
		reviewVerdict, reviewFindings, reviewTimestamp   sql.NullString
	)
	err := scanner.Scan(
		&t.ID, &t.Title, &t.Status, &typ, &desc, &createdBy, &assignedTo, &team,
		&t.PlanID, &tags, &acceptCrit, &t.CurrentPhase, &t.TotalPhases,
		&notes, &blockers, &relFiles, &hypotheses, &decisionLog, &result,
		&files, &commits, &t.SchemaVersion, &reviewVerdict, &reviewFindings,
		&reviewTimestamp, &t.CreatedAt, &t.UpdatedAt,
	)
	if err != nil {
		return t, err
	}
	t.Type = typ.String
	t.Description = desc.String
	t.CreatedBy = createdBy.String
	t.AssignedTo = assignedTo.String
	t.Team = team.String
	t.Tags = tags.String
	t.AcceptanceCriteria = acceptCrit.String
	t.Notes = notes.String
	t.Blockers = blockers.String
	t.RelatedFiles = relFiles.String
	t.Hypotheses = hypotheses.String
	t.DecisionLog = decisionLog.String
	t.Result = result.String
	t.Files = files.String
	t.Commits = commits.String
	t.ReviewVerdict = reviewVerdict.String
	t.ReviewFindings = reviewFindings.String
	t.ReviewTimestamp = reviewTimestamp.String
	return t, nil
}

func (s *Store) GetTask(id int64) (*Task, error) {
	row := s.db.QueryRow(`SELECT
		id, title, status, type, description, created_by, assigned_to, team,
		plan_id, tags, acceptance_criteria, current_phase, total_phases,
		notes, blockers, related_files, hypotheses, decision_log, result,
		files, commits, schema_version, review_verdict, review_findings,
		review_timestamp, created_at, updated_at
		FROM tasks WHERE id = ?`, id)
	t, err := scanTask(row)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func (s *Store) ListTasks(status string) ([]Task, error) {
	var rows *sql.Rows
	var err error
	if status == "" {
		rows, err = s.db.Query(`SELECT
			id, title, status, type, description, created_by, assigned_to, team,
			plan_id, tags, acceptance_criteria, current_phase, total_phases,
			notes, blockers, related_files, hypotheses, decision_log, result,
			files, commits, schema_version, review_verdict, review_findings,
			review_timestamp, created_at, updated_at
			FROM tasks ORDER BY updated_at DESC`)
	} else {
		rows, err = s.db.Query(`SELECT
			id, title, status, type, description, created_by, assigned_to, team,
			plan_id, tags, acceptance_criteria, current_phase, total_phases,
			notes, blockers, related_files, hypotheses, decision_log, result,
			files, commits, schema_version, review_verdict, review_findings,
			review_timestamp, created_at, updated_at
			FROM tasks WHERE status = ? ORDER BY updated_at DESC`, status)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tasks []Task
	for rows.Next() {
		t, err := scanTask(rows)
		if err != nil {
			return nil, err
		}
		tasks = append(tasks, t)
	}
	return tasks, rows.Err()
}

func (s *Store) UpdateTask(t *Task) error {
	if t.UpdatedAt == 0 {
		t.UpdatedAt = time.Now().Unix()
	}
	_, err := s.db.Exec(`UPDATE tasks SET
		title = ?, status = ?, type = ?, description = ?, created_by = ?,
		assigned_to = ?, team = ?, plan_id = ?, tags = ?, acceptance_criteria = ?,
		current_phase = ?, total_phases = ?, notes = ?, blockers = ?,
		related_files = ?, hypotheses = ?, decision_log = ?, result = ?,
		files = ?, commits = ?, schema_version = ?, review_verdict = ?,
		review_findings = ?, review_timestamp = ?, updated_at = ?
		WHERE id = ?`,
		t.Title, t.Status, t.Type, t.Description, t.CreatedBy,
		t.AssignedTo, t.Team, t.PlanID, t.Tags, t.AcceptanceCriteria,
		t.CurrentPhase, t.TotalPhases, t.Notes, t.Blockers,
		t.RelatedFiles, t.Hypotheses, t.DecisionLog, t.Result,
		t.Files, t.Commits, t.SchemaVersion, t.ReviewVerdict,
		t.ReviewFindings, t.ReviewTimestamp, t.UpdatedAt,
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
	res, err := s.db.Exec(`INSERT INTO subtasks (task_id, seq, title, status, assignee, worker, created_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		st.TaskID, st.Seq, st.Title, st.Status, st.Assignee, st.Worker, st.CreatedAt, st.CompletedAt,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) ListSubtasks(taskID int64) ([]Subtask, error) {
	rows, err := s.db.Query(`SELECT id, task_id, seq, title, status, assignee, worker, created_at, completed_at FROM subtasks WHERE task_id = ? ORDER BY seq`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var subtasks []Subtask
	for rows.Next() {
		var st Subtask
		if err := rows.Scan(&st.ID, &st.TaskID, &st.Seq, &st.Title, &st.Status, &st.Assignee, &st.Worker, &st.CreatedAt, &st.CompletedAt); err != nil {
			return nil, err
		}
		subtasks = append(subtasks, st)
	}
	return subtasks, rows.Err()
}

func (s *Store) UpdateSubtask(st *Subtask) error {
	_, err := s.db.Exec(`UPDATE subtasks SET title = ?, status = ?, assignee = ?, worker = ?, created_at = ?, completed_at = ? WHERE id = ?`,
		st.Title, st.Status, st.Assignee, st.Worker, st.CreatedAt, st.CompletedAt, st.ID,
	)
	return err
}

// GetSubtaskBySeq returns the subtask for a given task and sequence number.
func (s *Store) GetSubtaskBySeq(taskID int64, seq int) (*Subtask, error) {
	var st Subtask
	err := s.db.QueryRow(`SELECT id, task_id, seq, title, status, assignee, worker, created_at, completed_at FROM subtasks WHERE task_id = ? AND seq = ?`, taskID, seq).
		Scan(&st.ID, &st.TaskID, &st.Seq, &st.Title, &st.Status, &st.Assignee, &st.Worker, &st.CreatedAt, &st.CompletedAt)
	if err != nil {
		return nil, err
	}
	return &st, nil
}

// GetSubtaskByID returns the subtask by its DB primary key.
func (s *Store) GetSubtaskByID(id int64) (*Subtask, error) {
	var st Subtask
	err := s.db.QueryRow(`SELECT id, task_id, seq, title, status, assignee, worker, created_at, completed_at FROM subtasks WHERE id = ?`, id).
		Scan(&st.ID, &st.TaskID, &st.Seq, &st.Title, &st.Status, &st.Assignee, &st.Worker, &st.CreatedAt, &st.CompletedAt)
	if err != nil {
		return nil, err
	}
	return &st, nil
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
