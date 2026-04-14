package styles

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"
)

var defaultTheme = DefaultTheme()

// StatusColor returns the adaptive color for a given pane status.
func StatusColor(status string) lipgloss.AdaptiveColor {
	switch status {
	case "READY":
		return defaultTheme.Success
	case "BUSY", "WORKING":
		return defaultTheme.Warning
	case "BOOTING", "RESPAWNING":
		return defaultTheme.Warning
	case "FINISHED":
		return lipgloss.AdaptiveColor{Light: "#2563EB", Dark: "#3B82F6"}
	case "ERROR":
		return defaultTheme.Danger
	case "RESERVED":
		return defaultTheme.Accent
	default:
		return defaultTheme.Muted
	}
}

// StatusText returns status text colored by foreground only — subtle, informational.
func StatusText(status string) string {
	color := StatusColor(status)

	label := status
	if status == "WORKING" {
		label = "BUSY"
	}

	return lipgloss.NewStyle().Foreground(color).Render(label)
}

// StatusBadge returns a styled badge string for the given status.
// Colored text with bold — no background, no solid blocks.
func StatusBadge(status string) string {
	color := StatusColor(status)

	label := status
	if status == "WORKING" {
		label = "BUSY"
	}

	return lipgloss.NewStyle().
		Foreground(color).
		Bold(true).
		Padding(0, 1).
		Render(label)
}

// TeamBadge returns a styled badge for team type indicators.
func TeamBadge(kind string) string {
	switch kind {
	case "freelancer":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Warning).
			Bold(true).
			Render("[F]")
	case "worktree":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Primary).
			Bold(true).
			Render("[wt]")
	default:
		return ""
	}
}

// TaskIcon returns a styled icon for task status.
func TaskIcon(status string, t Theme) string {
	switch status {
	case "active":
		return lipgloss.NewStyle().Foreground(t.Muted).Render("○")
	case "in_progress":
		return lipgloss.NewStyle().Foreground(t.Primary).Render("●")
	case "pending_user_confirmation":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("◉")
	case "done":
		return lipgloss.NewStyle().Foreground(t.Success).Render("✓")
	case "cancelled":
		return lipgloss.NewStyle().Foreground(t.Muted).Render("—")
	case "failed":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("✗")
	case "deferred":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("⏸")
	default:
		return lipgloss.NewStyle().Foreground(t.Muted).Render("·")
	}
}

// CategoryColor returns the adaptive color for a given task category.
func CategoryColor(category string) lipgloss.AdaptiveColor {
	switch category {
	case "bug":
		return defaultTheme.Danger
	case "feature":
		return defaultTheme.Primary
	case "refactor":
		return defaultTheme.Accent
	case "docs":
		return defaultTheme.Success
	case "infrastructure":
		return defaultTheme.Warning
	default:
		return defaultTheme.Muted
	}
}

// CategoryBadge renders a colored category label.
func CategoryBadge(category string) string {
	if category == "" {
		return ""
	}
	color := CategoryColor(category)
	return lipgloss.NewStyle().
		Foreground(color).
		Bold(true).
		Render("[" + category + "]")
}

// TagBadge renders a single tag with muted styling.
func TagBadge(tag string) string {
	if tag == "" {
		return ""
	}
	return lipgloss.NewStyle().
		Foreground(defaultTheme.Muted).
		Render("#" + tag)
}

// SectionPill renders a subtle section header with a diamond prefix.
// No background — just colored marker + dim label text.
func SectionPill(label string, bg lipgloss.AdaptiveColor) string {
	marker := lipgloss.NewStyle().Foreground(bg).Render("◆")
	text := lipgloss.NewStyle().Foreground(defaultTheme.Text).Faint(true).Render(" " + label)
	return marker + text
}

// SubtaskProgress renders a subtask progress indicator in muted style.
// Shows "(done/total)" — dim unless fully complete. If deferred > 0,
// appends an amber-colored deferred indicator: "(done/active ⏸N)".
func SubtaskProgress(done, total, deferred int) string {
	if total == 0 {
		return ""
	}
	active := total - deferred
	label := fmt.Sprintf("(%d/%d)", done, active)
	var ratio string
	if active > 0 && done == active {
		ratio = lipgloss.NewStyle().Foreground(defaultTheme.Success).Faint(true).Render(label)
	} else {
		ratio = lipgloss.NewStyle().Foreground(defaultTheme.Muted).Render(label)
	}
	if deferred > 0 {
		deferredLabel := fmt.Sprintf(" ⏸%d", deferred)
		ratio += lipgloss.NewStyle().Foreground(defaultTheme.Warning).Render(deferredLabel)
	}
	return ratio
}

