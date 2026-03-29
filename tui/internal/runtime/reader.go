package runtime

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Reader polls Doey runtime files
type Reader struct {
	runtimeDir string
}

// NewReader creates a Reader for the given runtime directory
func NewReader(runtimeDir string) *Reader {
	return &Reader{runtimeDir: runtimeDir}
}

// RuntimeDir returns the configured runtime directory
func (r *Reader) RuntimeDir() string {
	return r.runtimeDir
}

// ReadSnapshot reads all runtime files and returns a complete Snapshot
func (r *Reader) ReadSnapshot() (Snapshot, error) {
	snap := Snapshot{
		Teams:      make(map[int]TeamConfig),
		Panes:      make(map[string]PaneStatus),
		Results:    make(map[string]PaneResult),
		ContextPct: make(map[string]int),
	}

	session, err := r.parseSessionConfig()
	if err != nil {
		return snap, fmt.Errorf("session config: %w", err)
	}
	snap.Session = session

	for _, w := range session.TeamWindows {
		tc, err := r.parseTeamConfig(w)
		if err != nil {
			continue // team file might not exist yet
		}
		snap.Teams[w] = tc
	}

	snap.Panes = r.parsePaneStatuses()
	snap.Tasks = r.parseTasks()
	snap.Subtasks = r.parseSubtasks()

	// Attach subtasks to their parent tasks
	subtasksByTask := make(map[string][]Subtask)
	for _, st := range snap.Subtasks {
		subtasksByTask[st.TaskID] = append(subtasksByTask[st.TaskID], st)
	}
	for i := range snap.Tasks {
		snap.Tasks[i].Subtasks = subtasksByTask[snap.Tasks[i].ID]
	}

	snap.Results = r.parseResults()
	snap.ContextPct = r.parseContextPcts()
	snap.Uptime = r.calculateUptime()

	if session.ProjectDir != "" {
		snap.AgentDefs = r.readAgentDefs(session.ProjectDir)
		snap.TeamDefs = r.readTeamDefs(session.ProjectDir)
	}

	snap.TeamUserCfg, _ = ReadTeamUserConfig()
	snap.TeamEntries = buildTeamEntries(snap.TeamDefs, snap.Teams, snap.TeamUserCfg)
	snap.DebugEntries = r.parseDebugEntries()
	snap.Messages = r.parseMessages()

	return snap, nil
}

// parseEnvFile reads a KEY=VALUE file, stripping quotes
func parseEnvFile(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	env := make(map[string]string)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		idx := strings.IndexByte(line, '=')
		if idx < 0 {
			continue
		}
		key := line[:idx]
		val := line[idx+1:]
		// Strip surrounding quotes
		if len(val) >= 2 {
			if (val[0] == '"' && val[len(val)-1] == '"') ||
				(val[0] == '\'' && val[len(val)-1] == '\'') {
				val = val[1 : len(val)-1]
			}
		}
		env[key] = val
	}
	return env, scanner.Err()
}

func (r *Reader) parseSessionConfig() (SessionConfig, error) {
	env, err := parseEnvFile(filepath.Join(r.runtimeDir, "session.env"))
	if err != nil {
		return SessionConfig{}, err
	}

	sc := SessionConfig{
		SessionName: env["SESSION_NAME"],
		ProjectName: env["PROJECT_NAME"],
		ProjectDir:  env["PROJECT_DIR"],
		RuntimeDir:  r.runtimeDir,
	}

	if tw := env["TEAM_WINDOWS"]; tw != "" {
		for _, s := range strings.Split(tw, ",") {
			s = strings.TrimSpace(s)
			if n, err := strconv.Atoi(s); err == nil {
				sc.TeamWindows = append(sc.TeamWindows, n)
			}
		}
	}

	return sc, nil
}

func (r *Reader) parseTeamConfig(windowIndex int) (TeamConfig, error) {
	path := filepath.Join(r.runtimeDir, fmt.Sprintf("team_%d.env", windowIndex))
	env, err := parseEnvFile(path)
	if err != nil {
		return TeamConfig{}, err
	}

	tc := TeamConfig{
		WindowIndex:    windowIndex,
		Grid:           env["GRID"],
		ManagerPane:    env["MANAGER_PANE"],
		TeamName:       env["TEAM_NAME"],
		TeamType:       env["TEAM_TYPE"],
		TeamDef:        env["TEAM_DEF"],
		WorktreeDir:    env["WORKTREE_DIR"],
		WorktreeBranch: env["WORKTREE_BRANCH"],
	}

	if wc := env["WORKER_COUNT"]; wc != "" {
		tc.WorkerCount, _ = strconv.Atoi(wc)
	}

	if wp := env["WORKER_PANES"]; wp != "" {
		for _, s := range strings.Split(wp, ",") {
			s = strings.TrimSpace(s)
			if n, err := strconv.Atoi(s); err == nil {
				tc.WorkerPanes = append(tc.WorkerPanes, n)
			}
		}
	}

	return tc, nil
}

