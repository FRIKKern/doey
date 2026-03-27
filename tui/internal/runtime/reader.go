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
	snap.Results = r.parseResults()
	snap.ContextPct = r.parseContextPcts()
	snap.Uptime = r.calculateUptime()

	if session.ProjectDir != "" {
		snap.AgentDefs = r.readAgentDefs(session.ProjectDir)
		snap.TeamDefs = r.readTeamDefs(session.ProjectDir)
	}

	snap.TeamUserCfg, _ = ReadTeamUserConfig()
	snap.TeamEntries = buildTeamEntries(snap.TeamDefs, snap.Teams, snap.TeamUserCfg)

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
		WatchdogPane:   env["WATCHDOG_PANE"],
		TeamName:       env["TEAM_NAME"],
		TeamType:       env["TEAM_TYPE"],
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
			ID:     env["TASK_ID"],
			Title:  env["TASK_TITLE"],
			Status: env["TASK_STATUS"],
		}
		if t.ID == "" {
			t.ID = strings.TrimSuffix(filepath.Base(path), ".task")
		}
		if c := env["TASK_CREATED"]; c != "" {
			t.Created, _ = strconv.ParseInt(c, 10, 64)
		}
		tasks = append(tasks, t)
	}

	return tasks
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
func buildTeamEntries(defs []TeamDef, teams map[int]TeamConfig, cfg TeamUserConfig) []TeamEntry {
	entries := make([]TeamEntry, 0, len(defs))

	// Build lookup: team name -> running TeamConfig
	running := make(map[string]TeamConfig)
	for _, tc := range teams {
		if tc.TeamName != "" {
			running[tc.TeamName] = tc
		}
	}

	for _, def := range defs {
		entry := TeamEntry{
			Def:       def,
			WindowIdx: -1,
			Starred:   cfg.IsStarred(def.Name),
			Startup:   cfg.IsStartup(def.Name),
		}
		if tc, ok := running[def.Name]; ok {
			entry.Running = true
			entry.WindowIdx = tc.WindowIndex
		}
		entries = append(entries, entry)
	}

	sort.SliceStable(entries, func(i, j int) bool {
		if entries[i].Starred != entries[j].Starred {
			return entries[i].Starred
		}
		return entries[i].Def.Name < entries[j].Def.Name
	})

	return entries
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
