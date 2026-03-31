package runtime

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

const taskConfigFile = "tasks.json"

// configProjectDir holds the project directory for locating .doey/tasks/tasks.json.
// Set via SetProjectDir when the TUI resolves the session config.
var configProjectDir string

// SetProjectDir sets the project directory used by the persistent task store.
// When set, tasks.json lives in <projectDir>/.doey/tasks/ instead of ~/.config/doey/.
func SetProjectDir(dir string) {
	if dir != "" {
		configProjectDir = dir
	}
}

// PersistentTaskLog is a timestamped activity log entry stored in the persistent task store.
type PersistentTaskLog struct {
	Timestamp int64  `json:"ts"`
	Entry     string `json:"entry"`
}

// PersistentSubtask represents a subtask parsed from TASK_SUBTASK_<N>_* fields.
type PersistentSubtask struct {
	Index    int    `json:"index"`
	Title    string `json:"title"`
	Status   string `json:"status"`             // pending, in_progress, done, failed
	Assignee string `json:"assignee,omitempty"`
}

// PersistentUpdate represents a live update parsed from TASK_UPDATE_<N>_* fields.
type PersistentUpdate struct {
	Index     int    `json:"index"`
	Timestamp int64  `json:"ts"`
	Author    string `json:"author,omitempty"`
	Text      string `json:"text"`
}

// PersistentReport represents a worker report stored in the persistent task store.
type PersistentReport struct {
	Index   int    `json:"index"`
	Author  string `json:"author,omitempty"`
	Type    string `json:"type"`
	Title   string `json:"title"`
	Body    string `json:"body"`
	Created int64  `json:"created"`
}

// PersistentAttachment represents a file attachment stored with a task (persistent store).
type PersistentAttachment struct {
	Filename  string `json:"filename"`
	Type      string `json:"type"`
	Title     string `json:"title"`
	Author    string `json:"author"`
	Timestamp int64  `json:"timestamp"`
	Body      string `json:"body,omitempty"`
	FilePath  string `json:"filepath,omitempty"`
}

// PersistentRecoveryEvent represents a stale detection or auto-recovery event (persistent store).
type PersistentRecoveryEvent struct {
	Index       int    `json:"index"`
	Timestamp   int64  `json:"timestamp"`
	Event       string `json:"event"`
	FailedAgent string `json:"failed_agent,omitempty"`
	NewAgent    string `json:"new_agent,omitempty"`
	Description string `json:"description,omitempty"`
}

// PersistentQAHop represents one step in a Q&A relay chain (persistent store).
type PersistentQAHop struct {
	Role      string `json:"role"`
	Pane      string `json:"pane"`
	Action    string `json:"action"`
	Timestamp int64  `json:"ts"`
}

// PersistentQAEntry represents a complete Q&A exchange with relay chain (persistent store).
type PersistentQAEntry struct {
	TrackingID string            `json:"tracking_id"`
	Question   string            `json:"question"`
	Answer     string            `json:"answer,omitempty"`
	Status     string            `json:"status"`
	Hops       []PersistentQAHop `json:"hops"`
	Created    int64             `json:"created"`
	Answered   int64             `json:"answered,omitempty"`
}

// PersistentTask is a task stored in the persistent JSON store.
type PersistentTask struct {
	ID           string              `json:"id"`
	Title        string              `json:"title"`
	Status       string              `json:"status"`                  // draft, active, in_progress, paused, blocked, pending_user_confirmation, done, cancelled
	Phase        string              `json:"phase,omitempty"`         // research, review, implementation
	Description  string              `json:"description"`             // optional detail text
	Attachments  []string            `json:"attachments,omitempty"`   // list of URLs/file paths
	Team         string              `json:"team"`                    // assigned team name (optional)
	Created      int64               `json:"created"`                 // unix epoch
	Updated      int64               `json:"updated"`                 // unix epoch
	Priority     int                 `json:"priority"`                // sort order (lower = higher priority)
	Category     string              `json:"category,omitempty"`      // bug, feature, refactor, docs, infrastructure
	Tags         []string            `json:"tags,omitempty"`          // cross-cutting concerns
	MergedInto   string              `json:"merged_into,omitempty"`   // task ID this was merged into
	ParentTaskID string              `json:"parent_task_id,omitempty"` // parent task for subtask hierarchy
	Result       string              `json:"result,omitempty"`        // outcome summary
	Logs         []PersistentTaskLog `json:"logs,omitempty"`          // activity log entries
	// v3 schema fields
	Type               string `json:"type,omitempty"`                // bug, feature, refactor, docs, infrastructure
	Blockers           string `json:"blockers,omitempty"`            // blocking issues
	CreatedBy          string `json:"created_by,omitempty"`          // who created it
	AssignedTo         string `json:"assigned_to,omitempty"`         // who/what team
	AcceptanceCriteria string `json:"acceptance_criteria,omitempty"` // bulleted criteria
	DecisionLog        string   `json:"decision_log,omitempty"`        // timestamped decisions
	Notes              string   `json:"notes,omitempty"`               // free-form journal
	// Proof-of-completion fields
	FilesChanged []string `json:"files_changed,omitempty"` // files modified by task workers
	Commits      string   `json:"commits,omitempty"`       // commit hashes with one-line messages
	// Live tracking fields
	Subtasks []PersistentSubtask `json:"subtasks,omitempty"` // subtask breakdown
	Updates  []PersistentUpdate  `json:"updates,omitempty"`  // live update log
	Reports         []PersistentReport         `json:"reports,omitempty"`          // worker reports
	TaskAttachments []PersistentAttachment     `json:"task_attachments,omitempty"` // file attachments from .doey/tasks/<id>/attachments/
	RecoveryLog     []PersistentRecoveryEvent  `json:"recovery_log,omitempty"`     // stale detection / auto-recovery events
	QAThread []PersistentQAEntry `json:"qa_thread,omitempty"` // Q&A relay chain entries
}

