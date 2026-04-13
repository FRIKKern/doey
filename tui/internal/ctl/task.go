package ctl

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// TaskEntry is a lightweight task representation for CRUD operations.
type TaskEntry struct {
	ID            string
	Title         string
	Shortname     string
	Status        string
	Type          string
	Description   string
	CreatedBy     string
	AssignedTo    string
	Team          string
	SchemaVersion int
	Subtasks      []SubtaskEntry
	DecisionLog   string
	Notes         string
}

// SubtaskEntry represents a single subtask within a task.
type SubtaskEntry struct {
	Index       int
	Description string
	Status      string
}

// taskDir returns the absolute path to the tasks directory.
func taskDir(projectDir string) string {
	return filepath.Join(projectDir, TaskDir)
}

// taskPath returns the absolute path to a .task file.
func taskPath(projectDir, taskID string) string {
	return filepath.Join(projectDir, TaskDir, taskID+TaskExt)
}

// ReadTask reads and parses a .task file by ID.
func ReadTask(projectDir, taskID string) (*TaskEntry, error) {
	data, err := os.ReadFile(taskPath(projectDir, taskID))
	if err != nil {
		return nil, fmt.Errorf("ctl: read task %s: %w", taskID, err)
	}
	return parseTask(string(data))
}

// parseTask parses KEY=VALUE lines from a .task file into a TaskEntry.
func parseTask(content string) (*TaskEntry, error) {
	fields := make(map[string]string)
	for _, line := range strings.Split(content, "\n") {
		idx := strings.IndexByte(line, '=')
		if idx < 0 {
			continue
		}
		key := line[:idx]
		val := line[idx+1:]
		fields[key] = val
	}

	t := &TaskEntry{
		ID:          fields[FieldTaskID],
		Title:       fields[FieldTaskTitle],
		Shortname:   fields[FieldTaskShortname],
		Status:      fields[FieldTaskStatus],
		Type:        fields[FieldTaskType],
		Description: fields[FieldTaskDescription],
		CreatedBy:   fields[FieldTaskCreatedBy],
		AssignedTo:  fields[FieldTaskAssignedTo],
		Team:        fields[FieldTaskTeam],
		DecisionLog: fields[FieldTaskDecisionLog],
		Notes:       fields[FieldTaskNotes],
	}
	if v, err := strconv.Atoi(fields[FieldTaskSchemaVersion]); err == nil {
		t.SchemaVersion = v
	}
	// v4 expanded form takes precedence: TASK_SUBTASK_<N>_TITLE / _STATUS
	expanded := parseExpandedSubtasks(fields)
	if len(expanded) > 0 {
		t.Subtasks = expanded
	} else if raw := fields[FieldTaskSubtasks]; raw != "" {
		// v3 fallback: inline TASK_SUBTASKS
		t.Subtasks = parseSubtasks(raw)
	}
	return t, nil
}

// parseExpandedSubtasks reads TASK_SUBTASK_<N>_TITLE / _STATUS entries
// from the parsed fields map and returns them ordered by index.
func parseExpandedSubtasks(fields map[string]string) []SubtaskEntry {
	byIdx := make(map[int]*SubtaskEntry)
	for key, val := range fields {
		if !strings.HasPrefix(key, "TASK_SUBTASK_") {
			continue
		}
		rest := strings.TrimPrefix(key, "TASK_SUBTASK_")
		// rest like "1_TITLE" or "12_STATUS"
		under := strings.IndexByte(rest, '_')
		if under < 0 {
			continue
		}
		idx, err := strconv.Atoi(rest[:under])
		if err != nil {
			continue
		}
		if byIdx[idx] == nil {
			byIdx[idx] = &SubtaskEntry{Index: idx, Status: "pending"}
		}
		switch rest[under+1:] {
		case "TITLE":
			byIdx[idx].Description = val
		case "STATUS":
			byIdx[idx].Status = val
		}
	}
	if len(byIdx) == 0 {
		return nil
	}
	idxs := make([]int, 0, len(byIdx))
	for i := range byIdx {
		idxs = append(idxs, i)
	}
	// Simple insertion sort — count is tiny.
	for i := 1; i < len(idxs); i++ {
		for j := i; j > 0 && idxs[j-1] > idxs[j]; j-- {
			idxs[j-1], idxs[j] = idxs[j], idxs[j-1]
		}
	}
	out := make([]SubtaskEntry, 0, len(idxs))
	for _, i := range idxs {
		out = append(out, *byIdx[i])
	}
	return out
}

