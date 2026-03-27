package runtime

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

const taskConfigFile = "tasks.json"

// PersistentTask is a task stored in the persistent JSON store.
type PersistentTask struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Status      string `json:"status"`      // backlog, todo, in_progress, committed, pushed
	Section     string `json:"section"`      // "backlog", "active", "complete"
	Description string   `json:"description"`            // optional detail text
	Attachments []string `json:"attachments,omitempty"`  // list of URLs/file paths
	Team        string   `json:"team"`                   // assigned team name (optional)
	Created     int64  `json:"created"`      // unix epoch
	Updated     int64  `json:"updated"`      // unix epoch
	Priority    int    `json:"priority"`     // sort order within section (lower = higher priority)
}

// TaskStore holds all persistent tasks.
type TaskStore struct {
	Tasks  []PersistentTask `json:"tasks"`
	NextID int              `json:"next_id"` // auto-increment counter
}

// taskConfigPath returns ~/.config/doey/tasks.json
func taskConfigPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = filepath.Join(os.Getenv("HOME"), ".config")
	}
	return filepath.Join(dir, "doey", taskConfigFile)
}

// ReadTaskStore reads the task store from ~/.config/doey/tasks.json.
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

// WriteTaskStore writes the task store to ~/.config/doey/tasks.json.
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
func (s *TaskStore) AddTask(title, section string) string {
	s.NextID++
	id := strconv.Itoa(s.NextID)
	now := time.Now().Unix()
	s.Tasks = append(s.Tasks, PersistentTask{
		ID:      id,
		Title:   title,
		Status:  section,
		Section: section,
		Created: now,
		Updated: now,
	})
	return id
}

// MoveTask moves a task to a new section and updates status.
func (s *TaskStore) MoveTask(id, section string) bool {
	for i := range s.Tasks {
		if s.Tasks[i].ID == id {
			s.Tasks[i].Section = section
			switch section {
			case "backlog":
				s.Tasks[i].Status = "backlog"
			case "active":
				s.Tasks[i].Status = "todo"
			case "complete":
				s.Tasks[i].Status = "committed"
			}
			s.Tasks[i].Updated = time.Now().Unix()
			return true
		}
	}
	return false
}

// CancelTask marks a task as cancelled by moving it to backlog.
func (s *TaskStore) CancelTask(id string) bool {
	for i := range s.Tasks {
		if s.Tasks[i].ID == id {
			s.Tasks[i].Status = "backlog"
			s.Tasks[i].Section = "backlog"
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

// MergeRuntimeTasks imports runtime tasks not already in the persistent store.
func (s *TaskStore) MergeRuntimeTasks(runtimeTasks []Task) {
	existing := make(map[string]bool)
	for _, t := range s.Tasks {
		existing[t.ID] = true
	}
	for _, rt := range runtimeTasks {
		if existing[rt.ID] {
			continue
		}
		var section string
		switch rt.Status {
		case "todo", "in_progress", "active", "pending_user_confirmation":
			section = "active"
		case "committed", "pushed", "done", "cancelled":
			section = "complete"
		default:
			section = "backlog"
		}

		id, _ := strconv.Atoi(rt.ID)
		if id >= s.NextID {
			s.NextID = id + 1
		}

		s.Tasks = append(s.Tasks, PersistentTask{
			ID:          rt.ID,
			Title:       rt.Title,
			Status:      rt.Status,
			Section:     section,
			Description: rt.Description,
			Attachments: rt.Attachments,
			Created:     rt.Created,
			Updated:     rt.Created,
		})
	}
}