func (r *Reader) parsePaneStatuses() map[string]PaneStatus {
	statuses := make(map[string]PaneStatus)
	statusDir := filepath.Join(r.runtimeDir, "status")

	matches, err := filepath.Glob(filepath.Join(statusDir, "*.status"))
	if err != nil || len(matches) == 0 {
		return statuses
	}

	for _, path := range matches {
		base := strings.TrimSuffix(filepath.Base(path), ".status")
		ps := PaneStatus{Pane: underscoreToPaneID(base)}

		f, err := os.Open(path)
		if err != nil {
			continue
		}
		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if strings.HasPrefix(line, "STATUS:") {
				ps.Status = strings.TrimSpace(strings.TrimPrefix(line, "STATUS:"))
			} else if strings.HasPrefix(line, "TASK:") {
				ps.Task = strings.TrimSpace(strings.TrimPrefix(line, "TASK:"))
			} else if strings.HasPrefix(line, "UPDATED:") {
				ps.Updated = strings.TrimSpace(strings.TrimPrefix(line, "UPDATED:"))
			}
		}
		f.Close()

		statuses[ps.Pane] = ps
	}

	return statuses
}

func (r *Reader) parseTasks() []Task {
	var tasks []Task
	taskDir := filepath.Join(r.runtimeDir, "tasks")

	matches, err := filepath.Glob(filepath.Join(taskDir, "*.task"))
	if err != nil || len(matches) == 0 {
		return tasks
	}

	for _, path := range matches {
		env, err := parseEnvFile(path)
		if err != nil {
			continue
		}

		t := Task{
			ID:         env["TASK_ID"],
			Title:      env["TASK_TITLE"],
			Status:     env["TASK_STATUS"],
			Team:       env["TASK_TEAM"],
			Priority:   env["TASK_PRIORITY"],
			MergedInto: env["TASK_MERGED_INTO"],
			Result:     env["TASK_RESULT"],
			Category:   env["TASK_TYPE"],
		}
		if t.ID == "" {
			t.ID = strings.TrimSuffix(filepath.Base(path), ".task")
		}
		if c := env["TASK_CREATED"]; c != "" {
			t.Created, _ = strconv.ParseInt(c, 10, 64)
		}
		if desc := env["TASK_DESCRIPTION"]; desc != "" {
			t.Description = strings.ReplaceAll(desc, "\\n", "\n")
		}
		if att := env["TASK_ATTACHMENTS"]; att != "" {
			t.Attachments = strings.Split(att, "|")
		}
		if tags := env["TASK_TAGS"]; tags != "" {
			for _, tag := range strings.Split(tags, ",") {
				tag = strings.TrimSpace(tag)
				if tag != "" {
					t.Tags = append(t.Tags, tag)
				}
			}
		}

		// Parse TASK_LOG_<timestamp>=<text> entries
		for key, val := range env {
			if strings.HasPrefix(key, "TASK_LOG_") {
				tsStr := strings.TrimPrefix(key, "TASK_LOG_")
				ts, err := strconv.ParseInt(tsStr, 10, 64)
				if err != nil {
					continue
				}
				t.Logs = append(t.Logs, TaskLog{Timestamp: ts, Entry: val})
			}
		}
		sort.Slice(t.Logs, func(i, j int) bool {
			return t.Logs[i].Timestamp < t.Logs[j].Timestamp
		})

		tasks = append(tasks, t)
	}

	return tasks
}

