package runtime

import (
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// AggregateHeartbeats produces per-task live state from an existing Snapshot.
// It does not re-read any files — all data comes from the snapshot's Panes,
// Tasks, Subtasks, and Results maps.
func AggregateHeartbeats(snap Snapshot) map[string]HeartbeatState {
	now := time.Now()
	out := make(map[string]HeartbeatState, len(snap.Tasks))

	// Index: task ID → panes working on it (from status files' TASK field)
	taskPanes := make(map[string][]PaneStatus)
	for _, ps := range snap.Panes {
		if ps.Task != "" && (ps.Status == "BUSY" || ps.Status == "WORKING") {
			taskPanes[ps.Task] = append(taskPanes[ps.Task], ps)
		}
	}

	// Index: task ID → subtask stats
	type subStats struct{ done, total int }
	subtaskCounts := make(map[string]subStats)
	for _, st := range snap.Subtasks {
		s := subtaskCounts[st.TaskID]
		s.total++
		if st.Status == "done" {
			s.done++
		}
		subtaskCounts[st.TaskID] = s
	}

	for _, task := range snap.Tasks {
		if task.Status == "done" || task.Status == "cancelled" {
			continue
		}

		hs := HeartbeatState{}

		// Active workers
		panes := taskPanes[task.ID]
		hs.ActiveWorkers = len(panes)

		// Last activity from pane timestamps
		var latestPaneTime time.Time
		var latestPane PaneStatus
		for _, ps := range panes {
			t := parseUpdatedTime(ps.Updated)
			if t.After(latestPaneTime) {
				latestPaneTime = t
				latestPane = ps
			}
		}

		// Last activity from task logs
		var latestLogTime time.Time
		var latestLogEntry string
		if len(task.Logs) > 0 {
			last := task.Logs[len(task.Logs)-1]
			latestLogTime = time.Unix(last.Timestamp, 0)
			latestLogEntry = last.Entry
		}

		// Pick the most recent activity source
		if latestPaneTime.After(latestLogTime) {
			hs.LastActivity = latestPaneTime
		} else {
			hs.LastActivity = latestLogTime
		}

		// Activity text: describe what the most active worker is doing
		if latestPane.Pane != "" {
			hs.ActivityText = buildActivityText(latestPane, snap.Results)
		} else if latestLogEntry != "" {
			hs.ActivityText = truncate(latestLogEntry, 60)
		}

		// Health based on staleness
		hs.Health = computeHealth(now, hs.LastActivity, hs.ActiveWorkers)

		// Progress from subtasks
		if ss, ok := subtaskCounts[task.ID]; ok && ss.total > 0 {
			hs.ProgressText = fmt.Sprintf("%d/%d subtasks done", ss.done, ss.total)
		}

		// Latest finding from task log
		if latestLogEntry != "" {
			hs.LatestFinding = truncate(latestLogEntry, 80)
		}

		out[task.ID] = hs
	}

	return out
}

// buildActivityText creates a human-readable description of what a pane is doing.
func buildActivityText(ps PaneStatus, results map[string]PaneResult) string {
	short := shortenPane(ps.Pane)

	// Check if we have a result with file info
	if res, ok := results[ps.Pane]; ok {
		if len(res.FilesChanged) > 0 {
			lastFile := filepath.Base(res.FilesChanged[len(res.FilesChanged)-1])
			return fmt.Sprintf("%s editing %s", short, lastFile)
		}
		if res.ToolCalls > 0 {
			return fmt.Sprintf("%s working (%d tools)", short, res.ToolCalls)
		}
	}

	if ps.Task != "" {
		return fmt.Sprintf("%s on %s", short, truncate(ps.Task, 40))
	}
	return fmt.Sprintf("%s busy", short)
}

// computeHealth returns green/amber/red based on time since last activity.
// Tasks with no active workers get "red" if stale, "amber" if idle but recent.
func computeHealth(now, lastActivity time.Time, activeWorkers int) string {
	if lastActivity.IsZero() {
		if activeWorkers > 0 {
			return "amber"
		}
		return "red"
	}
	elapsed := now.Sub(lastActivity)
	switch {
	case elapsed < 30*time.Second:
		return "green"
	case elapsed < 60*time.Second:
		return "amber"
	default:
		return "red"
	}
}

// parseUpdatedTime parses the UPDATED field from status files.
// Supports unix epoch (integer) and RFC3339 formats.
func parseUpdatedTime(s string) time.Time {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}
	}
	// Try unix epoch first (most common in Doey status files)
	if epoch, err := strconv.ParseInt(s, 10, 64); err == nil {
		return time.Unix(epoch, 0)
	}
	// Try RFC3339
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t
	}
	return time.Time{}
}

// shortenPane turns "doey-doey:2.1" into "W2.1".
func shortenPane(pane string) string {
	// Find the window.pane part after ":"
	if idx := strings.LastIndex(pane, ":"); idx >= 0 {
		return "W" + pane[idx+1:]
	}
	return pane
}

// truncate shortens a string to maxLen, adding "…" if truncated.
func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	if maxLen < 4 {
		return s[:maxLen]
	}
	return s[:maxLen-1] + "…"
}
