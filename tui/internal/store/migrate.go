package store

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// MigrateResult tracks what was migrated.
type MigrateResult struct {
	Tasks    int      `json:"tasks"`
	Plans    int      `json:"plans"`
	Agents   int      `json:"agents"`
	Statuses int      `json:"statuses"`
	Messages int      `json:"messages"`
	Config   int      `json:"config"`
	Errors   []string `json:"errors,omitempty"`
}

// Migrate reads existing file-based data and inserts into the store.
// Idempotent — uses INSERT OR IGNORE to skip existing records.
// Missing directories are silently skipped.
func (s *Store) Migrate(projectDir, runtimeDir string) (*MigrateResult, error) {
	r := &MigrateResult{}

	s.migrateTasks(projectDir, r)
	s.migratePlans(projectDir, r)
	s.migrateAgents(projectDir, r)
	s.migrateConfig(projectDir, r)

	if runtimeDir != "" {
		s.migrateStatuses(runtimeDir, r)
		s.migrateMessages(runtimeDir, r)
	}

	return r, nil
}

// --- Tasks ---

// migrateTasks is a no-op. Disabled in Phase 4: DB is now the primary store.
// .task files are no longer imported during migration.
func (s *Store) migrateTasks(projectDir string, r *MigrateResult) {
}

func (s *Store) migrateOneTask(path string, r *MigrateResult) error {
	fields, err := parseKeyValue(path)
	if err != nil {
		return err
	}

	idStr := fields["TASK_ID"]
	if idStr == "" {
		return fmt.Errorf("missing TASK_ID")
	}
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return fmt.Errorf("bad TASK_ID %q: %w", idStr, err)
	}

	// Skip if already exists
	var exists int
	s.db.QueryRow(`SELECT 1 FROM tasks WHERE id = ?`, id).Scan(&exists)
	if exists == 1 {
		return nil
	}

	if err := s.upsertTaskFromFields(id, fields); err != nil {
		return err
	}
	r.Tasks++
	return nil
}