func (r *Reader) parseSubtasks() []Subtask {
	var subtasks []Subtask

	// Nested layout: tasks/<task_id>/subtasks/*.subtask
	nestedMatches, _ := filepath.Glob(filepath.Join(r.runtimeDir, "tasks", "*", "subtasks", "*.subtask"))

	// Flat layout: tasks/*.subtask (written by shell scripts)
	flatMatches, _ := filepath.Glob(filepath.Join(r.runtimeDir, "tasks", "*.subtask"))

	seen := make(map[string]bool)
	allMatches := append(nestedMatches, flatMatches...)

	for _, path := range allMatches {
		// Deduplicate by absolute path
		abs, _ := filepath.Abs(path)
		if seen[abs] {
			continue
		}
		seen[abs] = true

		env, err := parseEnvFile(path)
		if err != nil {
			continue
		}

		// Support both prefixed (SUBTASK_*) and unprefixed field names
		taskID := env["SUBTASK_PARENT_TASK_ID"]
		if taskID == "" {
			taskID = env["PARENT_TASK_ID"]
		}
		if taskID == "" {
			taskID = env["TASK_ID"]
		}

		id := env["SUBTASK_ID"]

		pane := env["SUBTASK_WORKER"]
		if pane == "" {
			pane = env["PANE"]
		}

		title := env["SUBTASK_TITLE"]
		if title == "" {
			title = env["TITLE"]
		}

		status := env["SUBTASK_STATUS"]
		if status == "" {
			status = env["STATUS"]
		}

		createdStr := env["SUBTASK_CREATED"]
		if createdStr == "" {
			createdStr = env["CREATED"]
		}
		created, _ := strconv.ParseInt(createdStr, 10, 64)

		updated, _ := strconv.ParseInt(env["UPDATED"], 10, 64)

		st := Subtask{
			TaskID:  taskID,
			Pane:    pane,
			Title:   title,
			Status:  status,
			Created: created,
			Updated: updated,
		}
		// Use SUBTASK_ID as fallback TaskID if still empty
		if st.TaskID == "" && id != "" {
			st.TaskID = id
		}

		subtasks = append(subtasks, st)
	}

	return subtasks
}

func (r *Reader) parseResults() map[string]PaneResult {
	results := make(map[string]PaneResult)
	resultsDir := filepath.Join(r.runtimeDir, "results")

	matches, err := filepath.Glob(filepath.Join(resultsDir, "pane_*.json"))
	if err != nil || len(matches) == 0 {
		return results
	}

	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var pr PaneResult
		if err := json.Unmarshal(data, &pr); err != nil {
			continue
		}
		if pr.Pane == "" {
			// Derive pane ID from filename: pane_W_P.json
			base := strings.TrimSuffix(filepath.Base(path), ".json")
			pr.Pane = underscoreToPaneID(base)
		}
		results[pr.Pane] = pr
	}

	return results
}

func (r *Reader) parseContextPcts() map[string]int {
	pcts := make(map[string]int)

	statusDir := filepath.Join(r.runtimeDir, "status")
	matches, err := filepath.Glob(filepath.Join(statusDir, "context_pct_*"))
	if err != nil || len(matches) == 0 {
		return pcts
	}

	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		val := strings.TrimSpace(string(data))
		pct, err := strconv.Atoi(val)
		if err != nil {
			continue
		}
		// Derive pane ID from filename: context_pct_W_P
		base := filepath.Base(path)
		parts := strings.TrimPrefix(base, "context_pct_")
		paneID := underscoreToPaneID(parts)
		pcts[paneID] = pct
	}

	return pcts
}

func (r *Reader) calculateUptime() time.Duration {
	info, err := os.Stat(filepath.Join(r.runtimeDir, "session.env"))
	if err != nil {
		return 0
	}
	return time.Since(info.ModTime())
}

// readAgentDefs reads all agent definitions from <projectDir>/agents/*.md
func (r *Reader) readAgentDefs(projectDir string) []AgentDef {
	var agents []AgentDef

	matches, err := filepath.Glob(filepath.Join(projectDir, "agents", "*.md"))
	if err != nil || len(matches) == 0 {
		return agents
	}

	for _, path := range matches {
		fm := parseFrontmatter(path)
		if fm == nil {
			continue
		}

		name := fm["name"]
		if name == "" {
			name = strings.TrimSuffix(filepath.Base(path), ".md")
		}

		agents = append(agents, AgentDef{
			Name:        name,
			Description: fm["description"],
			Model:       fm["model"],
			Color:       fm["color"],
			Memory:      fm["memory"],
			Domain:      agentDomain(name),
			FilePath:    path,
		})
	}

	sort.Slice(agents, func(i, j int) bool {
		if agents[i].Domain != agents[j].Domain {
			return agents[i].Domain < agents[j].Domain
		}
		return agents[i].Name < agents[j].Name
	})

	return agents
}