// parseSubtasks parses the escaped \n-delimited subtask string.
// Format per entry: index:description:status
func parseSubtasks(raw string) []SubtaskEntry {
	// Subtasks are stored with literal \n (two chars) as separator.
	parts := strings.Split(raw, `\n`)
	var out []SubtaskEntry
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		// Split as index:description:status — description may contain colons,
		// so split from the right for status, from the left for index.
		firstColon := strings.IndexByte(p, ':')
		lastColon := strings.LastIndexByte(p, ':')
		if firstColon < 0 || firstColon == lastColon {
			continue
		}
		idx, err := strconv.Atoi(p[:firstColon])
		if err != nil {
			continue
		}
		desc := p[firstColon+1 : lastColon]
		status := p[lastColon+1:]
		out = append(out, SubtaskEntry{Index: idx, Description: desc, Status: status})
	}
	return out
}

// CreateTask creates a new task file with an auto-incremented ID.
// Returns the new task ID.
func CreateTask(projectDir, title, taskType, createdBy, description string, shortname ...string) (string, error) {
	dir := taskDir(projectDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("ctl: create task dir: %w", err)
	}

	// Read and increment .next_id.
	nextIDPath := filepath.Join(dir, ".next_id")
	idStr, err := readNextID(nextIDPath)
	if err != nil {
		return "", err
	}
	id, err := strconv.Atoi(strings.TrimSpace(idStr))
	if err != nil {
		return "", fmt.Errorf("ctl: parse .next_id: %w", err)
	}

	taskID := strconv.Itoa(id)
	now := strconv.FormatInt(time.Now().Unix(), 10)

	sn := ""
	if len(shortname) > 0 && shortname[0] != "" {
		sn = shortname[0]
	} else {
		sn = generateShortname(title)
	}

	var b strings.Builder
	b.WriteString(FieldTaskSchemaVersion + "=4\n")
	b.WriteString(FieldTaskID + "=" + taskID + "\n")
	b.WriteString(FieldTaskTitle + "=" + title + "\n")
	b.WriteString(FieldTaskShortname + "=" + sn + "\n")
	b.WriteString(FieldTaskStatus + "=" + TaskStatusDraft + "\n")
	b.WriteString(FieldTaskType + "=" + taskType + "\n")
	b.WriteString(FieldTaskTags + "=\n")
	b.WriteString(FieldTaskCreatedBy + "=" + createdBy + "\n")
	b.WriteString(FieldTaskAssignedTo + "=\n")
	b.WriteString(FieldTaskDescription + "=" + description + "\n")
	b.WriteString(FieldTaskAcceptance + "=\n")
	b.WriteString(FieldTaskSuccessCriteria + "=\n")
	b.WriteString(FieldTaskConstraints + "=\n")
	b.WriteString(FieldTaskRunningSummary + "=\n")
	b.WriteString(FieldTaskHypotheses + "=\n")
	b.WriteString(FieldTaskDecisionLog + "=" + now + ":Created task\n")
	// v4: no inline TASK_SUBTASKS — canonical shape is TASK_SUBTASK_N_*
	b.WriteString(FieldTaskRelatedFiles + "=\n")
	b.WriteString(FieldTaskBlockers + "=\n")
	b.WriteString(FieldTaskTimestamps + "=created=" + now + "\n")
	b.WriteString(FieldTaskPhase + "=0\n")
	b.WriteString(FieldTaskTotalPhases + "=0\n")
	b.WriteString(FieldTaskNotes + "=\n")
	b.WriteString(FieldTaskUpdated + "=" + now + "\n")

	// Atomic write: temp file → rename.
	dest := taskPath(projectDir, taskID)
	if err := atomicWrite(dest, []byte(b.String())); err != nil {
		return "", fmt.Errorf("ctl: create task %s: %w", taskID, err)
	}

	// Bump .next_id.
	if err := atomicWrite(nextIDPath, []byte(strconv.Itoa(id+1)+"\n")); err != nil {
		return "", fmt.Errorf("ctl: bump .next_id: %w", err)
	}

	return taskID, nil
}

// UpdateTaskField replaces or appends a single KEY=VALUE field in a task file.
func UpdateTaskField(projectDir, taskID, field, value string) error {
	path := taskPath(projectDir, taskID)
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("ctl: update task %s: %w", taskID, err)
	}

	content := replaceField(string(data), field, value)
	if err := atomicWrite(path, []byte(content)); err != nil {
		return fmt.Errorf("ctl: update task %s field %s: %w", taskID, field, err)
	}
	return nil
}