// upsertTaskFromFields inserts or replaces a task row from parsed .task file fields.
// Also syncs subtasks, decision log, and notes.
func (s *Store) upsertTaskFromFields(id int64, fields map[string]string) error {
	createdAt := parseTimestampField(fields["TASK_TIMESTAMPS"], "created")
	if createdAt == 0 {
		createdAt = time.Now().Unix()
	}
	updatedAt := atoi64(fields["TASK_UPDATED"])
	if updatedAt == 0 {
		updatedAt = createdAt
	}

	var planID *int64
	if v := fields["TASK_PLAN_ID"]; v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err == nil {
			planID = &n
		}
	}

	_, err := s.db.Exec(`INSERT INTO tasks
		(id, title, status, type, description, created_by, assigned_to, team,
		 plan_id, tags, acceptance_criteria, current_phase, total_phases,
		 notes, blockers, related_files, hypotheses, decision_log, result,
		 files, commits, schema_version, review_verdict, review_findings,
		 review_timestamp, attachments, priority, depends_on, merged_into,
		 dispatch_mode, summary, phase, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
		 title=excluded.title, status=excluded.status, type=excluded.type,
		 description=excluded.description, created_by=excluded.created_by,
		 assigned_to=excluded.assigned_to, team=excluded.team, plan_id=excluded.plan_id,
		 tags=excluded.tags, acceptance_criteria=excluded.acceptance_criteria,
		 current_phase=excluded.current_phase, total_phases=excluded.total_phases,
		 notes=excluded.notes, blockers=excluded.blockers, related_files=excluded.related_files,
		 hypotheses=excluded.hypotheses, decision_log=excluded.decision_log, result=excluded.result,
		 files=excluded.files, commits=excluded.commits, schema_version=excluded.schema_version,
		 review_verdict=excluded.review_verdict, review_findings=excluded.review_findings,
		 review_timestamp=excluded.review_timestamp, attachments=excluded.attachments,
		 priority=excluded.priority, depends_on=excluded.depends_on,
		 merged_into=excluded.merged_into, dispatch_mode=excluded.dispatch_mode,
		 summary=excluded.summary, phase=excluded.phase, updated_at=excluded.updated_at`,
		id, fields["TASK_TITLE"], fields["TASK_STATUS"], fields["TASK_TYPE"],
		fields["TASK_DESCRIPTION"], fields["TASK_CREATED_BY"], fields["TASK_ASSIGNED_TO"],
		fields["TASK_TEAM"], planID, fields["TASK_TAGS"],
		fields["TASK_ACCEPTANCE_CRITERIA"],
		atoi(fields["TASK_CURRENT_PHASE"]), atoi(fields["TASK_TOTAL_PHASES"]),
		fields["TASK_NOTES"], fields["TASK_BLOCKERS"], fields["TASK_RELATED_FILES"],
		fields["TASK_HYPOTHESES"], fields["TASK_DECISION_LOG"], fields["TASK_RESULT"],
		fields["TASK_FILES"], fields["TASK_COMMITS"],
		atoi(fields["TASK_SCHEMA_VERSION"]),
		fields["TASK_REVIEW_VERDICT"], fields["TASK_REVIEW_FINDINGS"],
		fields["TASK_REVIEW_TIMESTAMP"],
		fields["TASK_ATTACHMENTS"], atoi(fields["TASK_PRIORITY"]),
		fields["TASK_DEPENDS_ON"], fields["TASK_MERGED_INTO"],
		fields["TASK_DISPATCH_MODE"], fields["TASK_SUMMARY"], fields["TASK_PHASE"],
		createdAt, updatedAt,
	)
	if err != nil {
		return err
	}

	// Subtasks — prefer TASK_SUBTASK_N_* extension fields over inline TASK_SUBTASKS.
	// Extension format: TASK_SUBTASK_1_TITLE=..., TASK_SUBTASK_1_STATUS=..., etc.
	type subtaskExt struct {
		title       string
		status      string
		assignee    string
		worker      string
		createdAt   int64
		completedAt int64
	}
	extMap := make(map[int]*subtaskExt)
	for key, val := range fields {
		if !strings.HasPrefix(key, "TASK_SUBTASK_") {
			continue
		}
		rest := strings.TrimPrefix(key, "TASK_SUBTASK_")
		parts := strings.SplitN(rest, "_", 2)
		if len(parts) != 2 {
			continue
		}
		idx, err := strconv.Atoi(parts[0])
		if err != nil {
			continue
		}
		if extMap[idx] == nil {
			extMap[idx] = &subtaskExt{}
		}
		switch parts[1] {
		case "TITLE":
			extMap[idx].title = val
		case "STATUS":
			extMap[idx].status = val
		case "ASSIGNEE":
			extMap[idx].assignee = val
		case "WORKER":
			extMap[idx].worker = val
		case "CREATED_AT":
			extMap[idx].createdAt = atoi64(val)
		case "COMPLETED_AT":
			extMap[idx].completedAt = atoi64(val)
		}
	}

	if len(extMap) > 0 {
		// Use extension fields (richer data)
		s.db.Exec(`DELETE FROM subtasks WHERE task_id = ?`, id)
		for seq, ext := range extMap {
			status := ext.status
			if status == "" {
				status = "pending"
			}
			s.db.Exec(`INSERT INTO subtasks (task_id, seq, title, status, assignee, worker, created_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
				id, seq, ext.title, status, ext.assignee, ext.worker, ext.createdAt, ext.completedAt)
		}
	} else if raw := fields["TASK_SUBTASKS"]; raw != "" {
		// Fallback: inline format "idx:title:status\nidx:title:status"
		s.db.Exec(`DELETE FROM subtasks WHERE task_id = ?`, id)
		for seq, entry := range splitLiteralNewlines(raw) {
			parts := strings.SplitN(entry, ":", 3)
			if len(parts) < 3 {
				continue
			}
			title := parts[1]
			status := parts[2]
			s.db.Exec(`INSERT INTO subtasks (task_id, seq, title, status, assignee, worker, created_at, completed_at) VALUES (?, ?, ?, ?, '', '', 0, 0)`,
				id, seq+1, title, status)
		}
	}

	// Decision log — format: "timestamp:text\ntimestamp:text"
	// Clear existing decision entries for this task and rewrite
	if raw := fields["TASK_DECISION_LOG"]; raw != "" {
		s.db.Exec(`DELETE FROM task_log WHERE task_id = ? AND type = 'decision'`, id)
		for _, entry := range splitLiteralNewlines(raw) {
			ts, text := splitFirst(entry, ':')
			tsInt := atoi64(ts)
			if tsInt == 0 {
				tsInt = time.Now().Unix()
			}
			s.db.Exec(`INSERT INTO task_log (task_id, type, author, title, body, created_at) VALUES (?, 'decision', '', ?, '', ?)`,
				id, text, tsInt)
		}
	}

	// Notes
	if raw := fields["TASK_NOTES"]; raw != "" {
		s.db.Exec(`DELETE FROM task_log WHERE task_id = ? AND type = 'note'`, id)
		s.db.Exec(`INSERT INTO task_log (task_id, type, author, title, body, created_at) VALUES (?, 'note', '', 'note', ?, ?)`,
			id, raw, createdAt)
	}

	// Reports — TASK_REPORT_N_TIMESTAMP/AUTHOR/TYPE/TITLE/BODY
	type reportEntry struct {
		timestamp int64
		author    string
		typ       string
		title     string
		body      string
	}
	reportMap := make(map[int]*reportEntry)
	for key, val := range fields {
		if !strings.HasPrefix(key, "TASK_REPORT_") {
			continue
		}
		rest := strings.TrimPrefix(key, "TASK_REPORT_")
		parts := strings.SplitN(rest, "_", 2)
		if len(parts) != 2 {
			continue
		}
		idx, err := strconv.Atoi(parts[0])
		if err != nil {
			continue
		}
		if reportMap[idx] == nil {
			reportMap[idx] = &reportEntry{}
		}
		switch parts[1] {
		case "TIMESTAMP":
			reportMap[idx].timestamp = atoi64(val)
		case "AUTHOR":
			reportMap[idx].author = val
		case "TYPE":
			reportMap[idx].typ = val
		case "TITLE":
			reportMap[idx].title = val
		case "BODY":
			reportMap[idx].body = val
		}
	}
	if len(reportMap) > 0 {
		s.db.Exec(`DELETE FROM task_log WHERE task_id = ? AND type LIKE 'report:%'`, id)
		for _, r := range reportMap {
			typ := r.typ
			if typ == "" {
				typ = "report"
			}
			if !strings.HasPrefix(typ, "report") {
				typ = "report:" + typ
			}
			ts := r.timestamp
			if ts == 0 {
				ts = createdAt
			}
			s.db.Exec(`INSERT INTO task_log (task_id, type, author, title, body, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
				id, typ, r.author, r.title, r.body, ts)
		}
	}

	return nil
}