// readTeamDefs reads all team definitions from <projectDir>/teams/*.team.md
func (r *Reader) readTeamDefs(projectDir string) []TeamDef {
	var teams []TeamDef

	matches, err := filepath.Glob(filepath.Join(projectDir, "teams", "*.team.md"))
	if err != nil || len(matches) == 0 {
		return teams
	}

	for _, path := range matches {
		td, ok := parseTeamDef(path)
		if !ok {
			continue
		}
		teams = append(teams, td)
	}

	sort.Slice(teams, func(i, j int) bool {
		return teams[i].Name < teams[j].Name
	})

	return teams
}

// parseTeamDef parses a single .team.md file into a TeamDef
func parseTeamDef(path string) (TeamDef, bool) {
	fm := parseFrontmatter(path)
	if fm == nil {
		return TeamDef{}, false
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return TeamDef{}, false
	}
	content := string(data)

	name := fm["name"]
	if name == "" {
		base := filepath.Base(path)
		name = strings.TrimSuffix(base, ".team.md")
	}

	workers, _ := strconv.Atoi(fm["workers"])

	td := TeamDef{
		Name:         name,
		Description:  fm["description"],
		Grid:         fm["grid"],
		Workers:      workers,
		Type:         fm["type"],
		ManagerModel: fm["manager_model"],
		WorkerModel:  fm["worker_model"],
		Panes:        parseMarkdownTable(content, "## Panes", parseTeamDefPane),
		Workflows:    parseMarkdownTable(content, "## Workflows", parseTeamDefWorkflow),
		Briefing:     parseSection(content, "## Team Briefing"),
		FilePath:     path,
	}

	return td, true
}

// parseSection extracts text after a heading until EOF or the next ## heading
func parseSection(content, heading string) string {
	idx := strings.Index(content, heading)
	if idx < 0 {
		return ""
	}
	body := content[idx+len(heading):]
	// Trim to next ## heading or EOF
	if next := strings.Index(body, "\n## "); next >= 0 {
		body = body[:next]
	}
	return strings.TrimSpace(body)
}

// parseMarkdownTable extracts rows from a markdown table under a heading.
// It calls rowParser for each data row (after header + separator).
func parseMarkdownTable[T any](content, heading string, rowParser func([]string) (T, bool)) []T {
	section := parseSection(content, heading)
	if section == "" {
		return nil
	}

	lines := strings.Split(section, "\n")
	var results []T
	dataStart := 0

	// Find the table: skip until we see a header row (starts with |), then skip separator
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "|") {
			// Next line should be separator (|---|...)
			if i+1 < len(lines) && strings.Contains(lines[i+1], "---") {
				dataStart = i + 2
				break
			}
		}
	}

	if dataStart == 0 {
		return nil
	}

	for i := dataStart; i < len(lines); i++ {
		trimmed := strings.TrimSpace(lines[i])
		if !strings.HasPrefix(trimmed, "|") {
			break
		}
		cols := splitTableRow(trimmed)
		if item, ok := rowParser(cols); ok {
			results = append(results, item)
		}
	}

	return results
}

// splitTableRow splits "| a | b | c |" into ["a", "b", "c"]
func splitTableRow(line string) []string {
	line = strings.Trim(line, "|")
	parts := strings.Split(line, "|")
	cols := make([]string, len(parts))
	for i, p := range parts {
		cols[i] = strings.TrimSpace(p)
	}
	return cols
}

func parseTeamDefPane(cols []string) (TeamDefPane, bool) {
	if len(cols) < 2 {
		return TeamDefPane{}, false
	}
	idx, _ := strconv.Atoi(cols[0])
	p := TeamDefPane{Index: idx, Role: cols[1]}
	if len(cols) > 2 {
		p.Agent = cols[2]
	}
	if len(cols) > 3 {
		p.Name = cols[3]
	}
	if len(cols) > 4 {
		p.Model = cols[4]
	}
	return p, true
}

func parseTeamDefWorkflow(cols []string) (TeamDefWorkflow, bool) {
	if len(cols) < 2 {
		return TeamDefWorkflow{}, false
	}
	w := TeamDefWorkflow{Trigger: cols[0], From: cols[1]}
	if len(cols) > 2 {
		w.To = cols[2]
	}
	if len(cols) > 3 {
		w.Subject = cols[3]
	}
	return w, true
}