// LogEventBadge returns a subtle colored label for a log event type.
// Lowercase text with event color — no background, no solid blocks.
func LogEventBadge(theme Theme, eventType string) string {
	var clr lipgloss.AdaptiveColor
	switch eventType {
	case "info":
		clr = theme.Info
		if clr == (lipgloss.AdaptiveColor{}) {
			clr = theme.Primary
		}
	case "warn", "warning":
		clr = theme.Warning
	case "error":
		clr = theme.Danger
	case "task":
		clr = theme.Primary
	case "dispatch":
		clr = theme.Accent
	case "research":
		clr = theme.Success
	case "commit", "git":
		clr = theme.Muted
	default:
		clr = theme.Muted
	}

	label := strings.ToLower(eventType)
	return lipgloss.NewStyle().
		Foreground(clr).
		Padding(0, 1).
		Render(label)
}

// LogStatusIcon returns a colored icon character for a pane status.
func LogStatusIcon(status string, t Theme) string {
	switch status {
	case "BUSY", "WORKING":
		return lipgloss.NewStyle().Foreground(t.Primary).Render("●")
	case "BOOTING", "RESPAWNING":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("◌")
	case "FINISHED":
		return lipgloss.NewStyle().Foreground(t.Success).Render("✓")
	case "ERROR":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("✗")
	default:
		return lipgloss.NewStyle().Foreground(t.Muted).Render("○")
	}
}

// LogTaskBadge renders a task ID as a colored pill badge.
// Returns empty string if taskID is empty.
func LogTaskBadge(taskID string, t Theme) string {
	if taskID == "" {
		return ""
	}
	return lipgloss.NewStyle().
		Background(t.Accent).
		Foreground(t.BgText).
		Padding(0, 1).
		Bold(true).
		Render("#" + taskID)
}

// LogStatusBadge renders a status string as a background-colored pill badge.
func LogStatusBadge(status string, t Theme) string {
	color := StatusAccentColor(t, strings.ToLower(status))
	return lipgloss.NewStyle().
		Background(color).
		Foreground(t.BgText).
		Padding(0, 1).
		Bold(true).
		Render(strings.ToUpper(status))
}

// LogEntryIcon returns an icon for a proof/entry type.
func LogEntryIcon(proofType string, t Theme) string {
	switch proofType {
	case "agent":
		return "◆"
	case "test":
		return "◇"
	case "build":
		return "◆"
	case "manual":
		return "○"
	default:
		return lipgloss.NewStyle().Foreground(t.Muted).Render("◆")
	}
}

// LogTimestamp renders a timestamp in a very dim, barely-visible style.
func LogTimestamp(theme Theme, ts string) string {
	color := theme.Subtle
	if color == (lipgloss.AdaptiveColor{}) {
		color = theme.Muted
	}
	return lipgloss.NewStyle().
		Foreground(color).
		Faint(true).
		Render(ts)
}

// LogPaneLabel renders a pane identifier with subtle, quiet styling.
func LogPaneLabel(theme Theme, pane string) string {
	return lipgloss.NewStyle().
		Foreground(theme.Muted).
		Faint(true).
		Render(pane)
}

// WorkerStatusIcon returns a colored dot for worker/subtask status.
func WorkerStatusIcon(status string, t Theme) string {
	switch status {
	case "ready", "finished", "done":
		return lipgloss.NewStyle().Foreground(t.Success).Render("●")
	case "busy", "active":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("●")
	case "error", "failed":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("✗")
	case "deferred":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("⏸")
	case "reserved":
		return lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("○")
	default:
		return lipgloss.NewStyle().Foreground(t.Muted).Render("○")
	}
}

// ConnectionStatusDot returns a colored dot for connection status.
func ConnectionStatusDot(status string, t Theme) string {
	switch status {
	case "connected":
		return lipgloss.NewStyle().Foreground(t.Success).Render("●")
	case "error":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("●")
	case "pending", "connecting":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("●")
	default:
		return lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("○")
	}
}

// HealthDot returns a colored dot for a health status string.
func HealthDot(health string, t Theme) string {
	switch health {
	case "green", "healthy":
		return lipgloss.NewStyle().Foreground(t.Success).Render("●")
	case "amber", "degraded":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("●")
	case "idle":
		return lipgloss.NewStyle().Foreground(t.Muted).Render("●")
	default:
		return lipgloss.NewStyle().Foreground(t.Danger).Render("●")
	}
}

// ScrollIndicator returns a clickable LIVE/PAUSED scroll indicator.
func ScrollIndicator(autoFollow bool, zoneID string, t Theme) string {
	if autoFollow {
		return zone.Mark(zoneID, lipgloss.NewStyle().Foreground(t.Success).Render(" LIVE"))
	}
	return zone.Mark(zoneID, lipgloss.NewStyle().Foreground(t.Warning).Render(" PAUSED"))
}
