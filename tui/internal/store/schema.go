package store

import (
	"database/sql"
	"strings"
)

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
			schema_version INTEGER DEFAULT 4,
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
			color TEXT NOT NULL DEFAULT '',
			memory TEXT NOT NULL DEFAULT '',
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
		// agent color field (task #36)
		`ALTER TABLE agents ADD COLUMN color TEXT DEFAULT ''`,
		// agent memory field (task #511)
		`ALTER TABLE agents ADD COLUMN memory TEXT DEFAULT ''`,
		// schema v4: constraints + running summary (task #575)
		`ALTER TABLE tasks ADD COLUMN constraints TEXT DEFAULT ''`,
		`ALTER TABLE tasks ADD COLUMN running_summary TEXT DEFAULT ''`,
	}
	for _, stmt := range migrations {
		tx.Exec(stmt) // ignore "duplicate column" errors
	}

	// 525: transactional migration — atomic batch, NOT per-statement-ignored
	// like older entries. Ships as a logical BEGIN ... COMMIT batch: statements
	// execute within the enclosing ensureSchema transaction, so any non-"duplicate
	// column" error on any statement rolls back the entire schema+migration
	// transaction (partial-migration state is impossible). Coordinated with task
	// #521 — class discriminator is additive; either task may land first.
	//
	// Logical SQL (runs via the enclosing tx):
	//   BEGIN;
	//   ALTER TABLE events ADD COLUMN class TEXT DEFAULT '';
	//   ALTER TABLE events ADD COLUMN severity TEXT DEFAULT '';
	//   ALTER TABLE events ADD COLUMN session TEXT DEFAULT '';
	//   ALTER TABLE events ADD COLUMN role TEXT DEFAULT '';
	//   ALTER TABLE events ADD COLUMN window_id TEXT DEFAULT '';
	//   ALTER TABLE events ADD COLUMN wake_reason TEXT DEFAULT '';
	//   ALTER TABLE events ADD COLUMN unread_msg_ids TEXT DEFAULT '';
	//   ALTER TABLE events ADD COLUMN extra_json TEXT DEFAULT '';
	//   ALTER TABLE events ADD COLUMN consecutive_count INTEGER DEFAULT 0;
	//   ALTER TABLE events ADD COLUMN window_sec INTEGER DEFAULT 0;
	//   CREATE INDEX IF NOT EXISTS idx_events_class_created ON events(class, created_at DESC);
	//   CREATE INDEX IF NOT EXISTS idx_events_severity ON events(severity);
	//   COMMIT;
	events525 := []string{
		`ALTER TABLE events ADD COLUMN class TEXT DEFAULT ''`,
		`ALTER TABLE events ADD COLUMN severity TEXT DEFAULT ''`,
		`ALTER TABLE events ADD COLUMN session TEXT DEFAULT ''`,
		`ALTER TABLE events ADD COLUMN role TEXT DEFAULT ''`,
		`ALTER TABLE events ADD COLUMN window_id TEXT DEFAULT ''`,
		`ALTER TABLE events ADD COLUMN wake_reason TEXT DEFAULT ''`,
		`ALTER TABLE events ADD COLUMN unread_msg_ids TEXT DEFAULT ''`,
		`ALTER TABLE events ADD COLUMN extra_json TEXT DEFAULT ''`,
		`ALTER TABLE events ADD COLUMN consecutive_count INTEGER DEFAULT 0`,
		`ALTER TABLE events ADD COLUMN window_sec INTEGER DEFAULT 0`,
		`CREATE INDEX IF NOT EXISTS idx_events_class_created ON events(class, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_events_severity ON events(severity)`,
	}
	for _, stmt := range events525 {
		if _, err := tx.Exec(stmt); err != nil && !isDuplicateColumnErr(err) {
			return err
		}
	}

	// schema v4 (task #659): URL extraction table + FTS5 search.
	// task_urls indexes URLs found in task title/description/notes/etc., one
	// row per URL+field. Idempotent re-extract is handled at the application
	// layer (DELETE WHERE task_id=? AND field=?, then INSERT new set).
	v4 := []string{
		`CREATE TABLE IF NOT EXISTS task_urls (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			task_id INTEGER NOT NULL,
			url TEXT NOT NULL,
			host TEXT NOT NULL,
			kind TEXT NOT NULL,
			field TEXT NOT NULL,
			ts TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_task_urls_host_ts ON task_urls(host, ts)`,
		`CREATE INDEX IF NOT EXISTS idx_task_urls_task_id ON task_urls(task_id)`,
		`CREATE INDEX IF NOT EXISTS idx_task_urls_task_field ON task_urls(task_id, field)`,

		// FTS5 full-text search over tasks (title, description, shortname) and messages (body).
		// task_id / msg_id are UNINDEXED — stored alongside the rowid for query convenience.
		`CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(
			task_id UNINDEXED,
			title,
			description,
			shortname,
			tokenize="porter unicode61"
		)`,
		`CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
			msg_id UNINDEXED,
			body,
			tokenize="porter unicode61"
		)`,

		// Triggers — keep FTS shadow tables in sync with source rows.
		`CREATE TRIGGER IF NOT EXISTS tasks_fts_ai AFTER INSERT ON tasks BEGIN
			INSERT INTO tasks_fts(rowid, task_id, title, description, shortname)
			VALUES (NEW.id, NEW.id, COALESCE(NEW.title,''), COALESCE(NEW.description,''), COALESCE(NEW.shortname,''));
		END`,
		`CREATE TRIGGER IF NOT EXISTS tasks_fts_ad AFTER DELETE ON tasks BEGIN
			DELETE FROM tasks_fts WHERE rowid = OLD.id;
		END`,
		`CREATE TRIGGER IF NOT EXISTS tasks_fts_au AFTER UPDATE ON tasks BEGIN
			DELETE FROM tasks_fts WHERE rowid = OLD.id;
			INSERT INTO tasks_fts(rowid, task_id, title, description, shortname)
			VALUES (NEW.id, NEW.id, COALESCE(NEW.title,''), COALESCE(NEW.description,''), COALESCE(NEW.shortname,''));
		END`,
		`CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
			INSERT INTO messages_fts(rowid, msg_id, body)
			VALUES (NEW.id, NEW.id, COALESCE(NEW.body,''));
		END`,
		`CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
			DELETE FROM messages_fts WHERE rowid = OLD.id;
		END`,
		`CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE ON messages BEGIN
			DELETE FROM messages_fts WHERE rowid = OLD.id;
			INSERT INTO messages_fts(rowid, msg_id, body)
			VALUES (NEW.id, NEW.id, COALESCE(NEW.body,''));
		END`,

		// Backfill existing rows that predate the FTS tables. The triggers
		// above only fire on future writes; without this, an upgraded DB
		// would have an empty FTS index until each row is touched.
		`INSERT INTO tasks_fts(rowid, task_id, title, description, shortname)
			SELECT id, id, COALESCE(title,''), COALESCE(description,''), COALESCE(shortname,'')
			FROM tasks
			WHERE id NOT IN (SELECT rowid FROM tasks_fts)`,
		`INSERT INTO messages_fts(rowid, msg_id, body)
			SELECT id, id, COALESCE(body,'')
			FROM messages
			WHERE id NOT IN (SELECT rowid FROM messages_fts)`,
	}
	for _, stmt := range v4 {
		if _, err := tx.Exec(stmt); err != nil {
			return err
		}
	}

	return tx.Commit()
}

// isDuplicateColumnErr returns true for the benign "duplicate column" error
// returned when an ALTER TABLE ADD COLUMN runs against a schema that already
// contains the column. Every other error (syntax, constraint, I/O) is
// propagated so the enclosing transaction rolls back — that is the difference
// between the transactional 525 migration block and the older error-ignored
// migrations above.
func isDuplicateColumnErr(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "duplicate column")
}