// agentDomain computes the domain category from agent name prefix
func agentDomain(name string) string {
	if strings.HasPrefix(name, "doey-") {
		return "Doey Infrastructure"
	}
	if strings.HasPrefix(name, "seo-") {
		return "SEO"
	}
	if strings.HasPrefix(name, "visual-") {
		return "Visual QA"
	}
	return "Utility"
}

// parseFrontmatter reads YAML frontmatter (between --- markers) as key:value pairs
func parseFrontmatter(path string) map[string]string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	fm := make(map[string]string)

	// First line must be ---
	if !scanner.Scan() || strings.TrimSpace(scanner.Text()) != "---" {
		return nil
	}

	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "---" {
			return fm
		}
		idx := strings.IndexByte(line, ':')
		if idx < 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		val := strings.TrimSpace(line[idx+1:])
		// Strip surrounding quotes
		if len(val) >= 2 {
			if (val[0] == '"' && val[len(val)-1] == '"') ||
				(val[0] == '\'' && val[len(val)-1] == '\'') {
				val = val[1 : len(val)-1]
			}
		}
		fm[key] = val
	}

	return nil // never found closing ---
}

// buildTeamEntries merges team definitions with running state and user preferences.
// Handles multiple running instances of the same team definition correctly.
func buildTeamEntries(defs []TeamDef, teams map[int]TeamConfig, cfg TeamUserConfig) []TeamEntry {
	entries := make([]TeamEntry, 0, len(defs)+len(teams))

	// Build lookup: team def name -> list of running TeamConfigs
	// Use TeamDef field if set, fall back to TeamName
	runningByDef := make(map[string][]TeamConfig)
	for _, tc := range teams {
		defName := tc.TeamDef
		if defName == "" {
			defName = tc.TeamName
		}
		if defName != "" {
			runningByDef[defName] = append(runningByDef[defName], tc)
		}
	}

	// Track which def names we've handled
	handled := make(map[string]bool)

	// For each catalog def, create entries for running instances or one available entry
	for _, def := range defs {
		handled[def.Name] = true
		instances := runningByDef[def.Name]

		if len(instances) == 0 {
			// Not running — single available entry
			entries = append(entries, TeamEntry{
				Def:       def,
				WindowIdx: -1,
				Label:     def.Name,
				Starred:   cfg.IsStarred(def.Name),
				Startup:   cfg.IsStartup(def.Name),
			})
			continue
		}

		// One entry per running instance
		for _, tc := range instances {
			label := fmt.Sprintf("%s (W%d %s)", def.Name, tc.WindowIndex, tc.TeamType)
			entries = append(entries, TeamEntry{
				Def:       def,
				Running:   true,
				WindowIdx: tc.WindowIndex,
				Label:     label,
				Starred:   cfg.IsStarred(def.Name),
				Startup:   cfg.IsStartup(def.Name),
			})
		}
	}

	// Running teams that don't match any catalog def
	for defName, instances := range runningByDef {
		if handled[defName] {
			continue
		}
		for _, tc := range instances {
			syntheticDef := TeamDef{Name: defName}
			label := fmt.Sprintf("%s (W%d %s)", defName, tc.WindowIndex, tc.TeamType)
			entries = append(entries, TeamEntry{
				Def:       syntheticDef,
				Running:   true,
				WindowIdx: tc.WindowIndex,
				Label:     label,
			})
		}
	}

	// Sort: running first, then available; alpha within each group
	sort.SliceStable(entries, func(i, j int) bool {
		if entries[i].Running != entries[j].Running {
			return entries[i].Running
		}
		if entries[i].Starred != entries[j].Starred {
			return entries[i].Starred
		}
		return entries[i].Def.Name < entries[j].Def.Name
	})

	return entries
}