// AddSubtask appends a new subtask (v4 expanded form) and returns its index.
func AddSubtask(projectDir, taskID, description string) (int, error) {
	task, err := ReadTask(projectDir, taskID)
	if err != nil {
		return 0, err
	}

	// Next index is max existing + 1.
	maxIdx := 0
	for _, s := range task.Subtasks {
		if s.Index > maxIdx {
			maxIdx = s.Index
		}
	}
	newIdx := maxIdx + 1

	path := taskPath(projectDir, taskID)
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, fmt.Errorf("ctl: add subtask %s: %w", taskID, err)
	}
	content := string(data)
	if !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	now := strconv.FormatInt(time.Now().Unix(), 10)
	content += fmt.Sprintf("TASK_SUBTASK_%d_TITLE=%s\n", newIdx, description)
	content += fmt.Sprintf("TASK_SUBTASK_%d_STATUS=pending\n", newIdx)
	content += fmt.Sprintf("TASK_SUBTASK_%d_CREATED_AT=%s\n", newIdx, now)
	if err := atomicWrite(path, []byte(content)); err != nil {
		return 0, fmt.Errorf("ctl: add subtask %s: %w", taskID, err)
	}
	return newIdx, nil
}

// UpdateSubtaskStatus updates TASK_SUBTASK_<index>_STATUS (v4 expanded form).
func UpdateSubtaskStatus(projectDir, taskID string, index int, status string) error {
	task, err := ReadTask(projectDir, taskID)
	if err != nil {
		return err
	}

	found := false
	for i := range task.Subtasks {
		if task.Subtasks[i].Index == index {
			found = true
			break
		}
	}
	if !found {
		return fmt.Errorf("ctl: subtask %d not found in task %s", index, taskID)
	}

	return UpdateTaskField(projectDir, taskID, fmt.Sprintf("TASK_SUBTASK_%d_STATUS", index), status)
}

// AddDecision appends a timestamped entry to the decision log.
func AddDecision(projectDir, taskID, decision string) error {
	task, err := ReadTask(projectDir, taskID)
	if err != nil {
		return err
	}

	now := strconv.FormatInt(time.Now().Unix(), 10)
	entry := now + ":" + decision
	var newLog string
	if task.DecisionLog == "" {
		newLog = entry
	} else {
		newLog = task.DecisionLog + `\n` + entry
	}

	return UpdateTaskField(projectDir, taskID, FieldTaskDecisionLog, newLog)
}

// ListTasks reads all .task files in the project's task directory.
func ListTasks(projectDir string) ([]TaskEntry, error) {
	pattern := filepath.Join(projectDir, TaskDir, "*"+TaskExt)
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return nil, fmt.Errorf("ctl: list tasks: %w", err)
	}

	var tasks []TaskEntry
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		t, err := parseTask(string(data))
		if err != nil {
			continue
		}
		tasks = append(tasks, *t)
	}
	return tasks, nil
}

// readNextID reads the .next_id file, returning "1" if it doesn't exist.
func readNextID(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "1", nil
		}
		return "", fmt.Errorf("ctl: read .next_id: %w", err)
	}
	return strings.TrimSpace(string(data)), nil
}

// replaceField replaces an existing KEY=... line or appends it.
func replaceField(content, field, value string) string {
	prefix := field + "="
	lines := strings.Split(content, "\n")
	found := false
	for i, line := range lines {
		if strings.HasPrefix(line, prefix) {
			lines[i] = prefix + value
			if !found {
				found = true
			}
			// Replace the last occurrence to handle duplicates.
		}
	}
	if !found {
		// Insert before the last empty line if present.
		lines = append(lines, prefix+value)
	}
	return strings.Join(lines, "\n")
}

// generateShortname derives a URL-friendly short name from a task title.
func generateShortname(title string) string {
	s := strings.ToLower(title)
	s = strings.ReplaceAll(s, " ", "-")
	s = strings.ReplaceAll(s, "_", "-")
	var buf strings.Builder
	for _, c := range s {
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' {
			buf.WriteRune(c)
		}
	}
	s = buf.String()
	for _, w := range []string{"-the-", "-a-", "-an-", "-to-", "-for-", "-and-", "-in-", "-of-", "-with-"} {
		s = strings.ReplaceAll(s, w, "-")
	}
	for strings.Contains(s, "--") {
		s = strings.ReplaceAll(s, "--", "-")
	}
	s = strings.Trim(s, "-")
	if len(s) > 16 {
		s = s[:16]
	}
	s = strings.TrimRight(s, "-")
	return s
}

// atomicWrite writes data to a temp file then renames it into place.
func atomicWrite(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return fmt.Errorf("ctl: atomic write temp: %w", err)
	}
	tmpName := tmp.Name()

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return fmt.Errorf("ctl: atomic write: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return fmt.Errorf("ctl: atomic write close: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		os.Remove(tmpName)
		return fmt.Errorf("ctl: atomic rename: %w", err)
	}
	return nil
}
