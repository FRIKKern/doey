package store

import (
	"database/sql"
	"path/filepath"
	"testing"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	s, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestTaskCRUD(t *testing.T) {
	s := testStore(t)

	// Create
	task := &Task{Title: "build widget", Status: "active", Type: "feature", Description: "do the thing"}
	id, err := s.CreateTask(task)
	if err != nil {
		t.Fatal(err)
	}
	if id == 0 {
		t.Fatal("expected non-zero ID")
	}

	// Get
	got, err := s.GetTask(id)
	if err != nil {
		t.Fatal(err)
	}
	if got.Title != "build widget" {
		t.Errorf("title = %q, want %q", got.Title, "build widget")
	}
	if got.Status != "active" {
		t.Errorf("status = %q, want %q", got.Status, "active")
	}
	if got.Type != "feature" {
		t.Errorf("type = %q, want %q", got.Type, "feature")
	}
	if got.CreatedAt == 0 {
		t.Error("created_at should be set")
	}

	// Create a second task with different status
	_, err = s.CreateTask(&Task{Title: "fix bug", Status: "done"})
	if err != nil {
		t.Fatal(err)
	}

	// List all
	all, err := s.ListTasks("")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 2 {
		t.Fatalf("ListTasks('') = %d tasks, want 2", len(all))
	}

	// List filtered
	active, err := s.ListTasks("active")
	if err != nil {
		t.Fatal(err)
	}
	if len(active) != 1 {
		t.Fatalf("ListTasks('active') = %d tasks, want 1", len(active))
	}
	if active[0].Title != "build widget" {
		t.Errorf("filtered task title = %q, want %q", active[0].Title, "build widget")
	}

	// Update
	got.Title = "build super widget"
	got.Status = "in_progress"
	if err := s.UpdateTask(got); err != nil {
		t.Fatal(err)
	}
	updated, err := s.GetTask(id)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Title != "build super widget" {
		t.Errorf("updated title = %q, want %q", updated.Title, "build super widget")
	}
	if updated.Status != "in_progress" {
		t.Errorf("updated status = %q, want %q", updated.Status, "in_progress")
	}
	if updated.UpdatedAt < got.CreatedAt {
		t.Error("updated_at should be >= created_at")
	}

	// Delete
	if err := s.DeleteTask(id); err != nil {
		t.Fatal(err)
	}
	_, err = s.GetTask(id)
	if err != sql.ErrNoRows {
		t.Errorf("GetTask after delete: err = %v, want sql.ErrNoRows", err)
	}
}

func TestSubtaskCRUD(t *testing.T) {
	s := testStore(t)

	taskID, err := s.CreateTask(&Task{Title: "parent", Status: "active"})
	if err != nil {
		t.Fatal(err)
	}

	// Create 3 subtasks — seq should auto-increment
	titles := []string{"step A", "step B", "step C"}
	for _, title := range titles {
		_, err := s.CreateSubtask(&Subtask{TaskID: taskID, Title: title, Status: "pending"})
		if err != nil {
			t.Fatal(err)
		}
	}

	// List and verify order
	subs, err := s.ListSubtasks(taskID)
	if err != nil {
		t.Fatal(err)
	}
	if len(subs) != 3 {
		t.Fatalf("got %d subtasks, want 3", len(subs))
	}
	for i, sub := range subs {
		if sub.Seq != i+1 {
			t.Errorf("subtask %d: seq = %d, want %d", i, sub.Seq, i+1)
		}
		if sub.Title != titles[i] {
			t.Errorf("subtask %d: title = %q, want %q", i, sub.Title, titles[i])
		}
	}

	// Update subtask status
	subs[1].Status = "done"
	if err := s.UpdateSubtask(&subs[1]); err != nil {
		t.Fatal(err)
	}
	updated, err := s.ListSubtasks(taskID)
	if err != nil {
		t.Fatal(err)
	}
	if updated[1].Status != "done" {
		t.Errorf("subtask status = %q, want %q", updated[1].Status, "done")
	}
}

func TestTaskLog(t *testing.T) {
	s := testStore(t)

	taskID, err := s.CreateTask(&Task{Title: "logged task", Status: "active"})
	if err != nil {
		t.Fatal(err)
	}

	// Add log entries
	for _, title := range []string{"started", "progressed", "finished"} {
		_, err := s.AddTaskLog(&TaskLogEntry{
			TaskID: taskID, Type: "status", Author: "worker-1", Title: title, Body: "details about " + title,
		})
		if err != nil {
			t.Fatal(err)
		}
	}

	// List and verify order
	entries, err := s.ListTaskLog(taskID)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 {
		t.Fatalf("got %d log entries, want 3", len(entries))
	}
	if entries[0].Title != "started" {
		t.Errorf("first entry title = %q, want %q", entries[0].Title, "started")
	}

	// Cascade delete — deleting the task should remove log entries
	if err := s.DeleteTask(taskID); err != nil {
		t.Fatal(err)
	}
	remaining, err := s.ListTaskLog(taskID)
	if err != nil {
		t.Fatal(err)
	}
	if len(remaining) != 0 {
		t.Errorf("after cascade delete: %d log entries remain, want 0", len(remaining))
	}
}

func TestPlanCRUD(t *testing.T) {
	s := testStore(t)

	// Create
	plan := &Plan{Title: "migration plan", Status: "draft", Body: "## Steps\n1. Migrate\n2. Verify"}
	id, err := s.CreatePlan(plan)
	if err != nil {
		t.Fatal(err)
	}
	if id == 0 {
		t.Fatal("expected non-zero ID")
	}

	// Get
	got, err := s.GetPlan(id)
	if err != nil {
		t.Fatal(err)
	}
	if got.Title != "migration plan" {
		t.Errorf("title = %q, want %q", got.Title, "migration plan")
	}
	if got.Status != "draft" {
		t.Errorf("status = %q, want %q", got.Status, "draft")
	}
	if got.Body != "## Steps\n1. Migrate\n2. Verify" {
		t.Errorf("body mismatch")
	}
	if got.CreatedAt == 0 || got.UpdatedAt == 0 {
		t.Error("timestamps should be set")
	}

	// List
	s.CreatePlan(&Plan{Title: "rollback plan", Status: "active"})
	plans, err := s.ListPlans()
	if err != nil {
		t.Fatal(err)
	}
	if len(plans) != 2 {
		t.Fatalf("got %d plans, want 2", len(plans))
	}

	// Update
	got.Title = "updated migration plan"
	got.Status = "active"
	if err := s.UpdatePlan(got); err != nil {
		t.Fatal(err)
	}
	updated, err := s.GetPlan(id)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Title != "updated migration plan" {
		t.Errorf("updated title = %q, want %q", updated.Title, "updated migration plan")
	}

	// Delete
	if err := s.DeletePlan(id); err != nil {
		t.Fatal(err)
	}
	_, err = s.GetPlan(id)
	if err != sql.ErrNoRows {
		t.Errorf("GetPlan after delete: err = %v, want sql.ErrNoRows", err)
	}
}

func TestTeamCRUD(t *testing.T) {
	s := testStore(t)

	// Upsert team
	team := &Team{WindowID: "w1", Name: "alpha", Type: "standard", PaneCount: 4}
	if err := s.UpsertTeam(team); err != nil {
		t.Fatal(err)
	}
	if team.CreatedAt == 0 {
		t.Error("created_at should be set after upsert")
	}

	// Get
	got, err := s.GetTeam("w1")
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "alpha" {
		t.Errorf("name = %q, want %q", got.Name, "alpha")
	}
	if got.PaneCount != 4 {
		t.Errorf("pane_count = %d, want 4", got.PaneCount)
	}

	// Upsert update — change pane count
	team.PaneCount = 6
	if err := s.UpsertTeam(team); err != nil {
		t.Fatal(err)
	}
	got, err = s.GetTeam("w1")
	if err != nil {
		t.Fatal(err)
	}
	if got.PaneCount != 6 {
		t.Errorf("after upsert update: pane_count = %d, want 6", got.PaneCount)
	}

	// List
	s.UpsertTeam(&Team{WindowID: "w2", Name: "beta", Type: "worktree", WorktreePath: "/tmp/wt"})
	teams, err := s.ListTeams()
	if err != nil {
		t.Fatal(err)
	}
	if len(teams) != 2 {
		t.Fatalf("got %d teams, want 2", len(teams))
	}

	// Get not found
	_, err = s.GetTeam("nonexistent")
	if err != sql.ErrNoRows {
		t.Errorf("GetTeam nonexistent: err = %v, want sql.ErrNoRows", err)
	}

	// Delete
	if err := s.DeleteTeam("w1"); err != nil {
		t.Fatal(err)
	}
	teams, _ = s.ListTeams()
	if len(teams) != 1 {
		t.Errorf("after delete: %d teams, want 1", len(teams))
	}

	// Pane status
	taskID := int64(42)
	ps := &PaneStatus{
		PaneID: "w1.1", WindowID: "w2", Role: "worker", Status: "BUSY",
		TaskID: &taskID, TaskTitle: "fix it", Agent: "doey-worker",
	}
	if err := s.UpsertPaneStatus(ps); err != nil {
		t.Fatal(err)
	}
	if ps.UpdatedAt == 0 {
		t.Error("pane status updated_at should be set")
	}

	gotPS, err := s.GetPaneStatus("w1.1")
	if err != nil {
		t.Fatal(err)
	}
	if gotPS.Role != "worker" {
		t.Errorf("role = %q, want %q", gotPS.Role, "worker")
	}
	if gotPS.TaskID == nil || *gotPS.TaskID != 42 {
		t.Errorf("task_id = %v, want 42", gotPS.TaskID)
	}

	// Add second pane to same window and list
	s.UpsertPaneStatus(&PaneStatus{PaneID: "w2.0", WindowID: "w2", Role: "subtaskmaster", Status: "READY"})
	statuses, err := s.ListPaneStatuses("w2")
	if err != nil {
		t.Fatal(err)
	}
	if len(statuses) != 2 {
		t.Fatalf("got %d pane statuses, want 2", len(statuses))
	}
	// Verify order by pane_id
	if statuses[0].PaneID != "w1.1" {
		t.Errorf("first pane = %q, want %q", statuses[0].PaneID, "w1.1")
	}
}

func TestMessageCRUD(t *testing.T) {
	s := testStore(t)

	// Send messages
	m1 := &Message{FromPane: "0.1", ToPane: "0.2", Subject: "task ready", Body: "go"}
	id1, err := s.SendMessage(m1)
	if err != nil {
		t.Fatal(err)
	}
	if id1 == 0 {
		t.Fatal("expected non-zero ID")
	}

	m2 := &Message{FromPane: "0.1", ToPane: "0.2", Subject: "update", Body: "status changed"}
	s.SendMessage(m2)

	// Also send to different pane
	s.SendMessage(&Message{FromPane: "0.2", ToPane: "1.0", Subject: "dispatch"})

	// List all for 0.2
	msgs, err := s.ListMessages("0.2", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 {
		t.Fatalf("got %d messages for 0.2, want 2", len(msgs))
	}
	// Verify both subjects present (order may vary within same second)
	subjects := map[string]bool{}
	for _, m := range msgs {
		subjects[m.Subject] = true
	}
	if !subjects["task ready"] || !subjects["update"] {
		t.Errorf("expected both subjects, got %v", subjects)
	}

	// Unread only
	unread, err := s.ListMessages("0.2", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(unread) != 2 {
		t.Fatalf("unread = %d, want 2", len(unread))
	}

	// Count unread
	count, err := s.CountUnread("0.2")
	if err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Errorf("CountUnread = %d, want 2", count)
	}

	// Mark one read
	if err := s.MarkRead(id1); err != nil {
		t.Fatal(err)
	}
	count, _ = s.CountUnread("0.2")
	if count != 1 {
		t.Errorf("after MarkRead: CountUnread = %d, want 1", count)
	}

	// Mark all read
	if err := s.MarkAllRead("0.2"); err != nil {
		t.Fatal(err)
	}
	count, _ = s.CountUnread("0.2")
	if count != 0 {
		t.Errorf("after MarkAllRead: CountUnread = %d, want 0", count)
	}

	// Verify unread filter returns empty
	unread, _ = s.ListMessages("0.2", true)
	if len(unread) != 0 {
		t.Errorf("unread after MarkAllRead = %d, want 0", len(unread))
	}
}

func TestEventCRUD(t *testing.T) {
	s := testStore(t)

	taskID := int64(10)

	// Log events of different types
	s.LogEvent(&Event{Type: "dispatch", Source: "taskmaster", Target: "w1.1", TaskID: &taskID, Data: `{"cmd":"go"}`})
	s.LogEvent(&Event{Type: "status", Source: "w1.1", Data: "BUSY"})
	s.LogEvent(&Event{Type: "dispatch", Source: "taskmaster", Target: "w1.2", TaskID: &taskID})

	// List all (limit 10)
	all, err := s.ListEvents("", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 3 {
		t.Fatalf("got %d events, want 3", len(all))
	}
	// Newest first
	if all[0].Type != "dispatch" && all[0].Target != "w1.2" {
		t.Error("newest event should be last inserted dispatch")
	}

	// Filter by type
	dispatches, err := s.ListEvents("dispatch", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(dispatches) != 2 {
		t.Fatalf("dispatch events = %d, want 2", len(dispatches))
	}

	// Verify limit
	limited, err := s.ListEvents("", 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(limited) != 1 {
		t.Fatalf("limited events = %d, want 1", len(limited))
	}

	// List by task
	byTask, err := s.ListEventsByTask(taskID)
	if err != nil {
		t.Fatal(err)
	}
	if len(byTask) != 2 {
		t.Fatalf("events for task = %d, want 2", len(byTask))
	}
	// Oldest first
	if byTask[0].Target != "w1.1" {
		t.Errorf("first task event target = %q, want %q", byTask[0].Target, "w1.1")
	}
}

func TestAgentCRUD(t *testing.T) {
	s := testStore(t)

	// Upsert
	a := &Agent{Name: "doey-worker", DisplayName: "Worker", Model: "opus", Description: "does work", FilePath: "/agents/doey-worker.md"}
	if err := s.UpsertAgent(a); err != nil {
		t.Fatal(err)
	}

	// Get
	got, err := s.GetAgent("doey-worker")
	if err != nil {
		t.Fatal(err)
	}
	if got.DisplayName != "Worker" {
		t.Errorf("display_name = %q, want %q", got.DisplayName, "Worker")
	}
	if got.Model != "opus" {
		t.Errorf("model = %q, want %q", got.Model, "opus")
	}

	// Upsert update
	a.Model = "sonnet"
	if err := s.UpsertAgent(a); err != nil {
		t.Fatal(err)
	}
	got, _ = s.GetAgent("doey-worker")
	if got.Model != "sonnet" {
		t.Errorf("after upsert: model = %q, want %q", got.Model, "sonnet")
	}

	// List
	s.UpsertAgent(&Agent{Name: "doey-boss", DisplayName: "Boss"})
	agents, err := s.ListAgents()
	if err != nil {
		t.Fatal(err)
	}
	if len(agents) != 2 {
		t.Fatalf("got %d agents, want 2", len(agents))
	}
	// Ordered by name
	if agents[0].Name != "doey-boss" {
		t.Errorf("first agent = %q, want %q", agents[0].Name, "doey-boss")
	}

	// Delete
	if err := s.DeleteAgent("doey-worker"); err != nil {
		t.Fatal(err)
	}
	_, err = s.GetAgent("doey-worker")
	if err != sql.ErrNoRows {
		t.Errorf("GetAgent after delete: err = %v, want sql.ErrNoRows", err)
	}
}

func TestConfigCRUD(t *testing.T) {
	s := testStore(t)

	// Set
	if err := s.SetConfig("theme", "dark", "user"); err != nil {
		t.Fatal(err)
	}

	// Get
	val, err := s.GetConfig("theme")
	if err != nil {
		t.Fatal(err)
	}
	if val != "dark" {
		t.Errorf("value = %q, want %q", val, "dark")
	}

	// Get nonexistent
	_, err = s.GetConfig("nonexistent")
	if err != sql.ErrNoRows {
		t.Errorf("GetConfig nonexistent: err = %v, want sql.ErrNoRows", err)
	}

	// Upsert — overwrite existing key
	if err := s.SetConfig("theme", "light", "override"); err != nil {
		t.Fatal(err)
	}
	val, _ = s.GetConfig("theme")
	if val != "light" {
		t.Errorf("after upsert: value = %q, want %q", val, "light")
	}

	// List
	s.SetConfig("workers", "4", "default")
	entries, err := s.ListConfig()
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("got %d config entries, want 2", len(entries))
	}
	// Ordered by key
	if entries[0].Key != "theme" {
		t.Errorf("first key = %q, want %q", entries[0].Key, "theme")
	}

	// Delete
	if err := s.DeleteConfig("theme"); err != nil {
		t.Fatal(err)
	}
	_, err = s.GetConfig("theme")
	if err != sql.ErrNoRows {
		t.Errorf("GetConfig after delete: err = %v, want sql.ErrNoRows", err)
	}
}

func TestSchemaIdempotent(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "reopen.db")

	// Open, write, close
	s1, err := Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	s1.SetConfig("key", "val", "test")
	s1.Close()

	// Reopen same path — should not error, data persists
	s2, err := Open(dbPath)
	if err != nil {
		t.Fatal("reopen failed:", err)
	}
	defer s2.Close()

	val, err := s2.GetConfig("key")
	if err != nil {
		t.Fatal(err)
	}
	if val != "val" {
		t.Errorf("value after reopen = %q, want %q", val, "val")
	}
}
