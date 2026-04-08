package store

import "database/sql"

func ensureSchema(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmts := []string{
		`CREATE TABLE IF NOT EXISTS tasks (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			title TEXT NOT NULL,
			status TEXT NOT NULL DEFAULT 'active',
			type TEXT,
			description TEXT,
			created_by TEXT,
			assigned_to TEXT,
			team TEXT,
			plan_id INTEGER,
			tags TEXT,
			acceptance_criteria TEXT,
			current_phase INTEGER DEFAULT 0,
			total_phases INTEGER DEFAULT 0,
			notes TEXT,
			blockers TEXT,
			related_files TEXT,
			hypotheses TEXT,
			decision_log TEXT,
			result TEXT,
			files TEXT,
			commits TEXT,
			schema_version INTEGER DEFAULT 3,
			review_verdict TEXT,
			review_findings TEXT,
			review_timestamp TEXT,
			created_at INTEGER,
			updated_at INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS subtasks (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			task_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
			seq INTEGER,
			title TEXT NOT NULL,
			status TEXT DEFAULT 'pending'
		)`,
		`CREATE TABLE IF NOT EXISTS task_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			task_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
			type TEXT,
			author TEXT,
			title TEXT,
			body TEXT,
			created_at INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS plans (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			title TEXT NOT NULL,
			status TEXT DEFAULT 'draft',
			body TEXT,
			created_at INTEGER,
			updated_at INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS teams (
			window_id TEXT PRIMARY KEY,
			name TEXT,
			type TEXT,
			worktree_path TEXT,
			pane_count INTEGER,
			created_at INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS pane_status (
			pane_id TEXT PRIMARY KEY,
			window_id TEXT,
			role TEXT,
			status TEXT,
			task_id INTEGER,
			task_title TEXT,
			agent TEXT,
			updated_at INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS messages (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			from_pane TEXT,
			to_pane TEXT,
			subject TEXT,
			body TEXT,
			task_id INTEGER,
			read INTEGER DEFAULT 0,
			routed INTEGER DEFAULT 0,
			created_at INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS events (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			type TEXT,
			source TEXT,
			target TEXT,
			task_id INTEGER,
			data TEXT,
			created_at INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS agents (
			name TEXT PRIMARY KEY,
			display_name TEXT,
			model TEXT,
			description TEXT,
			file_path TEXT
		)`,
		`CREATE TABLE IF NOT EXISTS config (
			key TEXT PRIMARY KEY,
			value TEXT,
			source TEXT
		)`,

		`CREATE TABLE IF NOT EXISTS interaction_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			session_name TEXT,
			task_id INTEGER,
			message_text TEXT NOT NULL,
			message_type TEXT DEFAULT 'other',
			source TEXT DEFAULT 'user',
			context TEXT,
			created_at INTEGER
		)`,

		// Indexes
		`CREATE INDEX IF NOT EXISTS idx_interaction_log_session ON interaction_log(session_name)`,
		`CREATE INDEX IF NOT EXISTS idx_interaction_log_task ON interaction_log(task_id)`,
		`CREATE INDEX IF NOT EXISTS idx_interaction_log_type ON interaction_log(message_type)`,
		`CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)`,
		`CREATE INDEX IF NOT EXISTS idx_subtasks_task_id ON subtasks(task_id)`,
		`CREATE INDEX IF NOT EXISTS idx_task_log_task_id ON task_log(task_id)`,
		`CREATE INDEX IF NOT EXISTS idx_messages_to_pane ON messages(to_pane)`,
		`CREATE INDEX IF NOT EXISTS idx_events_type ON events(type)`,
		`CREATE INDEX IF NOT EXISTS idx_pane_status_window ON pane_status(window_id)`,
	}

	for _, stmt := range stmts {
		if _, err := tx.Exec(stmt); err != nil {
			return err
		}
	}

	// Migrations — ALTER TABLE ADD COLUMN errors are ignored (column may already exist).
	migrations := []string{
		// subtasks enrichment (task #181)
		`ALTER TABLE subtasks ADD COLUMN assignee TEXT DEFAULT ''`,
		`ALTER TABLE subtasks ADD COLUMN worker TEXT DEFAULT ''`,
		`ALTER TABLE subtasks ADD COLUMN created_at INTEGER DEFAULT 0`,
		`ALTER TABLE subtasks ADD COLUMN completed_at INTEGER DEFAULT 0`,
		// tasks schema parity (task #185)
		`ALTER TABLE tasks ADD COLUMN attachments TEXT DEFAULT ''`,
		`ALTER TABLE tasks ADD COLUMN priority INTEGER DEFAULT 0`,
		`ALTER TABLE tasks ADD COLUMN depends_on TEXT DEFAULT ''`,
		`ALTER TABLE tasks ADD COLUMN merged_into TEXT DEFAULT ''`,
		`ALTER TABLE tasks ADD COLUMN dispatch_mode TEXT DEFAULT ''`,
		`ALTER TABLE tasks ADD COLUMN summary TEXT DEFAULT ''`,
		`ALTER TABLE tasks ADD COLUMN phase TEXT DEFAULT ''`,
		`ALTER TABLE tasks ADD COLUMN intent TEXT DEFAULT ''`,
		// plans: add task_id for plan-task linkage (task #263)
		`ALTER TABLE plans ADD COLUMN task_id INTEGER`,
		// proof-of-completion columns (task #275)
		`ALTER TABLE tasks ADD COLUMN proof_type TEXT DEFAULT ''`,
		`ALTER TABLE tasks ADD COLUMN proof_content TEXT DEFAULT ''`,
		`ALTER TABLE tasks ADD COLUMN verification_status TEXT DEFAULT 'unverified'`,
		`ALTER TABLE tasks ADD COLUMN build_status TEXT DEFAULT ''`,
		// verification steps column (task #278)
		`ALTER TABLE tasks ADD COLUMN verification_steps TEXT DEFAULT ''`,
		// subtask review columns (task #275)
		`ALTER TABLE subtasks ADD COLUMN review_verdict TEXT DEFAULT ''`,
		`ALTER TABLE subtasks ADD COLUMN review_evidence TEXT DEFAULT ''`,
		`ALTER TABLE subtasks ADD COLUMN reviewer TEXT DEFAULT ''`,
		// deferred status reason column (task #301)
		`ALTER TABLE subtasks ADD COLUMN reason TEXT DEFAULT ''`,
		// success criteria + structured proof-of-success (task #332)
		`ALTER TABLE tasks ADD COLUMN success_criteria TEXT DEFAULT ''`,
		`ALTER TABLE tasks ADD COLUMN proof_of_success TEXT DEFAULT ''`,
		// shortname field (task #8)
		`ALTER TABLE tasks ADD COLUMN shortname TEXT DEFAULT ''`,
		// origin_prompt field (task #24)
		`ALTER TABLE tasks ADD COLUMN origin_prompt TEXT DEFAULT ''`,
	}
	for _, stmt := range migrations {
		tx.Exec(stmt) // ignore "duplicate column" errors
	}

	return tx.Commit()
}
