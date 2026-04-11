package runtime

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/doey-cli/doey/tui/internal/store"
)

// TestStoreReaderTasksAttachments covers bug #479: SQLite-backed projects must
// populate Task.TaskAttachments through storeReader.readTasks, matching the
// file-based ParseTasks path. Without the fix, t.TaskAttachments is nil and
// the TUI renders no ATTACHMENTS section.
func TestStoreReaderTasksAttachments(t *testing.T) {
	dir := t.TempDir()
	projectDir := filepath.Join(dir, "proj")
	runtimeDir := filepath.Join(dir, "runtime")
	if err := os.MkdirAll(filepath.Join(projectDir, ".doey"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatal(err)
	}

	writeFile(t, filepath.Join(runtimeDir, "session.env"),
		`SESSION_NAME="doey-test"
PROJECT_NAME="test"
PROJECT_DIR="`+projectDir+`"
TEAM_WINDOWS=1
`)

	dbPath := filepath.Join(projectDir, ".doey", "doey.db")
	s, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	task := &store.Task{
		ID:          479,
		Title:       "attachments-fixture",
		Status:      "in_progress",
		Type:        "task",
		Description: "seed task for bug 479 repro",
	}
	if _, err := s.CreateTask(task); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}
	s.Close()

	// Seed two attachment files under both legitimate directory patterns.
	attachDir := filepath.Join(projectDir, ".doey", "tasks", "479", "attachments")
	if err := os.MkdirAll(attachDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(attachDir, "1700000000_completion_2_1.md"),
		`---
type: completion
title: Worker 2.1 completion report
author: d-t2-w1
timestamp: 1700000000
task_id: 479
---
# Completion

Bug fix verified.
`)
	writeFile(t, filepath.Join(attachDir, "1700000100_note_boss.md"),
		`---
type: note
title: Boss note
author: boss
timestamp: 1700000100
task_id: 479
---
Looks good to ship.
`)

	r := NewReader(runtimeDir)
	defer r.Close()
	snap, err := r.ReadSnapshot()
	if err != nil {
		t.Fatalf("ReadSnapshot: %v", err)
	}

	var target *Task
	for i := range snap.Tasks {
		if snap.Tasks[i].ID == "479" {
			target = &snap.Tasks[i]
			break
		}
	}
	if target == nil {
		t.Fatalf("task 479 not present in snapshot (got %d tasks)", len(snap.Tasks))
	}

	if len(target.TaskAttachments) != 2 {
		t.Fatalf("TaskAttachments len = %d, want 2 (slice=%+v)",
			len(target.TaskAttachments), target.TaskAttachments)
	}

	var sawCompletion, sawNote bool
	for _, a := range target.TaskAttachments {
		switch a.Type {
		case "completion":
			sawCompletion = true
			if a.Author != "d-t2-w1" {
				t.Errorf("completion author = %q, want d-t2-w1", a.Author)
			}
			if a.Title != "Worker 2.1 completion report" {
				t.Errorf("completion title = %q", a.Title)
			}
		case "note":
			sawNote = true
			if a.Author != "boss" {
				t.Errorf("note author = %q, want boss", a.Author)
			}
		default:
			t.Errorf("unexpected attachment type %q", a.Type)
		}
	}
	if !sawCompletion {
		t.Error("did not see completion attachment")
	}
	if !sawNote {
		t.Error("did not see note attachment")
	}
}
