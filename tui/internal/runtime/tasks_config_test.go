package runtime

import (
	"os"
	"path/filepath"
	"testing"
)

// TestTaskStoreLogsAppendOnly verifies that log entries added to a task
// survive a ReadTaskStore/WriteTaskStore round trip, even when the SQLite
// store is populated and takes precedence in ReadTaskStore.
//
// Regression for task 571: the SQL path in ReadTaskStore used to return
// tasks with empty Logs/Reports/TaskAttachments slices, and the subsequent
// WriteTaskStore would overwrite the JSON file, silently dropping history.
func TestTaskStoreLogsAppendOnly(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".doey", "tasks"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	prev := configProjectDir
	SetProjectDir(dir)
	t.Cleanup(func() { configProjectDir = prev })

	// Seed: task with a single log entry.
	first := PersistentTask{
		ID:     "1",
		Title:  "append-only task",
		Status: "active",
		Logs:   []PersistentTaskLog{{Timestamp: 1000, Entry: "first"}},
	}
	ts := TaskStore{Tasks: []PersistentTask{first}, NextID: 2}
	if err := WriteTaskStore(ts); err != nil {
		t.Fatalf("WriteTaskStore seed: %v", err)
	}

	// First reload — must preserve the seeded log entry.
	ts2, err := ReadTaskStore()
	if err != nil {
		t.Fatalf("ReadTaskStore #1: %v", err)
	}
	got := ts2.FindTask("1")
	if got == nil {
		t.Fatalf("task 1 missing after first reload")
	}
	if len(got.Logs) != 1 || got.Logs[0].Entry != "first" {
		t.Fatalf("first reload lost log history: got %+v", got.Logs)
	}

	// Append a second log entry and persist.
	got.Logs = append(got.Logs, PersistentTaskLog{Timestamp: 2000, Entry: "second"})
	if err := WriteTaskStore(ts2); err != nil {
		t.Fatalf("WriteTaskStore append: %v", err)
	}

	// Second reload — must see BOTH entries.
	ts3, err := ReadTaskStore()
	if err != nil {
		t.Fatalf("ReadTaskStore #2: %v", err)
	}
	got3 := ts3.FindTask("1")
	if got3 == nil {
		t.Fatalf("task 1 missing after second reload")
	}
	if len(got3.Logs) != 2 {
		t.Fatalf("append-only violated: got %d log entries, want 2: %+v", len(got3.Logs), got3.Logs)
	}
	entries := map[string]bool{}
	for _, l := range got3.Logs {
		entries[l.Entry] = true
	}
	if !entries["first"] || !entries["second"] {
		t.Errorf("missing log entries after reload: %+v", got3.Logs)
	}
}

// TestTaskStoreReportsAppendOnly verifies that worker reports survive a
// round trip through Read/Write TaskStore and are not replaced when a
// runtime task is merged in with a different (or empty) Reports slice.
func TestTaskStoreReportsAppendOnly(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".doey", "tasks"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	prev := configProjectDir
	SetProjectDir(dir)
	t.Cleanup(func() { configProjectDir = prev })

	seed := PersistentTask{
		ID:     "1",
		Title:  "reports task",
		Status: "active",
		Reports: []PersistentReport{
			{Index: 1, Author: "W1.1", Type: "progress", Title: "r1", Body: "b1", Created: 1000},
		},
	}
	if err := WriteTaskStore(TaskStore{Tasks: []PersistentTask{seed}, NextID: 2}); err != nil {
		t.Fatalf("WriteTaskStore seed: %v", err)
	}

	// Reload and append a second report.
	ts, err := ReadTaskStore()
	if err != nil {
		t.Fatalf("ReadTaskStore: %v", err)
	}
	got := ts.FindTask("1")
	if got == nil {
		t.Fatalf("task 1 missing after reload")
	}
	if len(got.Reports) != 1 {
		t.Fatalf("first report lost: %+v", got.Reports)
	}
	got.Reports = append(got.Reports, PersistentReport{
		Index: 2, Author: "W1.2", Type: "completion", Title: "r2", Body: "b2", Created: 2000,
	})
	if err := WriteTaskStore(ts); err != nil {
		t.Fatalf("WriteTaskStore append: %v", err)
	}

	// Final reload — both reports must be present.
	ts2, err := ReadTaskStore()
	if err != nil {
		t.Fatalf("ReadTaskStore final: %v", err)
	}
	got2 := ts2.FindTask("1")
	if got2 == nil {
		t.Fatalf("task 1 missing after final reload")
	}
	if len(got2.Reports) != 2 {
		t.Fatalf("report history dropped: got %d reports, want 2: %+v", len(got2.Reports), got2.Reports)
	}
}

// TestMergeRuntimeIntoPersistentReportsAdditive verifies that feeding a
// runtime task with fewer reports than the persistent task does NOT drop
// the extra persistent reports.
func TestMergeRuntimeIntoPersistentReportsAdditive(t *testing.T) {
	pt := &PersistentTask{
		ID: "7",
		Reports: []PersistentReport{
			{Index: 1, Author: "W1.1", Created: 1000, Title: "old"},
			{Index: 2, Author: "W1.2", Created: 2000, Title: "older"},
		},
	}
	rt := Task{
		ID: "7",
		Reports: []Report{
			// Runtime only sees the newest — the merge must not erase the
			// persisted history.
			{Index: 3, Author: "W1.3", Created: 3000, Title: "new"},
		},
	}
	mergeRuntimeIntoPersistent(pt, rt)
	if len(pt.Reports) != 3 {
		t.Fatalf("expected additive merge to produce 3 reports, got %d: %+v", len(pt.Reports), pt.Reports)
	}
}