// parseMessages reads all IPC .msg files from the messages directory.
// Files are read-only — the TUI never deletes them (recipients handle consumption).
// Returns messages sorted by timestamp descending (newest first).
func (r *Reader) parseMessages() []Message {
	var msgs []Message

	matches, _ := filepath.Glob(filepath.Join(r.runtimeDir, "messages", "*.msg"))
	for _, path := range matches {
		base := filepath.Base(path)
		if strings.HasSuffix(base, ".msg.tmp") {
			continue
		}

		data, err := os.ReadFile(path)
		if err != nil {
			continue // file may have been consumed between glob and read
		}

		// Parse filename: <target_safe>_<unix_timestamp>_<pid>.msg
		// e.g. "doey_doey_0_1_1774609239_10826.msg"
		nameNoExt := strings.TrimSuffix(base, ".msg")
		parts := strings.Split(nameNoExt, "_")

		var targetSafe string
		var ts int64

		// Walk backwards to find timestamp (first all-digit segment from the end)
		// Format: <safe_name>_<timestamp>_<pid>
		if len(parts) >= 3 {
			// PID is last, timestamp is second-to-last
			pidIdx := len(parts) - 1
			tsIdx := len(parts) - 2
			ts, _ = strconv.ParseInt(parts[tsIdx], 10, 64)
			if ts == 0 {
				// Fallback: try last segment as timestamp
				ts, _ = strconv.ParseInt(parts[pidIdx], 10, 64)
				targetSafe = strings.Join(parts[:pidIdx], "_")
			} else {
				targetSafe = strings.Join(parts[:tsIdx], "_")
			}
		}

		content := string(data)
		from, subject, body := parseMessageContent(content)

		msgs = append(msgs, Message{
			ID:        nameNoExt,
			From:      from,
			To:        decodePaneSafe(targetSafe),
			ToRaw:     targetSafe,
			Subject:   subject,
			Body:      body,
			Timestamp: ts,
			Filename:  base,
		})
	}

	// Sort by timestamp descending (newest first)
	sort.Slice(msgs, func(i, j int) bool {
		return msgs[i].Timestamp > msgs[j].Timestamp
	})

	return msgs
}

// parseMessageContent extracts FROM, SUBJECT, and body from message content.
// Format: first line "FROM: ...", second line "SUBJECT: ...", rest is body.
func parseMessageContent(content string) (from, subject, body string) {
	lines := strings.SplitN(content, "\n", 3)

	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "FROM:") {
			from = strings.TrimSpace(strings.TrimPrefix(trimmed, "FROM:"))
		} else if strings.HasPrefix(trimmed, "SUBJECT:") {
			subject = strings.TrimSpace(strings.TrimPrefix(trimmed, "SUBJECT:"))
		} else {
			// Everything from this line onward is body
			body = strings.TrimSpace(strings.Join(lines[i:], "\n"))
			break
		}
	}

	if body == "" && len(lines) > 2 {
		body = strings.TrimSpace(lines[2])
	}

	return
}

// decodePaneSafe converts a pane safe name to a human-readable label.
// e.g. "doey_doey_0_1" → "Boss (0.1)", "doey_doey_0_2" → "SM (0.2)",
// "doey_doey_2_0" → "WM (2.0)", "doey_doey_2_3" → "W3 (2.3)"
func decodePaneSafe(safe string) string {
	parts := strings.Split(safe, "_")
	if len(parts) < 2 {
		return safe
	}

	// Extract last two parts as window.pane
	w := parts[len(parts)-2]
	p := parts[len(parts)-1]

	wInt, err1 := strconv.Atoi(w)
	pInt, err2 := strconv.Atoi(p)
	if err1 != nil || err2 != nil {
		return safe
	}

	paneID := fmt.Sprintf("%d.%d", wInt, pInt)

	// Map well-known panes to roles
	if wInt == 0 {
		switch pInt {
		case 0:
			return "Dashboard (" + paneID + ")"
		case 1:
			return "Boss (" + paneID + ")"
		case 2:
			return "SM (" + paneID + ")"
		default:
			return fmt.Sprintf("WD (%s)", paneID)
		}
	}

	// Team windows: pane 0 = manager, others = workers
	if pInt == 0 {
		return fmt.Sprintf("WM (%s)", paneID)
	}
	return fmt.Sprintf("W%d (%s)", pInt, paneID)
}

