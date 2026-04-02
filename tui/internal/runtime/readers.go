package runtime

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/doey-cli/doey/tui/internal/store"
)

// ReadPaneStatuses reads pane statuses. If projectDir is provided, tries the
// SQLite store first and falls back to file-based parsing.
func ReadPaneStatuses(runtimeDir string, projectDir ...string) []PaneStatus {
	// Try store first
	if len(projectDir) > 0 && projectDir[0] != "" {
		if statuses, ok := readPaneStatusesFromStore(projectDir[0]); ok {
			return statuses
		}
	}

	// Fall back to file parsing
	return readPaneStatusesFromFiles(runtimeDir)
}

func readPaneStatusesFromStore(projectDir string) ([]PaneStatus, bool) {
	dbPath := filepath.Join(projectDir, ".doey", "doey.db")
	s, err := store.Open(dbPath)
	if err != nil {
		return nil, false
	}
	defer s.Close()

	// List all pane statuses across all windows
	rows, err := s.DB().Query(
		`SELECT pane_id, window_id, role, status, task_id, task_title, agent, updated_at FROM pane_status ORDER BY pane_id`,
	)
	if err != nil {
		return nil, false
	}
	defer rows.Close()

	var result []PaneStatus
	for rows.Next() {
		var sp store.PaneStatus
		if err := rows.Scan(&sp.PaneID, &sp.WindowID, &sp.Role, &sp.Status, &sp.TaskID, &sp.TaskTitle, &sp.Agent, &sp.UpdatedAt); err != nil {
			return nil, false
		}
		ps := PaneStatus{
			Pane:    sp.PaneID,
			Status:  sp.Status,
			Task:    sp.TaskTitle,
			Updated: fmt.Sprintf("%d", sp.UpdatedAt),
		}
		if dotIdx := strings.IndexByte(ps.Pane, '.'); dotIdx >= 0 {
			ps.WindowIdx, _ = strconv.Atoi(ps.Pane[:dotIdx])
			ps.PaneIdx, _ = strconv.Atoi(ps.Pane[dotIdx+1:])
		}
		result = append(result, ps)
	}
	if rows.Err() != nil || len(result) == 0 {
		return nil, false
	}
	return result, true
}

func readPaneStatusesFromFiles(runtimeDir string) []PaneStatus {
	var result []PaneStatus
	statusDir := filepath.Join(runtimeDir, "status")

	matches, err := filepath.Glob(filepath.Join(statusDir, "*.status"))
	if err != nil || len(matches) == 0 {
		return result
	}

	for _, path := range matches {
		base := strings.TrimSuffix(filepath.Base(path), ".status")
		ps := PaneStatus{Pane: underscoreToPaneID(base)}

		// Extract WindowIdx and PaneIdx from pane ID (e.g. "2.1")
		if dotIdx := strings.IndexByte(ps.Pane, '.'); dotIdx >= 0 {
			ps.WindowIdx, _ = strconv.Atoi(ps.Pane[:dotIdx])
			ps.PaneIdx, _ = strconv.Atoi(ps.Pane[dotIdx+1:])
		}

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

		result = append(result, ps)
	}

	return result
}

// ReadResults reads all result JSON files from runtimeDir/results/.
// Uses json.Unmarshal into WorkerResult (alias for PaneResult).
func ReadResults(runtimeDir string) []WorkerResult {
	var results []WorkerResult
	resultsDir := filepath.Join(runtimeDir, "results")

	matches, err := filepath.Glob(filepath.Join(resultsDir, "pane_*.json"))
	if err != nil || len(matches) == 0 {
		return results
	}

	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var wr WorkerResult
		if err := json.Unmarshal(data, &wr); err != nil {
			continue
		}
		if wr.Pane == "" {
			base := strings.TrimSuffix(filepath.Base(path), ".json")
			wr.Pane = underscoreToPaneID(base)
		}
		results = append(results, wr)
	}

	// Sort by timestamp descending (newest first)
	sort.Slice(results, func(i, j int) bool {
		return results[i].Timestamp > results[j].Timestamp
	})

	return results
}

// ReadRecentMessages reads messages. If projectDir is provided, tries the
// SQLite store first and falls back to file-based parsing.
// Returns most recent `limit` messages, sorted newest first.
func ReadRecentMessages(runtimeDir string, limit int, projectDir ...string) []Message {
	// Try store first
	if len(projectDir) > 0 && projectDir[0] != "" {
		if msgs, ok := readRecentMessagesFromStore(projectDir[0], limit); ok {
			return msgs
		}
	}

	// Fall back to file parsing
	return readRecentMessagesFromFiles(runtimeDir, limit)
}

