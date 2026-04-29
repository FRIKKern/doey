package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Task files live at <project>/.doey/tasks/<id>.task and are KEY=VALUE
// (shell-style) — NOT JSON. Some keys repeat with numeric suffixes
// (TASK_SUBTASK_<n>_*, TASK_DECISION_<n>_*, TASK_NOTE_<n>_*).

type taskSummary struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	Status       string `json:"status"`
	Type         string `json:"type"`
	AssignedTo   string `json:"assigned_to"`
	Team         string `json:"team,omitempty"`
	CurrentPhase string `json:"current_phase,omitempty"`
	CreatedAt    int64  `json:"created_at,omitempty"`
	Updated      int64  `json:"updated,omitempty"`
}

type tasksListArgs struct {
	Status     string `json:"status"`
	AssignedTo string `json:"assigned_to"`
	Limit      int    `json:"limit"`
}

func tasksListHandler(_ context.Context, raw json.RawMessage) (any, error) {
	args := tasksListArgs{Limit: 100}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("invalid arguments: %w", err)
		}
	}
	if args.Limit <= 0 {
		args.Limit = 100
	}
	if args.Limit > 500 {
		args.Limit = 500
	}

	dir := filepath.Join(projectDir(), ".doey", "tasks")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read tasks dir: %w", err)
	}

	var tasks []taskSummary
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".task") {
			continue
		}
		fields, err := parseKVFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		s := taskSummary{
			ID:           fields["TASK_ID"],
			Title:        fields["TASK_TITLE"],
			Status:       fields["TASK_STATUS"],
			Type:         fields["TASK_TYPE"],
			AssignedTo:   fields["TASK_ASSIGNED_TO"],
			Team:         fields["TASK_TEAM"],
			CurrentPhase: fields["TASK_CURRENT_PHASE"],
			CreatedAt:    parseTimestampField(fields["TASK_TIMESTAMPS"], "created"),
			Updated:      atoi64(fields["TASK_UPDATED"]),
		}
		if s.ID == "" {
			// Fall back to filename stem when the file is corrupt.
			s.ID = strings.TrimSuffix(e.Name(), ".task")
		}
		if args.Status != "" && !strings.EqualFold(s.Status, args.Status) {
			continue
		}
		if args.AssignedTo != "" && !strings.EqualFold(s.AssignedTo, args.AssignedTo) {
			continue
		}
		tasks = append(tasks, s)
	}

	// Sort by numeric id descending (newest first), ties on lexical id.
	sort.Slice(tasks, func(i, j int) bool {
		ai, _ := strconv.Atoi(tasks[i].ID)
		aj, _ := strconv.Atoi(tasks[j].ID)
		if ai != aj {
			return ai > aj
		}
		return tasks[i].ID > tasks[j].ID
	})

	if len(tasks) > args.Limit {
		tasks = tasks[:args.Limit]
	}

	return map[string]any{
		"count": len(tasks),
		"tasks": tasks,
	}, nil
}

type taskGetArgs struct {
	TaskID string `json:"task_id"`
}

func taskGetHandler(_ context.Context, raw json.RawMessage) (any, error) {
	var args taskGetArgs
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("invalid arguments: %w", err)
		}
	}
	args.TaskID = strings.TrimSpace(args.TaskID)
	if args.TaskID == "" {
		return nil, fmt.Errorf("task_id is required")
	}
	if !isSafeID(args.TaskID) {
		return nil, fmt.Errorf("invalid task_id: %q", args.TaskID)
	}

	path := filepath.Join(projectDir(), ".doey", "tasks", args.TaskID+".task")
	fields, err := parseKVFile(path)
	if err != nil {
		return nil, fmt.Errorf("read task %s: %w", args.TaskID, err)
	}

	subtasks := collectIndexed(fields, "TASK_SUBTASK_")
	decisions := collectIndexed(fields, "TASK_DECISION_")
	notes := collectIndexed(fields, "TASK_NOTE_")
	logEntries := collectIndexed(fields, "TASK_LOG_")

	// Build the bare-fields map without the indexed groups so callers can see
	// scalar fields in one place.
	scalars := make(map[string]string, len(fields))
	for k, v := range fields {
		if strings.HasPrefix(k, "TASK_SUBTASK_") ||
			strings.HasPrefix(k, "TASK_DECISION_") ||
			strings.HasPrefix(k, "TASK_NOTE_") ||
			strings.HasPrefix(k, "TASK_LOG_") {
			continue
		}
		scalars[k] = v
	}

	return map[string]any{
		"task_id":   args.TaskID,
		"path":      path,
		"fields":    scalars,
		"subtasks":  subtasks,
		"decisions": decisions,
		"notes":     notes,
		"log":       logEntries,
	}, nil
}

// collectIndexed gathers `<prefix><n>_<key>=value` lines into an ordered
// list of {index, key, value} groups, keyed by the numeric index.
func collectIndexed(fields map[string]string, prefix string) []map[string]any {
	groups := make(map[int]map[string]string)
	for k, v := range fields {
		if !strings.HasPrefix(k, prefix) {
			continue
		}
		rest := strings.TrimPrefix(k, prefix)
		// rest looks like "1_TITLE" or "2_STATUS" or "1" (rare).
		parts := strings.SplitN(rest, "_", 2)
		idx, err := strconv.Atoi(parts[0])
		if err != nil {
			continue
		}
		key := "value"
		if len(parts) == 2 {
			key = parts[1]
		}
		if _, ok := groups[idx]; !ok {
			groups[idx] = make(map[string]string)
		}
		groups[idx][key] = v
	}

	indices := make([]int, 0, len(groups))
	for i := range groups {
		indices = append(indices, i)
	}
	sort.Ints(indices)

	out := make([]map[string]any, 0, len(indices))
	for _, i := range indices {
		entry := map[string]any{"index": i}
		for k, v := range groups[i] {
			entry[strings.ToLower(k)] = v
		}
		out = append(out, entry)
	}
	return out
}

// parseKVFile parses a shell-style KEY=VALUE file. Lines beginning with #,
// blank lines, and lines without "=" are skipped. Quotes around the value
// are stripped if balanced.
func parseKVFile(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	out := make(map[string]string)
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimRight(line, "\r")
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := line[eq+1:]
		val = stripPairedQuotes(val)
		out[key] = val
	}
	return out, nil
}

func stripPairedQuotes(s string) string {
	if len(s) >= 2 {
		if (s[0] == '"' && s[len(s)-1] == '"') || (s[0] == '\'' && s[len(s)-1] == '\'') {
			return s[1 : len(s)-1]
		}
	}
	return s
}

func parseTimestampField(s, key string) int64 {
	if s == "" {
		return 0
	}
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if !strings.HasPrefix(part, key+"=") {
			continue
		}
		return atoi64(strings.TrimPrefix(part, key+"="))
	}
	return 0
}

func atoi64(s string) int64 {
	if s == "" {
		return 0
	}
	n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return n
}

// isSafeID rejects path-traversal attempts. Task ids are short and
// alphanumeric (often pure digits) — anything with a slash, dot, or backslash
// is suspicious.
func isSafeID(id string) bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for _, r := range id {
		if r == '/' || r == '\\' || r == '.' || r == 0 {
			return false
		}
	}
	return true
}