// TaskStore holds all persistent tasks.
type TaskStore struct {
	Tasks  []PersistentTask `json:"tasks"`
	NextID int              `json:"next_id"` // auto-increment counter
}

// taskConfigPath returns the path to tasks.json.
// Priority: configProjectDir (set by TUI) > DOEY_PROJECT_DIR env > ~/.config/doey/.
func taskConfigPath() string {
	// 1. Package-level project dir (set by TUI via SetProjectDir)
	if configProjectDir != "" {
		return filepath.Join(configProjectDir, ".doey", "tasks", taskConfigFile)
	}
	// 2. Environment variable (set by session hooks)
	if pd := os.Getenv("DOEY_PROJECT_DIR"); pd != "" {
		candidate := filepath.Join(pd, ".doey", "tasks", taskConfigFile)
		if _, err := os.Stat(filepath.Dir(candidate)); err == nil {
			return candidate
		}
	}
	// 3. Fallback: ~/.config/doey/tasks.json
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = filepath.Join(os.Getenv("HOME"), ".config")
	}
	return filepath.Join(dir, "doey", taskConfigFile)
}

// ReadTaskStore reads the persistent task store (project .doey/tasks/ or ~/.config/doey/ fallback).
// Returns empty store if file does not exist.
func ReadTaskStore() (TaskStore, error) {
	var store TaskStore

	data, err := os.ReadFile(taskConfigPath())
	if err != nil {
		if os.IsNotExist(err) {
			return store, nil
		}
		return store, nil // graceful: treat any read error as empty
	}

	if err := json.Unmarshal(data, &store); err != nil {
		return TaskStore{}, nil // graceful: malformed file = empty store
	}

	return store, nil
}

// WriteTaskStore writes the persistent task store (project .doey/tasks/ or ~/.config/doey/ fallback).
// Creates the directory if it does not exist. Uses atomic write via .tmp + rename.
func WriteTaskStore(store TaskStore) error {
	path := taskConfigPath()

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return err
	}

	// Atomic write: write to .tmp then rename
	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

// AddTask creates a new task and returns its ID.
func (s *TaskStore) AddTask(title string) string {
	s.NextID++
	id := strconv.Itoa(s.NextID)
	now := time.Now().Unix()
	s.Tasks = append(s.Tasks, PersistentTask{
		ID:      id,
		Title:   title,
		Status:  "active",
		Created: now,
		Updated: now,
	})
	return id
}

// MoveTask sets a task's status directly.
func (s *TaskStore) MoveTask(id, status string) bool {
	for i := range s.Tasks {
		if s.Tasks[i].ID == id {
			s.Tasks[i].Status = status
			s.Tasks[i].Updated = time.Now().Unix()
			return true
		}
	}
	return false
}

// CancelTask marks a task as cancelled.
func (s *TaskStore) CancelTask(id string) bool {
	for i := range s.Tasks {
		if s.Tasks[i].ID == id {
			s.Tasks[i].Status = "cancelled"
			s.Tasks[i].Updated = time.Now().Unix()
			return true
		}
	}
	return false
}

// UpdateTask updates a task's title or description.
func (s *TaskStore) UpdateTask(id, title, description string) bool {
	for i := range s.Tasks {
		if s.Tasks[i].ID == id {
			if title != "" {
				s.Tasks[i].Title = title
			}
			if description != "" {
				s.Tasks[i].Description = description
			}
			s.Tasks[i].Updated = time.Now().Unix()
			return true
		}
	}
	return false
}

// FindTask returns a task by ID.
func (s *TaskStore) FindTask(id string) *PersistentTask {
	for i := range s.Tasks {
		if s.Tasks[i].ID == id {
			return &s.Tasks[i]
		}
	}
	return nil
}

// parsePriority converts a string priority (high/medium/low) to an int (1/2/3).
// Returns 0 if the string is empty or unrecognized.
func parsePriority(s string) int {
	switch s {
	case "high":
		return 1
	case "medium":
		return 2
	case "low":
		return 3
	default:
		return 0
	}
}

