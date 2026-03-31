package runtime

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestParseSessionConfig(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "session.env"), `# Doey session config
SESSION_NAME="doey-myproject"
PROJECT_NAME="myproject"
PROJECT_DIR="/Users/dev/projects/myproject"
TEAM_WINDOWS=1,2,3
`)

	r := NewReader(dir)
	sc, err := r.parseSessionConfig()
	if err != nil {
		t.Fatalf("parseSessionConfig: %v", err)
	}

	if sc.SessionName != "doey-myproject" {
		t.Errorf("SessionName = %q, want %q", sc.SessionName, "doey-myproject")
	}
	if sc.ProjectName != "myproject" {
		t.Errorf("ProjectName = %q, want %q", sc.ProjectName, "myproject")
	}
	if sc.ProjectDir != "/Users/dev/projects/myproject" {
		t.Errorf("ProjectDir = %q, want %q", sc.ProjectDir, "/Users/dev/projects/myproject")
	}
	if len(sc.TeamWindows) != 3 || sc.TeamWindows[0] != 1 || sc.TeamWindows[1] != 2 || sc.TeamWindows[2] != 3 {
		t.Errorf("TeamWindows = %v, want [1 2 3]", sc.TeamWindows)
	}
	if sc.RuntimeDir != dir {
		t.Errorf("RuntimeDir = %q, want %q", sc.RuntimeDir, dir)
	}
}

func TestParseTeamConfig(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "team_1.env"), `GRID="manager-left"
MANAGER_PANE="doey-myproject:1.0"
WATCHDOG_PANE="doey-myproject:0.2"
WORKER_PANES=1,2,3
WORKER_COUNT=3
TEAM_NAME='charm-ui'
TEAM_TYPE="premade"
WORKTREE_DIR=""
WORKTREE_BRANCH=""
`)

	r := NewReader(dir)
	tc, err := r.parseTeamConfig(1)
	if err != nil {
		t.Fatalf("parseTeamConfig: %v", err)
	}

	if tc.WindowIndex != 1 {
		t.Errorf("WindowIndex = %d, want 1", tc.WindowIndex)
	}
	if tc.Grid != "manager-left" {
		t.Errorf("Grid = %q, want %q", tc.Grid, "manager-left")
	}
	if tc.ManagerPane != "doey-myproject:1.0" {
		t.Errorf("ManagerPane = %q, want %q", tc.ManagerPane, "doey-myproject:1.0")
	}
	if tc.TeamName != "charm-ui" {
		t.Errorf("TeamName = %q, want %q", tc.TeamName, "charm-ui")
	}
	if tc.TeamType != "premade" {
		t.Errorf("TeamType = %q, want %q", tc.TeamType, "premade")
	}
	if tc.WorkerCount != 3 {
		t.Errorf("WorkerCount = %d, want 3", tc.WorkerCount)
	}
	if len(tc.WorkerPanes) != 3 {
		t.Errorf("WorkerPanes = %v, want [1 2 3]", tc.WorkerPanes)
	}
}

func TestParsePaneStatuses(t *testing.T) {
	dir := t.TempDir()
	statusDir := filepath.Join(dir, "status")

	writeFile(t, filepath.Join(statusDir, "1_0.status"), `STATUS: BUSY
TASK: implementing charm TUI
UPDATED: 2026-03-26T10:30:00
`)
	writeFile(t, filepath.Join(statusDir, "1_2.status"), `STATUS: READY
TASK:
UPDATED: 2026-03-26T10:28:00
`)

	r := NewReader(dir)
	statuses := r.parsePaneStatuses()

	if len(statuses) != 2 {
		t.Fatalf("got %d statuses, want 2", len(statuses))
	}

	ps, ok := statuses["1.0"]
	if !ok {
		t.Fatal("missing status for pane 1.0")
	}
	if ps.Status != "BUSY" {
		t.Errorf("1.0 Status = %q, want BUSY", ps.Status)
	}
	if ps.Task != "implementing charm TUI" {
		t.Errorf("1.0 Task = %q, want %q", ps.Task, "implementing charm TUI")
	}

	ps2, ok := statuses["1.2"]
	if !ok {
		t.Fatal("missing status for pane 1.2")
	}
	if ps2.Status != "READY" {
		t.Errorf("1.2 Status = %q, want READY", ps2.Status)
	}
}

func TestParseTasks(t *testing.T) {
	dir := t.TempDir()
	taskDir := filepath.Join(dir, "tasks")

	writeFile(t, filepath.Join(taskDir, "001.task"), `TASK_ID=001
TASK_TITLE="Build charm TUI dashboard"
TASK_STATUS=active
TASK_CREATED=1711443600
`)
	writeFile(t, filepath.Join(taskDir, "002.task"), `TASK_ID=002
TASK_TITLE='Fix pane border rendering'
TASK_STATUS=done
TASK_CREATED=1711440000
`)

	r := NewReader(dir)
	tasks := r.ParseTasks()

	if len(tasks) != 2 {
		t.Fatalf("got %d tasks, want 2", len(tasks))
	}

	// Tasks may come in any order from Glob
	taskMap := make(map[string]Task)
	for _, tk := range tasks {
		taskMap[tk.ID] = tk
	}

	t1, ok := taskMap["001"]
	if !ok {
		t.Fatal("missing task 001")
	}
	if t1.Title != "Build charm TUI dashboard" {
		t.Errorf("task 001 Title = %q, want %q", t1.Title, "Build charm TUI dashboard")
	}
	if t1.Status != "active" {
		t.Errorf("task 001 Status = %q, want active", t1.Status)
	}
	if t1.Created != 1711443600 {
		t.Errorf("task 001 Created = %d, want 1711443600", t1.Created)
	}

	t2, ok := taskMap["002"]
	if !ok {
		t.Fatal("missing task 002")
	}
	if t2.Status != "done" {
		t.Errorf("task 002 Status = %q, want done", t2.Status)
	}
}

