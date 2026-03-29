package runtime

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// ReadPaneStatuses reads all .status files from runtimeDir/status/.
// Parses STATUS:, TASK:, UPDATED: fields. Extracts window/pane indices from filename.
func ReadPaneStatuses(runtimeDir string) []PaneStatus {
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

// ReadRecentMessages reads .msg files from runtimeDir/messages/.
// Parses FROM:, SUBJECT: headers; rest is body. Extracts timestamp from filename.
// Returns most recent `limit` messages, sorted newest first.
func ReadRecentMessages(runtimeDir string, limit int) []Message {
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

// ReadTaskLogs parses TASK_LOG_* entries from a .task file.
// Format: TASK_LOG_N=timestamp|action|detail (or just text)
func ReadTaskLogs(taskFile string) []LogEntry {
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