// SyncTaskFiles is a no-op. Disabled in Phase 4: DB is now the primary store.
// .task files are no longer synced into the DB. Use 'doey-ctl task export' for
// .task file generation from the DB.
func (s *Store) SyncTaskFiles(tasksDir string) (int, []string) {
	return 0, nil
}

// --- Plans ---

func (s *Store) migratePlans(projectDir string, r *MigrateResult) {
	plansDir := filepath.Join(projectDir, ".doey", "plans")
	entries, err := os.ReadDir(plansDir)
	if err != nil {
		return
	}

	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		if err := s.migrateOnePlan(filepath.Join(plansDir, e.Name()), r); err != nil {
			r.Errors = append(r.Errors, fmt.Sprintf("plan %s: %v", e.Name(), err))
		}
	}
}

func (s *Store) migrateOnePlan(path string, r *MigrateResult) error {
	fm, body, err := parseFrontmatter(path)
	if err != nil {
		return err
	}

	// Determine ID from frontmatter or filename
	idStr := fm["plan_id"]
	if idStr == "" {
		idStr = fm["id"]
	}
	if idStr == "" {
		base := strings.TrimSuffix(filepath.Base(path), ".md")
		idStr = base
	}
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		r.Errors = append(r.Errors, fmt.Sprintf("plan %s: skipping non-numeric plan ID %q", filepath.Base(path), idStr))
		return nil
	}

	var exists int
	s.db.QueryRow(`SELECT 1 FROM plans WHERE id = ?`, id).Scan(&exists)
	if exists == 1 {
		return nil
	}

	title := fm["title"]
	status := fm["status"]
	if status == "" {
		status = "draft"
	}

	createdAt := parseTimeString(fm["created"])
	updatedAt := parseTimeString(fm["updated"])
	if createdAt == 0 {
		createdAt = time.Now().Unix()
	}
	if updatedAt == 0 {
		updatedAt = createdAt
	}

	_, err = s.db.Exec(`INSERT OR IGNORE INTO plans (id, title, status, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`,
		id, title, status, body, createdAt, updatedAt)
	if err != nil {
		return err
	}
	r.Plans++
	return nil
}

// --- Agents ---