// mergeLogs appends new log entries from runtime that aren't already in the persistent store.
// Comparison is by timestamp to avoid duplicates.
func mergeLogs(existing []PersistentTaskLog, incoming []TaskLog) []PersistentTaskLog {
	if len(incoming) == 0 {
		return existing
	}
	seen := make(map[int64]bool, len(existing))
	for _, l := range existing {
		seen[l.Timestamp] = true
	}
	for _, l := range incoming {
		if !seen[l.Timestamp] {
			existing = append(existing, PersistentTaskLog{
				Timestamp: l.Timestamp,
				Entry:     l.Entry,
			})
			seen[l.Timestamp] = true
		}
	}
	return existing
}

// mergeRuntimeIntoPersistent updates a persistent task with non-empty runtime fields.
// Preserves existing persistent data when the runtime field is empty/zero.
func mergeRuntimeIntoPersistent(pt *PersistentTask, rt Task) {
	if rt.Title != "" {
		pt.Title = rt.Title
	}
	if rt.Status != "" {
		pt.Status = rt.Status
	}
	if rt.Phase != "" {
		pt.Phase = rt.Phase
	}
	if rt.Description != "" {
		pt.Description = rt.Description
	}
	if len(rt.Attachments) > 0 {
		pt.Attachments = rt.Attachments
	}
	if rt.Team != "" {
		pt.Team = rt.Team
	}
	if rt.Category != "" {
		pt.Category = rt.Category
	}
	if len(rt.Tags) > 0 {
		pt.Tags = rt.Tags
	}
	if p := parsePriority(rt.Priority); p != 0 {
		pt.Priority = p
	}
	if rt.MergedInto != "" {
		pt.MergedInto = rt.MergedInto
	}
	if rt.ParentTaskID != "" {
		pt.ParentTaskID = rt.ParentTaskID
	}
	if rt.Result != "" {
		pt.Result = rt.Result
	}
	if rt.Category != "" {
		pt.Type = rt.Category
	}
	if rt.Blockers != "" {
		pt.Blockers = rt.Blockers
	}
	if rt.CreatedBy != "" {
		pt.CreatedBy = rt.CreatedBy
	}
	if rt.AssignedTo != "" {
		pt.AssignedTo = rt.AssignedTo
	}
	if rt.AcceptanceCriteria != "" {
		pt.AcceptanceCriteria = rt.AcceptanceCriteria
	}
	if rt.DecisionLog != "" {
		pt.DecisionLog = rt.DecisionLog
	}
	if rt.Notes != "" {
		pt.Notes = rt.Notes
	}
	if len(rt.FilesChanged) > 0 {
		pt.FilesChanged = rt.FilesChanged
	}
	if rt.Commits != "" {
		pt.Commits = rt.Commits
	}
	if len(rt.Reports) > 0 {
		pt.Reports = nil
		for _, r := range rt.Reports {
			pt.Reports = append(pt.Reports, PersistentReport{
				Index: r.Index, Author: r.Author, Type: r.Type,
				Title: r.Title, Body: r.Body, Created: r.Created,
			})
		}
	}
	pt.Logs = mergeLogs(pt.Logs, rt.Logs)
	if rt.Updated != 0 {
		pt.Updated = rt.Updated
	} else {
		pt.Updated = time.Now().Unix()
	}
}

// MergeRuntimeTasks imports runtime tasks into the persistent store.
// New tasks are added; existing tasks are updated with non-empty runtime fields.
func (s *TaskStore) MergeRuntimeTasks(runtimeTasks []Task) {
	index := make(map[string]int, len(s.Tasks))
	for i, t := range s.Tasks {
		index[t.ID] = i
	}
	for _, rt := range runtimeTasks {
		id, _ := strconv.Atoi(rt.ID)
		if id >= s.NextID {
			s.NextID = id + 1
		}

		if i, ok := index[rt.ID]; ok {
			mergeRuntimeIntoPersistent(&s.Tasks[i], rt)
			continue
		}

		pt := PersistentTask{
			ID:           rt.ID,
			Title:        rt.Title,
			Status:       rt.Status,
			Description:  rt.Description,
			Attachments:  rt.Attachments,
			Team:         rt.Team,
			Created:      rt.Created,
			Updated:      rt.Created,
			Priority:     parsePriority(rt.Priority),
			Category:     rt.Category,
			Tags:         rt.Tags,
			MergedInto:   rt.MergedInto,
			ParentTaskID: rt.ParentTaskID,
			Result:       rt.Result,
			Type:               rt.Category,
			Blockers:           rt.Blockers,
			CreatedBy:          rt.CreatedBy,
			AssignedTo:         rt.AssignedTo,
			AcceptanceCriteria: rt.AcceptanceCriteria,
			DecisionLog:        rt.DecisionLog,
			Notes:              rt.Notes,
			FilesChanged:       rt.FilesChanged,
			Commits:            rt.Commits,
		}
		pt.Logs = mergeLogs(nil, rt.Logs)
		index[rt.ID] = len(s.Tasks)
		s.Tasks = append(s.Tasks, pt)
	}
}