func readRecentMessagesFromStore(projectDir string, limit int) ([]Message, bool) {
	dbPath := filepath.Join(projectDir, ".doey", "doey.db")
	s, err := store.Open(dbPath)
	if err != nil {
		return nil, false
	}
	defer s.Close()

	if limit <= 0 {
		limit = 100
	}

	// Query recent messages across all panes
	rows, err := s.DB().Query(
		`SELECT id, from_pane, to_pane, subject, body, created_at FROM messages ORDER BY created_at DESC LIMIT ?`, limit,
	)
	if err != nil {
		return nil, false
	}
	defer rows.Close()

	var msgs []Message
	for rows.Next() {
		var id int64
		var from, to, subject, body string
		var createdAt int64
		if err := rows.Scan(&id, &from, &to, &subject, &body, &createdAt); err != nil {
			return nil, false
		}
		msgs = append(msgs, Message{
			ID:        fmt.Sprintf("%d", id),
			From:      from,
			To:        to,
			Subject:   subject,
			Body:      body,
			Timestamp: createdAt,
		})
	}
	if rows.Err() != nil || len(msgs) == 0 {
		return nil, false
	}
	return msgs, true
}

func readRecentMessagesFromFiles(runtimeDir string, limit int) []Message {
	var msgs []Message

	matches, _ := filepath.Glob(filepath.Join(runtimeDir, "messages", "*.msg"))
	for _, path := range matches {
		base := filepath.Base(path)
		if strings.HasSuffix(base, ".msg.tmp") {
			continue
		}

		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}

		// Parse filename: <target_safe>_<unix_timestamp>_<pid>.msg
		nameNoExt := strings.TrimSuffix(base, ".msg")
		parts := strings.Split(nameNoExt, "_")

		var ts int64
		if len(parts) >= 3 {
			tsIdx := len(parts) - 2
			ts, _ = strconv.ParseInt(parts[tsIdx], 10, 64)
			if ts == 0 {
				pidIdx := len(parts) - 1
				ts, _ = strconv.ParseInt(parts[pidIdx], 10, 64)
			}
		}

		content := string(data)
		from, subject, body := parseMessageContent(content)

		msgs = append(msgs, Message{
			From:      from,
			Subject:   subject,
			Body:      body,
			Timestamp: ts,
			Filename:  base,
		})
	}

	// Sort newest first
	sort.Slice(msgs, func(i, j int) bool {
		return msgs[i].Timestamp > msgs[j].Timestamp
	})

	// Apply limit
	if limit > 0 && len(msgs) > limit {
		msgs = msgs[:limit]
	}

	return msgs
}

// ReadTaskLogs parses task log entries. If projectDir and taskID are provided,
// tries the SQLite store first and falls back to .task file parsing.
// taskFile is always the path to the .task file (used for file fallback).
func ReadTaskLogs(taskFile string, storeArgs ...string) []LogEntry {
	// Try store: storeArgs[0]=projectDir, storeArgs[1]=taskID
	if len(storeArgs) >= 2 && storeArgs[0] != "" && storeArgs[1] != "" {
		if logs, ok := readTaskLogsFromStore(storeArgs[0], storeArgs[1]); ok {
			return logs
		}
	}

	// Fall back to file parsing
	return readTaskLogsFromFile(taskFile)
}

func readTaskLogsFromStore(projectDir, taskIDStr string) ([]LogEntry, bool) {
	taskID, err := strconv.ParseInt(taskIDStr, 10, 64)
	if err != nil {
		return nil, false
	}

	dbPath := filepath.Join(projectDir, ".doey", "doey.db")
	s, err := store.Open(dbPath)
	if err != nil {
		return nil, false
	}
	defer s.Close()

	entries, err := s.ListTaskLog(taskID)
	if err != nil || len(entries) == 0 {
		return nil, false
	}

	var logs []LogEntry
	for _, e := range entries {
		logs = append(logs, LogEntry{
			Timestamp: fmt.Sprintf("%d", e.CreatedAt),
			Action:    e.Type,
			Detail:    e.Title,
		})
	}
	return logs, true
}

func readTaskLogsFromFile(taskFile string) []LogEntry {
	var logs []LogEntry

	env, err := parseEnvFile(taskFile)
	if err != nil {
		return logs
	}

	for key, val := range env {
		if !strings.HasPrefix(key, "TASK_LOG_") {
			continue
		}
		tsStr := strings.TrimPrefix(key, "TASK_LOG_")

		// Value format: "timestamp|action|detail" or just plain text
		parts := strings.SplitN(val, "|", 3)
		entry := LogEntry{Timestamp: tsStr}
		switch len(parts) {
		case 3:
			entry.Timestamp = parts[0]
			entry.Action = parts[1]
			entry.Detail = parts[2]
		case 2:
			entry.Action = parts[0]
			entry.Detail = parts[1]
		default:
			entry.Detail = val
		}
		logs = append(logs, entry)
	}

	// Sort by timestamp
	sort.Slice(logs, func(i, j int) bool {
		return logs[i].Timestamp < logs[j].Timestamp
	})

	return logs
}
