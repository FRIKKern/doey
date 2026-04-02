package ctl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// --- IPC tests ---

func TestWriteReadMsg(t *testing.T) {
	dir := t.TempDir()
	err := WriteMsg(dir, "test_pane", "boss", "task", "do the thing")
	if err != nil {
		t.Fatalf("WriteMsg: %v", err)
	}

	msgs, err := ReadMsgs(dir, "test_pane")
	if err != nil {
		t.Fatalf("ReadMsgs: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 msg, got %d", len(msgs))
	}
	m := msgs[0]
	if m.From != "boss" {
		t.Errorf("From = %q, want %q", m.From, "boss")
	}
	if m.Subject != "task" {
		t.Errorf("Subject = %q, want %q", m.Subject, "task")
	}
	if m.Body != "do the thing" {
		t.Errorf("Body = %q, want %q", m.Body, "do the thing")
	}
	if m.Timestamp == 0 {
		t.Error("Timestamp should be non-zero")
	}
	if !strings.HasSuffix(m.Filename, MsgExt) {
		t.Errorf("Filename %q should end with %s", m.Filename, MsgExt)
	}
}

func TestCleanupMsgs(t *testing.T) {
	dir := t.TempDir()
	if err := WriteMsg(dir, "p1", "a", "s1", "b1"); err != nil {
		t.Fatal(err)
	}
	// Small sleep so filenames differ (nanosecond timestamp should suffice, but be safe).
	time.Sleep(time.Millisecond)
	if err := WriteMsg(dir, "p1", "a", "s2", "b2"); err != nil {
		t.Fatal(err)
	}

	msgs, _ := ReadMsgs(dir, "p1")
	if len(msgs) != 2 {
		t.Fatalf("expected 2 msgs before cleanup, got %d", len(msgs))
	}

	if err := CleanupMsgs(dir, "p1"); err != nil {
		t.Fatalf("CleanupMsgs: %v", err)
	}

	msgs, _ = ReadMsgs(dir, "p1")
	if len(msgs) != 0 {
		t.Errorf("expected 0 msgs after cleanup, got %d", len(msgs))
	}
}

func TestFireTrigger(t *testing.T) {
	dir := t.TempDir()
	if err := FireTrigger(dir, "worker_1"); err != nil {
		t.Fatalf("FireTrigger: %v", err)
	}

	path := filepath.Join(dir, TriggersSubdir, "worker_1"+TriggerExt)
	if _, err := os.Stat(path); err != nil {
		t.Errorf("trigger file should exist at %s: %v", path, err)
	}
}

// --- Status tests ---

func TestWriteReadStatus(t *testing.T) {
	dir := t.TempDir()
	err := WriteStatus(dir, "sess_0_1", "W0.1", StatusBusy, "fixing bug")
	if err != nil {
		t.Fatalf("WriteStatus: %v", err)
	}

	entry, err := ReadStatus(dir, "sess_0_1")
	if err != nil {
		t.Fatalf("ReadStatus: %v", err)
	}
	if entry.Pane != "W0.1" {
		t.Errorf("Pane = %q, want %q", entry.Pane, "W0.1")
	}
	if entry.Status != StatusBusy {
		t.Errorf("Status = %q, want %q", entry.Status, StatusBusy)
	}
	if entry.Task != "fixing bug" {
		t.Errorf("Task = %q, want %q", entry.Task, "fixing bug")
	}
	if entry.Updated == "" {
		t.Error("Updated should be non-empty")
	}
	if entry.UpdatedTime.IsZero() {
		t.Error("UpdatedTime should be non-zero")
	}
}

func TestIsAlive(t *testing.T) {
	dir := t.TempDir()

	// Fresh write — should be alive with 5s threshold.
	if err := WriteStatus(dir, "alive_pane", "W1.0", StatusReady, ""); err != nil {
		t.Fatal(err)
	}
	alive, err := IsAlive(dir, "alive_pane", 5*time.Second)
	if err != nil {
		t.Fatalf("IsAlive: %v", err)
	}
	if !alive {
		t.Error("expected alive=true for fresh status")
	}

	// Write a stale status by hand (2 hours ago).
	staleTime := time.Now().Add(-2 * time.Hour).Format(timeFormat)
	statusDir := filepath.Join(dir, StatusSubdir)
	content := "PANE=W1.1\nUPDATED=" + staleTime + "\nSTATUS=BUSY\nTASK=old\n"
	os.WriteFile(filepath.Join(statusDir, "stale_pane"+StatusExt), []byte(content), 0o644)

	alive, err = IsAlive(dir, "stale_pane", 1*time.Second)
	if err != nil {
		t.Fatalf("IsAlive stale: %v", err)
	}
	if alive {
		t.Error("expected alive=false for stale status")
	}
}

