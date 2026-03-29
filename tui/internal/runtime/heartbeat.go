package runtime

import (
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Health state constants for HeartbeatState.Health.
const (
	HealthHealthy  = "healthy"  // green — last update <30s ago
	HealthDegraded = "degraded" // yellow — 30-120s ago
	HealthStale    = "stale"    // red — >120s ago
	HealthIdle     = "idle"     // gray — no activity at all
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

	// Index: pane → result (for tool call / file progress)
	// (snap.Results is already keyed by pane ID)

	for _, task := range snap.Tasks {
		if task.Status == "done" || task.Status == "cancelled" {
			continue
		}

		hs := HeartbeatState{}

		// Active workers and their names
		panes := taskPanes[task.ID]
		hs.ActiveWorkers = len(panes)
		hs.SpinnerActive = len(panes) > 0

		var workerNames []string
		for _, ps := range panes {
			workerNames = append(workerNames, shortenPane(ps.Pane))
		}
		hs.ActiveWorkerNames = workerNames

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

		// Health state based on staleness
		hs.Health = healthFromAge(now.Sub(hs.LastActivity), hs.ActiveWorkers, hs.LastActivity.IsZero())
		hs.HealthSince = hs.LastActivity // approximate: health started when last activity occurred

		// Activity text: describe what the most active worker is doing
		if latestPane.Pane != "" {
			hs.ActivityText = buildActivityText(latestPane, snap.Results)
		} else if latestLogEntry != "" {
			hs.ActivityText = truncate(latestLogEntry, 60)
		}

		// Extract last tool call and progress from result files for active panes
		hs.LastToolCall, hs.ProgressPercent = extractResultProgress(panes, snap.Results)

		// Progress text from subtasks
		if ss, ok := subtaskCounts[task.ID]; ok && ss.total > 0 {
			hs.ProgressText = fmt.Sprintf("%d/%d subtasks done", ss.done, ss.total)
			// Use subtask ratio for progress percent if we have subtasks
			hs.ProgressPercent = float64(ss.done) / float64(ss.total)
		}

		// Latest finding from task log
		if latestLogEntry != "" {
			hs.LatestFinding = truncate(latestLogEntry, 80)
		}

		out[task.ID] = hs
	}

	return out
}

// healthFromAge returns a health state string based on time since last activity.
func healthFromAge(age time.Duration, activeWorkers int, noActivity bool) string {
	if noActivity {
		if activeWorkers > 0 {
			return HealthDegraded
		}
		return HealthIdle
	}
	switch {
	case age < 30*time.Second:
		return HealthHealthy
	case age < 120*time.Second:
		return HealthDegraded
	default:
		return HealthStale
	}
}

// parseActivityFromStatus extracts a readable activity description from a PaneStatus.
func parseActivityFromStatus(ps PaneStatus) string {
	short := shortenPane(ps.Pane)
	if ps.Task != "" {
		return fmt.Sprintf("%s on %s", short, truncate(ps.Task, 40))
	}
	if ps.Status == "BUSY" || ps.Status == "WORKING" {
		return fmt.Sprintf("%s busy", short)
	}
	return short + " " + strings.ToLower(ps.Status)
}

// formatTimeSince returns a human-readable relative time string.
func formatTimeSince(t time.Time) string {
	if t.IsZero() {
		return "no activity"
	}
	elapsed := time.Since(t)
	if elapsed < 5*time.Second {
		return "active now"
	}
	if elapsed < time.Minute {
		return fmt.Sprintf("%ds ago", int(elapsed.Seconds()))
	}
	if elapsed < time.Hour {
		return fmt.Sprintf("%dm ago", int(elapsed.Minutes()))
	}
	return fmt.Sprintf("%dh ago", int(elapsed.Hours()))
}

// extractResultProgress scans result files for active panes to find the latest
// tool call name and an estimated progress percentage from files changed.
func extractResultProgress(panes []PaneStatus, results map[string]PaneResult) (lastTool string, progress float64) {
	var latestTS int64
	var totalTools int
	var totalFiles int

	for _, ps := range panes {
		res, ok := results[ps.Pane]
		if !ok {
			continue
		}
		totalTools += res.ToolCalls
		totalFiles += len(res.FilesChanged)

		if res.Timestamp > latestTS {
			latestTS = res.Timestamp
			// Derive last tool hint from files changed or status
			if len(res.FilesChanged) > 0 {
				lastTool = "editing " + filepath.Base(res.FilesChanged[len(res.FilesChanged)-1])
			} else if res.ToolCalls > 0 {
				lastTool = fmt.Sprintf("%d tool calls", res.ToolCalls)
			}
		}
	}

	// No reliable total to compute percentage from result files alone;
	// callers should prefer subtask-based progress when available.
	return lastTool, 0
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

	return parseActivityFromStatus(ps)
}

// computeHealth returns green/amber/red based on time since last activity.
// Retained for backward compatibility; new code should use healthFromAge.
func computeHealth(now, lastActivity time.Time, activeWorkers int) string {
	h := healthFromAge(now.Sub(lastActivity), activeWorkers, lastActivity.IsZero())
	// Map new states to legacy color names for any callers using old API
	switch h {
	case HealthHealthy:
		return "green"
	case HealthDegraded:
		return "amber"
	case HealthStale:
		return "red"
	case HealthIdle:
		return "red"
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
