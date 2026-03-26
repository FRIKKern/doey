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
		crossReferenceAgentsAndTeams(snap.AgentDefs, snap.TeamDefs)
	}

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
			ID:     env["ID"],
			Title:  env["TITLE"],
			Status: env["STATUS"],
		}
		if t.ID == "" {
			t.ID = strings.TrimSuffix(filepath.Base(path), ".task")
		}
		if c := env["CREATED"]; c != "" {
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
		td := parseTeamDef(path)
		if td == nil {
			continue
		}
		td.FilePath = path
		teams = append(teams, *td)
	}

	sort.Slice(teams, func(i, j int) bool {
		return teams[i].Name < teams[j].Name
	})

	return teams
}

// crossReferenceAgentsAndTeams populates AgentDef.UsedByTeams
func crossReferenceAgentsAndTeams(agents []AgentDef, teams []TeamDef) {
	for i := range agents {
		var teamNames []string
		for _, td := range teams {
			for _, p := range td.Panes {
				if p.Agent == agents[i].Name {
					teamNames = append(teamNames, td.Name)
					break
				}
			}
		}
		agents[i].UsedByTeams = teamNames
	}
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

// parseTeamDef parses a team definition file (frontmatter + optional pane table)
func parseTeamDef(path string) *TeamDef {
	fm := parseFrontmatter(path)
	if fm == nil {
		return nil
	}

	td := &TeamDef{
		Name:         fm["name"],
		Description:  fm["description"],
		Type:         fm["type"],
		Grid:         fm["grid"],
		ManagerModel: fm["manager_model"],
		WorkerModel:  fm["worker_model"],
	}

	if td.Name == "" {
		base := filepath.Base(path)
		td.Name = strings.TrimSuffix(base, ".team.md")
	}

	if w := fm["workers"]; w != "" {
		td.Workers, _ = strconv.Atoi(w)
	}

	// Try parsing panes from YAML frontmatter first
	td.Panes = parsePanesFromFrontmatter(path)

	// If no panes in frontmatter, try markdown table in body
	if len(td.Panes) == 0 {
		td.Panes = parsePanesFromTable(path)
	}

	return td
}

// parsePanesFromFrontmatter extracts pane defs from YAML frontmatter panes: block
// Format:  N: { role: X, agent: Y, name: "Z" }
func parsePanesFromFrontmatter(path string) []TeamPaneDef {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	var panes []TeamPaneDef
	inFrontmatter := false
	inPanes := false

	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)

		if trimmed == "---" {
			if !inFrontmatter {
				inFrontmatter = true
				continue
			}
			break // end of frontmatter
		}

		if !inFrontmatter {
			continue
		}

		// Detect "panes:" key
		if strings.HasPrefix(trimmed, "panes:") {
			inPanes = true
			continue
		}

		if inPanes {
			// Lines like "  0: { role: brain, agent: doey-product-brain, name: "Brain" }"
			// Stop if we hit a non-indented line (new top-level key)
			if len(line) > 0 && line[0] != ' ' && line[0] != '\t' {
				inPanes = false
				continue
			}

			// Parse "N: { ... }"
			colonIdx := strings.IndexByte(trimmed, ':')
			if colonIdx < 0 {
				continue
			}
			indexStr := strings.TrimSpace(trimmed[:colonIdx])
			idx, err := strconv.Atoi(indexStr)
			if err != nil {
				continue
			}

			rest := strings.TrimSpace(trimmed[colonIdx+1:])
			// Strip { }
			rest = strings.TrimPrefix(rest, "{")
			rest = strings.TrimSuffix(rest, "}")
			rest = strings.TrimSpace(rest)

			pane := TeamPaneDef{Index: idx}
			for _, part := range strings.Split(rest, ",") {
				kv := strings.SplitN(strings.TrimSpace(part), ":", 2)
				if len(kv) != 2 {
					continue
				}
				k := strings.TrimSpace(kv[0])
				v := strings.TrimSpace(kv[1])
				// Strip quotes
				if len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"' {
					v = v[1 : len(v)-1]
				}
				switch k {
				case "role":
					pane.Role = v
				case "agent":
					pane.Agent = v
				case "name":
					pane.Name = v
				case "model":
					pane.Model = v
				}
			}
			panes = append(panes, pane)
		}
	}

	return panes
}

// parsePanesFromTable extracts pane defs from a markdown table after "## Panes"
// Format: | Pane | Role | Agent | Name | Model |
func parsePanesFromTable(path string) []TeamPaneDef {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	var panes []TeamPaneDef
	inPanesSection := false
	headerParsed := false

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		if line == "## Panes" {
			inPanesSection = true
			continue
		}

		// Stop at next heading
		if inPanesSection && strings.HasPrefix(line, "## ") {
			break
		}

		if !inPanesSection {
			continue
		}

		// Skip non-table lines
		if !strings.HasPrefix(line, "|") {
			continue
		}

		// Skip header row
		if !headerParsed {
			headerParsed = true
			continue
		}

		// Skip separator row (|------|...)
		if strings.Contains(line, "---") {
			continue
		}

		// Parse: | 0 | manager | doey-manager | Manager | opus |
		cells := splitTableRow(line)
		if len(cells) < 5 {
			continue
		}

		idx, err := strconv.Atoi(strings.TrimSpace(cells[0]))
		if err != nil {
			continue
		}

		agent := strings.TrimSpace(cells[2])
		if agent == "-" {
			agent = ""
		}

		panes = append(panes, TeamPaneDef{
			Index: idx,
			Role:  strings.TrimSpace(cells[1]),
			Agent: agent,
			Name:  strings.TrimSpace(cells[3]),
			Model: strings.TrimSpace(cells[4]),
		})
	}

	return panes
}

// splitTableRow splits a markdown table row "| a | b | c |" into ["a", "b", "c"]
func splitTableRow(line string) []string {
	line = strings.Trim(line, "|")
	parts := strings.Split(line, "|")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
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
