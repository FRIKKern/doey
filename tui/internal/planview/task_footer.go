// Task wiring footer — Phase 8 of masterplan-20260426-203854 (Track A).
//
// Surfaces the task linked to the active plan: ID, title, status, the
// subtask roll-up (N/M done), the current phase label (when the phase
// in focus has its own task linkage in the SQLite plans table), and the
// age of the most recent .task file mutation. The .task file is treated
// as authoritative — the SQLite plans table is consulted only when the
// file is missing so the footer always reflects the latest on-disk
// state without polling.
package planview

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/store"
)

// LoadTaskFooter resolves the TaskFooter for the active plan from disk.
//
//	projectDir — repo root containing .doey/. Empty falls back to cwd.
//	taskID     — preferred task id (typically $DOEY_TASK_ID); when empty
//	             the function still returns a zero-value footer so the
//	             renderer can show a "no task linkage" state.
//
// Lookup order:
//  1. .doey/tasks/<taskID>.task — file authoritative for title/status/
//     subtask totals and last-change age (file mtime).
//  2. SQLite store at .doey/doey.db — used as a fallback for title/
//     status when the file is missing or unparseable. Subtask roll-up
//     is *not* derived from the DB (the file is the only source of
//     subtask granularity); a missing file leaves SubtaskDone/Total = 0.
//
// Soft-fails on every step: a missing project dir, an unreadable file,
// or a missing DB all yield a partially-populated TaskFooter rather
// than an error. The renderer copes with empty fields.
func LoadTaskFooter(projectDir, taskID string) TaskFooter {
	t := TaskFooter{TaskID: taskID}
	if t.TaskID == "" {
		return t
	}
	if projectDir == "" {
		if cwd, err := os.Getwd(); err == nil {
			projectDir = cwd
		}
	}
	if projectDir == "" {
		return t
	}
	taskPath := filepath.Join(projectDir, ".doey", "tasks", t.TaskID+".task")
	if env, mtime, ok := readTaskEnvFile(taskPath); ok {
		t.Title = env["TASK_TITLE"]
		t.Status = env["TASK_STATUS"]
		t.LastChangeAge = time.Since(mtime)
		done, total := countSubtaskRollup(env)
		t.SubtaskDone = done
		t.SubtaskTotal = total
		t.CurrentPhase = resolveCurrentPhase(env, projectDir)
		return t
	}
	// File missing — fall back to SQLite plans table for title/status
	// only. The plans table joins task_id → plan_id, so we look up by
	// task_id when available. Soft-fail on every error.
	dbPath := filepath.Join(projectDir, ".doey", "doey.db")
	if s, err := store.Open(dbPath); err == nil {
		defer s.Close()
		if id, parseErr := strconv.ParseInt(t.TaskID, 10, 64); parseErr == nil {
			if plans, listErr := s.ListPlans(); listErr == nil {
				for _, p := range plans {
					if p.TaskID != nil && *p.TaskID == id {
						if t.Title == "" {
							t.Title = p.Title
						}
						if t.Status == "" {
							t.Status = p.Status
						}
						break
					}
				}
			}
		}
	}
	return t
}

// readTaskEnvFile parses a .task file (shell-style KEY=VALUE) and
// returns the populated map, the file mtime, and ok=false when the file
// is missing or unreadable. Tolerates `export ` prefix, surrounding
// quotes, blank lines, and comments — same dialect as parseTeamEnv in
// main.go and loadFixtureEnv in fixtures.go.
func readTaskEnvFile(path string) (map[string]string, time.Time, bool) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, time.Time{}, false
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, time.Time{}, false
	}
	defer f.Close()
	out := map[string]string{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 4096), 1<<20)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		val = strings.Trim(val, `"'`)
		out[key] = val
	}
	return out, st.ModTime(), true
}

// countSubtaskRollup walks the TASK_SUBTASK_<N>_STATUS keys and returns
// (done, total). Recognised statuses: "done", "completed", "complete"
// count as done; everything non-empty (including in_progress, pending)
// counts only against the total. The maximum index is bounded at 64 to
// avoid scanning a pathologically large map.
func countSubtaskRollup(env map[string]string) (done, total int) {
	for i := 1; i <= 64; i++ {
		key := fmt.Sprintf("TASK_SUBTASK_%d_STATUS", i)
		val, ok := env[key]
		if !ok {
			continue
		}
		val = strings.ToLower(strings.TrimSpace(val))
		if val == "" {
			continue
		}
		total++
		switch val {
		case "done", "completed", "complete":
			done++
		}
	}
	return done, total
}