func (s *Store) migrateAgents(projectDir string, r *MigrateResult) {
	agentsDir := filepath.Join(projectDir, "agents")
	entries, err := os.ReadDir(agentsDir)
	if err != nil {
		return
	}

	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		if err := s.migrateOneAgent(filepath.Join(agentsDir, e.Name()), r); err != nil {
			r.Errors = append(r.Errors, fmt.Sprintf("agent %s: %v", e.Name(), err))
		}
	}
}

func (s *Store) migrateOneAgent(path string, r *MigrateResult) error {
	fm, _, err := parseFrontmatter(path)
	if err != nil {
		return err
	}

	name := fm["name"]
	if name == "" {
		name = strings.TrimSuffix(filepath.Base(path), ".md")
	}

	_, err = s.db.Exec(`INSERT OR IGNORE INTO agents (name, display_name, model, description, file_path) VALUES (?, ?, ?, ?, ?)`,
		name, fm["display_name"], fm["model"], fm["description"], path)
	if err != nil {
		return err
	}
	r.Agents++
	return nil
}

// --- Statuses ---

func (s *Store) migrateStatuses(runtimeDir string, r *MigrateResult) {
	statusDir := filepath.Join(runtimeDir, "status")
	entries, err := os.ReadDir(statusDir)
	if err != nil {
		return
	}

	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".status") {
			continue
		}
		if err := s.migrateOneStatus(filepath.Join(statusDir, e.Name()), r); err != nil {
			r.Errors = append(r.Errors, fmt.Sprintf("status %s: %v", e.Name(), err))
		}
	}
}

func (s *Store) migrateOneStatus(path string, r *MigrateResult) error {
	fields, err := parseColonKV(path)
	if err != nil {
		return err
	}

	paneID := fields["PANE"]
	if paneID == "" {
		return fmt.Errorf("missing PANE field")
	}

	// Derive pane_id (safe name) from filename
	paneSafe := strings.TrimSuffix(filepath.Base(path), ".status")

	updatedAt := parseTimeString(fields["UPDATED"])
	if updatedAt == 0 {
		updatedAt = time.Now().Unix()
	}

	// Extract window_id from pane — e.g. "doey-foo:1.2" → window part
	windowID := ""
	if idx := strings.Index(paneID, ":"); idx >= 0 {
		rest := paneID[idx+1:]
		if dot := strings.Index(rest, "."); dot >= 0 {
			windowID = rest[:dot]
		}
	}

	var taskID *int64
	if v := fields["TASK_ID"]; v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err == nil {
			taskID = &n
		}
	}

	_, err = s.db.Exec(`INSERT OR REPLACE INTO pane_status (pane_id, window_id, role, status, task_id, task_title, agent, updated_at)
		VALUES (?, ?, '', ?, ?, ?, '', ?)`,
		paneSafe, windowID, fields["STATUS"], taskID, fields["TASK"], updatedAt)
	if err != nil {
		return err
	}
	r.Statuses++
	return nil
}

// --- Messages ---

func (s *Store) migrateMessages(runtimeDir string, r *MigrateResult) {
	msgDir := filepath.Join(runtimeDir, "messages")
	entries, err := os.ReadDir(msgDir)
	if err != nil {
		return
	}

	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".msg") {
			continue
		}
		if err := s.migrateOneMessage(filepath.Join(msgDir, e.Name()), e.Name(), r); err != nil {
			r.Errors = append(r.Errors, fmt.Sprintf("message %s: %v", e.Name(), err))
		}
	}
}

func (s *Store) migrateOneMessage(path, filename string, r *MigrateResult) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	var from, subject string
	var bodyLines []string
	headersDone := false

	for scanner.Scan() {
		line := scanner.Text()
		if !headersDone {
			if strings.HasPrefix(line, "FROM: ") {
				from = strings.TrimPrefix(line, "FROM: ")
				continue
			}
			if strings.HasPrefix(line, "SUBJECT: ") {
				subject = strings.TrimPrefix(line, "SUBJECT: ")
				headersDone = true
				continue
			}
			// Any non-header line means headers are done
			headersDone = true
		}
		bodyLines = append(bodyLines, line)
	}

	// Derive to_pane from filename: {safe}_{timestamp}_{pid}.msg
	// The safe name is everything before the last two underscore-separated parts
	toPane := deriveToPane(filename)

	_, err = s.db.Exec(`INSERT INTO messages (from_pane, to_pane, subject, body, read, created_at) VALUES (?, ?, ?, ?, 1, ?)`,
		from, toPane, subject, strings.Join(bodyLines, "\n"), time.Now().Unix())
	if err != nil {
		return err
	}
	r.Messages++
	return nil
}