// parseDebugEntries collects debug events from all runtime sources.
// Returns entries sorted by timestamp descending (newest first), capped at 200.
func (r *Reader) parseDebugEntries() []DebugEntry {
	var entries []DebugEntry

	// 1. IPC messages — read .msg files WITHOUT deleting them
	matches, _ := filepath.Glob(filepath.Join(r.runtimeDir, "messages", "*.msg"))
	for _, path := range matches {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		content := string(data)

		from := parseHeaderLine(content, "FROM:")
		subject := parseHeaderLine(content, "SUBJECT:")
		summary := fmt.Sprintf("[%s] %s → %s", subject, from, filepath.Base(path))

		entries = append(entries, DebugEntry{
			Time:     info.ModTime(),
			Type:     "IPC_MESSAGE",
			Severity: "INFO",
			Source:   from,
			Summary:  summary,
			Detail:   content,
		})
	}

	// 2. Crash alerts — runtimeDir/status/crash_pane_*
	matches, _ = filepath.Glob(filepath.Join(r.runtimeDir, "status", "crash_pane_*"))
	for _, path := range matches {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		data, _ := os.ReadFile(path)

		pane := strings.TrimPrefix(filepath.Base(path), "crash_pane_")
		entries = append(entries, DebugEntry{
			Time:     info.ModTime(),
			Type:     "CRASH",
			Severity: "ERROR",
			Source:   pane,
			Summary:  fmt.Sprintf("Crash detected: pane %s", pane),
			Detail:   string(data),
		})
	}

	// 3. Issues — runtimeDir/issues/*.issue
	matches, _ = filepath.Glob(filepath.Join(r.runtimeDir, "issues", "*.issue"))
	for _, path := range matches {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		data, _ := os.ReadFile(path)
		content := string(data)

		severity := parseHeaderLine(content, "SEVERITY:")
		if severity == "" {
			severity = "WARN"
		}
		category := parseHeaderLine(content, "CATEGORY:")
		pane := parseHeaderLine(content, "PANE:")

		entries = append(entries, DebugEntry{
			Time:     info.ModTime(),
			Type:     "ISSUE",
			Severity: mapIssueSeverity(severity),
			Source:   pane,
			Summary:  fmt.Sprintf("[%s] %s", category, firstLine(content)),
			Detail:   content,
		})
	}

	// 4. Hook debug events — runtimeDir/debug/* (only if /doey-debug on)
	matches, _ = filepath.Glob(filepath.Join(r.runtimeDir, "debug", "*"))
	for _, path := range matches {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		data, _ := os.ReadFile(path)

		entries = append(entries, DebugEntry{
			Time:     info.ModTime(),
			Type:     "HOOK_EVENT",
			Severity: "DEBUG",
			Source:   filepath.Base(path),
			Summary:  firstLine(string(data)),
			Detail:   string(data),
		})
	}

	// 5. Status changes — derive from status files (latest change per pane)
	matches, _ = filepath.Glob(filepath.Join(r.runtimeDir, "status", "*.status"))
	for _, path := range matches {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		data, _ := os.ReadFile(path)
		content := string(data)

		status := parseHeaderLine(content, "STATUS:")
		pane := parseHeaderLine(content, "PANE:")
		task := parseHeaderLine(content, "TASK:")

		sev := "INFO"
		if status == "ERROR" {
			sev = "ERROR"
		}

		summary := fmt.Sprintf("%s → %s", pane, status)
		if task != "" {
			maxTask := 60
			if len(task) > maxTask {
				task = task[:maxTask] + "…"
			}
			summary += ": " + task
		}

		entries = append(entries, DebugEntry{
			Time:     info.ModTime(),
			Type:     "STATUS_CHANGE",
			Severity: sev,
			Source:   pane,
			Summary:  summary,
			Detail:   content,
		})
	}

	// Sort by time descending (newest first)
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Time.After(entries[j].Time)
	})

	// Cap at 200 entries
	if len(entries) > 200 {
		entries = entries[:200]
	}

	return entries
}

// parseHeaderLine extracts the value after a "KEY: value" line from content.
func parseHeaderLine(content, prefix string) string {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return ""
}

// firstLine returns the first non-empty line of text.
func firstLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			return line
		}
	}
	return ""
}

// mapIssueSeverity normalizes issue severity to our standard levels.
func mapIssueSeverity(s string) string {
	switch strings.ToUpper(s) {
	case "CRITICAL", "HIGH":
		return "ERROR"
	case "MEDIUM":
		return "WARN"
	default:
		return "INFO"
	}
}

// underscoreToPaneID converts "doey-proj_W_P" or "W_P" to a pane-style ID "W.P"
// Handles both full session names and simple W_P patterns.
func underscoreToPaneID(s string) string {
	// Try to find last two underscore-separated integers for W_P
	parts := strings.Split(s, "_")
	if len(parts) >= 2 {
		w := parts[len(parts)-2]
		p := parts[len(parts)-1]
		if _, err := strconv.Atoi(w); err == nil {
			if _, err := strconv.Atoi(p); err == nil {
				return w + "." + p
			}
		}
	}
	return s
}