// resolveCurrentPhase derives the human-readable label of the phase
// currently in focus on the linked task. The .task file stores
// TASK_CURRENT_PHASE as an integer index; if the corresponding phase
// has its own linked task in the SQLite plans table, the phase label
// comes from that plan's title. Falls back to the TASK_PHASE string
// (free-form label) and finally to "" so the renderer can hide the
// pillar when no phase information is available.
func resolveCurrentPhase(env map[string]string, projectDir string) string {
	phaseIdx := strings.TrimSpace(env["TASK_CURRENT_PHASE"])
	phaseLabel := strings.TrimSpace(env["TASK_PHASE"])
	planID := strings.TrimSpace(env["TASK_PLAN_ID"])

	if phaseIdx == "" || phaseIdx == "0" {
		return phaseLabel
	}
	idx, err := strconv.Atoi(phaseIdx)
	if err != nil || idx <= 0 {
		return phaseLabel
	}
	if planID == "" || projectDir == "" {
		if phaseLabel != "" {
			return phaseLabel + " (phase " + phaseIdx + ")"
		}
		return "phase " + phaseIdx
	}
	dbPath := filepath.Join(projectDir, ".doey", "doey.db")
	s, err := store.Open(dbPath)
	if err != nil {
		if phaseLabel != "" {
			return phaseLabel + " (phase " + phaseIdx + ")"
		}
		return "phase " + phaseIdx
	}
	defer s.Close()
	id, err := strconv.ParseInt(planID, 10, 64)
	if err != nil {
		return phaseLabel
	}
	plan, err := s.GetPlan(id)
	if err != nil || plan == nil {
		if phaseLabel != "" {
			return phaseLabel + " (phase " + phaseIdx + ")"
		}
		return "phase " + phaseIdx
	}
	return plan.Title + " · phase " + phaseIdx
}

// RenderTaskFooter returns the compact one-line footer summarising the
// active task. Empty when no task is linked (TaskID == ""). The line is
// composed of:
//
//	task #<id> · <title> · <status> · <N>/<M> done · phase <label> · age <h>
//
// Sections are dropped individually when their value is empty so a
// freshly-launched task without subtasks doesn't display "0/0 done".
//
// width is the available column count; the helper truncates the title
// when needed but never wraps — the renderer expects a single visual
// line so the footer band height stays stable across snapshots.
func RenderTaskFooter(t TaskFooter, width int) string {
	if strings.TrimSpace(t.TaskID) == "" {
		return ""
	}
	if width < 20 {
		width = 20
	}
	parts := make([]string, 0, 6)
	parts = append(parts, taskFooterIDStyle.Render("task #"+t.TaskID))

	if title := strings.TrimSpace(t.Title); title != "" {
		// Reserve 30 cells for the other meta blocks so the title
		// doesn't shove them off-screen on a narrow viewport.
		titleBudget := width - 30
		if titleBudget < 12 {
			titleBudget = 12
		}
		parts = append(parts, taskFooterTitleStyle.Render(truncate(title, titleBudget)))
	}
	if status := strings.TrimSpace(t.Status); status != "" {
		parts = append(parts, taskFooterStatusStyle.Render(strings.ToLower(status)))
	}
	if t.SubtaskTotal > 0 {
		parts = append(parts,
			taskFooterMetaStyle.Render(fmt.Sprintf("%d/%d done", t.SubtaskDone, t.SubtaskTotal)))
	}
	if phase := strings.TrimSpace(t.CurrentPhase); phase != "" {
		parts = append(parts,
			taskFooterMetaStyle.Render("phase "+truncate(phase, 24)))
	}
	if t.LastChangeAge > 0 {
		parts = append(parts,
			taskFooterMetaStyle.Render("·"+formatAge(t.LastChangeAge)))
	}
	return strings.Join(parts, " · ")
}

var (
	taskFooterIDStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#0f172a", Dark: "#e2e8f0"}).
				Bold(true)
	taskFooterTitleStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#1e293b", Dark: "#e2e8f0"})
	taskFooterStatusStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#2563eb", Dark: "#60a5fa"}).
				Bold(true)
	taskFooterMetaStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#64748b", Dark: "#94a3b8"}).
				Faint(true)
)