// --- Config ---

func (s *Store) migrateConfig(projectDir string, r *MigrateResult) {
	configPath := filepath.Join(projectDir, ".doey", "config.sh")
	f, err := os.Open(configPath)
	if err != nil {
		return // no config file — skip
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "set ") ||
			strings.HasPrefix(line, "source ") || strings.HasPrefix(line, "#!/") {
			continue
		}
		key, value := splitFirst(line, '=')
		if key == "" {
			continue
		}
		// Strip surrounding quotes from value
		value = strings.Trim(value, "\"'")
		// Skip commented-out lines (e.g. "# DOEY_FOO=bar")
		if strings.HasPrefix(key, "#") {
			continue
		}

		_, err := s.db.Exec(`INSERT OR IGNORE INTO config (key, value, source) VALUES (?, ?, 'project')`,
			key, value)
		if err != nil {
			r.Errors = append(r.Errors, fmt.Sprintf("config %s: %v", key, err))
			continue
		}
		r.Config++
	}
}

// --- Parsing helpers ---

// parseKeyValue reads a file of KEY=VALUE lines (task file format).
func parseKeyValue(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	fields := make(map[string]string)
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024) // large buffer for long lines
	for scanner.Scan() {
		line := scanner.Text()
		k, v := splitFirst(line, '=')
		if k != "" {
			fields[k] = v
		}
	}
	return fields, scanner.Err()
}

// parseColonKV reads a file of "KEY: VALUE" lines (status file format).
func parseColonKV(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	fields := make(map[string]string)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		k, v := splitFirst(line, ':')
		if k != "" {
			fields[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	return fields, scanner.Err()
}

// parseFrontmatter reads YAML frontmatter (between --- delimiters) and body.
func parseFrontmatter(path string) (map[string]string, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, "", err
	}
	defer f.Close()

	fm := make(map[string]string)
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	// Find opening ---
	inFrontmatter := false
	var bodyLines []string
	pastFrontmatter := false

	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)

		if !inFrontmatter && !pastFrontmatter && trimmed == "---" {
			inFrontmatter = true
			continue
		}
		if inFrontmatter && trimmed == "---" {
			inFrontmatter = false
			pastFrontmatter = true
			continue
		}
		if inFrontmatter {
			k, v := splitFirst(line, ':')
			k = strings.TrimSpace(k)
			v = strings.TrimSpace(v)
			// Strip quotes
			v = strings.Trim(v, "\"'")
			if k != "" {
				fm[k] = v
			}
			continue
		}
		if pastFrontmatter {
			bodyLines = append(bodyLines, line)
		}
	}

	body := strings.TrimSpace(strings.Join(bodyLines, "\n"))
	return fm, body, scanner.Err()
}

// splitFirst splits s on the first occurrence of sep.
func splitFirst(s string, sep byte) (string, string) {
	i := strings.IndexByte(s, sep)
	if i < 0 {
		return s, ""
	}
	return s[:i], s[i+1:]
}

// splitLiteralNewlines splits on literal "\n" (two-char escape, not actual newline).
func splitLiteralNewlines(s string) []string {
	return strings.Split(s, `\n`)
}

// parseTimestampField extracts a named key from pipe-delimited "key=value|key=value" format.
func parseTimestampField(timestamps, key string) int64 {
	for _, part := range strings.Split(timestamps, "|") {
		k, v := splitFirst(part, '=')
		if k == key {
			return atoi64(v)
		}
	}
	return 0
}

// parseTimeString parses various time formats to unix epoch.
func parseTimeString(s string) int64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	// Try unix epoch first
	if n := atoi64(s); n > 0 {
		return n
	}
	// Try common formats
	for _, layout := range []string{
		time.RFC3339,
		"2006-01-02T15:04:05Z",
		"2006-01-02T15:04:05-0700",
		"2006-01-02T15:04:05+0000",
		"2006-01-02",
	} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.Unix()
		}
	}
	return 0
}

// deriveToPane extracts the target pane safe name from a message filename.
// Format: {safe}_{timestamp}_{pid}.msg
func deriveToPane(filename string) string {
	name := strings.TrimSuffix(filename, ".msg")
	// Remove trailing _{pid} and _{timestamp}
	parts := strings.Split(name, "_")
	if len(parts) > 2 {
		return strings.Join(parts[:len(parts)-2], "_")
	}
	return name
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

func atoi64(s string) int64 {
	n, _ := strconv.ParseInt(s, 10, 64)
	return n
}
