package runtime

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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