func TestListStatuses(t *testing.T) {
	dir := t.TempDir()
	// ListStatuses globs *_<window>_*.status — names must match that pattern.
	if err := WriteStatus(dir, "sess_1_0", "W1.0", StatusBusy, "task-a"); err != nil {
		t.Fatal(err)
	}
	if err := WriteStatus(dir, "sess_1_1", "W1.1", StatusReady, "task-b"); err != nil {
		t.Fatal(err)
	}
	// Different window — should not appear.
	if err := WriteStatus(dir, "sess_2_0", "W2.0", StatusFinished, "task-c"); err != nil {
		t.Fatal(err)
	}

	entries, err := ListStatuses(dir, 1)
	if err != nil {
		t.Fatalf("ListStatuses: %v", err)
	}
	if len(entries) != 2 {
		t.Errorf("expected 2 entries for window 1, got %d", len(entries))
	}
}

// --- Task tests ---

func setupTaskDir(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	tasksDir := filepath.Join(tmp, ".doey", "tasks")
	if err := os.MkdirAll(tasksDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tasksDir, ".next_id"), []byte("1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return tmp
}

func TestCreateReadTask(t *testing.T) {
	proj := setupTaskDir(t)
	id, err := CreateTask(proj, "Build widget", "feature", "boss", "Build a new widget")
	if err != nil {
		t.Fatalf("CreateTask: %v", err)
	}
	if id != "1" {
		t.Errorf("expected id=1, got %s", id)
	}

	task, err := ReadTask(proj, id)
	if err != nil {
		t.Fatalf("ReadTask: %v", err)
	}
	if task.Title != "Build widget" {
		t.Errorf("Title = %q, want %q", task.Title, "Build widget")
	}
	if task.Status != TaskStatusDraft {
		t.Errorf("Status = %q, want %q", task.Status, TaskStatusDraft)
	}
	if task.Type != "feature" {
		t.Errorf("Type = %q, want %q", task.Type, "feature")
	}
}

func TestUpdateTaskField(t *testing.T) {
	proj := setupTaskDir(t)
	id, err := CreateTask(proj, "Old title", "bug", "worker", "desc")
	if err != nil {
		t.Fatal(err)
	}

	if err := UpdateTaskField(proj, id, FieldTaskTitle, "New title"); err != nil {
		t.Fatalf("UpdateTaskField: %v", err)
	}

	task, err := ReadTask(proj, id)
	if err != nil {
		t.Fatal(err)
	}
	if task.Title != "New title" {
		t.Errorf("Title = %q, want %q", task.Title, "New title")
	}
}

func TestAddSubtask(t *testing.T) {
	proj := setupTaskDir(t)
	id, _ := CreateTask(proj, "Parent", "feature", "boss", "parent task")

	idx1, err := AddSubtask(proj, id, "First subtask")
	if err != nil {
		t.Fatalf("AddSubtask 1: %v", err)
	}
	idx2, err := AddSubtask(proj, id, "Second subtask")
	if err != nil {
		t.Fatalf("AddSubtask 2: %v", err)
	}
	if idx1 >= idx2 {
		t.Errorf("expected idx1 < idx2, got %d >= %d", idx1, idx2)
	}

	task, _ := ReadTask(proj, id)
	if len(task.Subtasks) != 2 {
		t.Fatalf("expected 2 subtasks, got %d", len(task.Subtasks))
	}
	if task.Subtasks[0].Description != "First subtask" {
		t.Errorf("subtask[0] desc = %q", task.Subtasks[0].Description)
	}
	if task.Subtasks[1].Description != "Second subtask" {
		t.Errorf("subtask[1] desc = %q", task.Subtasks[1].Description)
	}
}

func TestUpdateSubtaskStatus(t *testing.T) {
	proj := setupTaskDir(t)
	id, _ := CreateTask(proj, "Task", "feature", "boss", "d")
	idx, _ := AddSubtask(proj, id, "Do something")

	if err := UpdateSubtaskStatus(proj, id, idx, "done"); err != nil {
		t.Fatalf("UpdateSubtaskStatus: %v", err)
	}

	task, _ := ReadTask(proj, id)
	if len(task.Subtasks) != 1 {
		t.Fatalf("expected 1 subtask, got %d", len(task.Subtasks))
	}
	if task.Subtasks[0].Status != "done" {
		t.Errorf("subtask status = %q, want %q", task.Subtasks[0].Status, "done")
	}
}

func TestAddDecision(t *testing.T) {
	proj := setupTaskDir(t)
	id, _ := CreateTask(proj, "Task", "feature", "boss", "d")

	if err := AddDecision(proj, id, "Chose approach A"); err != nil {
		t.Fatalf("AddDecision: %v", err)
	}

	task, _ := ReadTask(proj, id)
	if !strings.Contains(task.DecisionLog, "Chose approach A") {
		t.Errorf("DecisionLog = %q, should contain %q", task.DecisionLog, "Chose approach A")
	}
}

func TestListTasks(t *testing.T) {
	proj := setupTaskDir(t)
	CreateTask(proj, "Task A", "feature", "boss", "a")
	CreateTask(proj, "Task B", "bug", "worker", "b")

	tasks, err := ListTasks(proj)
	if err != nil {
		t.Fatalf("ListTasks: %v", err)
	}
	if len(tasks) < 2 {
		t.Errorf("expected >= 2 tasks, got %d", len(tasks))
	}
}