func TestReadSnapshotMissingDir(t *testing.T) {
	r := NewReader("/tmp/doey-test-nonexistent-dir-12345")
	snap, err := r.ReadSnapshot()

	// Should return error for missing session.env but not panic
	if err == nil {
		t.Fatal("expected error for missing runtime dir, got nil")
	}

	// Snapshot maps should be initialized (not nil)
	if snap.Teams == nil {
		t.Error("Teams map is nil, should be initialized")
	}
	if snap.Panes == nil {
		t.Error("Panes map is nil, should be initialized")
	}
}

func TestReadSnapshotRealistic(t *testing.T) {
	dir := t.TempDir()

	// session.env
	writeFile(t, filepath.Join(dir, "session.env"), `SESSION_NAME="doey-doey"
PROJECT_NAME="doey"
PROJECT_DIR="/Users/pelle/Documents/github/doey"
TEAM_WINDOWS=1,2
`)

	// team configs
	writeFile(t, filepath.Join(dir, "team_1.env"), `GRID="manager-left"
MANAGER_PANE="doey-doey:1.0"
WATCHDOG_PANE="doey-doey:0.2"
WORKER_PANES=1,2,3
WORKER_COUNT=3
TEAM_NAME="charm-ui"
TEAM_TYPE="premade"
`)
	writeFile(t, filepath.Join(dir, "team_2.env"), `GRID="even-horizontal"
MANAGER_PANE="doey-doey:2.0"
WATCHDOG_PANE="doey-doey:0.3"
WORKER_PANES=1,2
WORKER_COUNT=2
TEAM_NAME="deploy"
TEAM_TYPE="local"
`)

	// statuses
	writeFile(t, filepath.Join(dir, "status", "1_1.status"), `STATUS: BUSY
TASK: writing tests
UPDATED: 2026-03-26T11:00:00
`)
	writeFile(t, filepath.Join(dir, "status", "2_0.status"), `STATUS: READY
TASK:
UPDATED: 2026-03-26T10:55:00
`)

	// tasks
	writeFile(t, filepath.Join(dir, "tasks", "t1.task"), `TASK_ID=t1
TASK_TITLE="Build TUI"
TASK_STATUS=active
TASK_CREATED=1711443600
`)

	// results
	result := PaneResult{
		Pane:         "1.1",
		Title:        "Test results",
		Status:       "success",
		Timestamp:    1711443700,
		FilesChanged: []string{"reader_test.go"},
		ToolCalls:    5,
	}
	resultJSON, _ := json.Marshal(result)
	writeFile(t, filepath.Join(dir, "results", "pane_1_1.json"), string(resultJSON))

	// context percentages (live in status/ subdir)
	writeFile(t, filepath.Join(dir, "status", "context_pct_1_1"), "42")
	writeFile(t, filepath.Join(dir, "status", "context_pct_2_0"), "15")

	r := NewReader(dir)
	snap, err := r.ReadSnapshot()
	if err != nil {
		t.Fatalf("ReadSnapshot: %v", err)
	}

	// Session
	if snap.Session.ProjectName != "doey" {
		t.Errorf("ProjectName = %q, want doey", snap.Session.ProjectName)
	}
	if len(snap.Session.TeamWindows) != 2 {
		t.Errorf("TeamWindows = %v, want [1 2]", snap.Session.TeamWindows)
	}

	// Teams
	if len(snap.Teams) != 2 {
		t.Errorf("got %d teams, want 2", len(snap.Teams))
	}
	if snap.Teams[1].TeamName != "charm-ui" {
		t.Errorf("team 1 name = %q, want charm-ui", snap.Teams[1].TeamName)
	}
	if snap.Teams[2].TeamName != "deploy" {
		t.Errorf("team 2 name = %q, want deploy", snap.Teams[2].TeamName)
	}

	// Panes
	if len(snap.Panes) != 2 {
		t.Errorf("got %d pane statuses, want 2", len(snap.Panes))
	}
	if snap.Panes["1.1"].Status != "BUSY" {
		t.Errorf("pane 1.1 status = %q, want BUSY", snap.Panes["1.1"].Status)
	}

	// Tasks
	if len(snap.Tasks) != 1 {
		t.Errorf("got %d tasks, want 1", len(snap.Tasks))
	}

	// Results
	if len(snap.Results) != 1 {
		t.Errorf("got %d results, want 1", len(snap.Results))
	}
	if snap.Results["1.1"].ToolCalls != 5 {
		t.Errorf("result tool calls = %d, want 5", snap.Results["1.1"].ToolCalls)
	}

	// Context percentages
	if snap.ContextPct["1.1"] != 42 {
		t.Errorf("context pct 1.1 = %d, want 42", snap.ContextPct["1.1"])
	}
	if snap.ContextPct["2.0"] != 15 {
		t.Errorf("context pct 2.0 = %d, want 15", snap.ContextPct["2.0"])
	}

	// Uptime should be > 0 since we just created session.env
	if snap.Uptime <= 0 {
		t.Error("Uptime should be > 0")
	}
}
