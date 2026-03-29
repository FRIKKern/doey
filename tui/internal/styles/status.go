package styles

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

var defaultTheme = DefaultTheme()

// StatusColor returns the adaptive color for a given pane status.
func StatusColor(status string) lipgloss.AdaptiveColor {
	switch status {
	case "READY":
		return defaultTheme.Success
	case "BUSY", "WORKING":
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

// StatusText returns status text colored by foreground only — calm, informational.
func StatusText(status string) string {
	color := StatusColor(status)

	style := lipgloss.NewStyle().Foreground(color)
	if status == "ERROR" {
		style = style.Bold(true)
	}

	label := status
	if status == "WORKING" {
		label = "BUSY"
	}

	return style.Render(label)
}

// StatusBadge returns a styled, padded badge string for the given status.
// Prefer StatusText for a calmer look; use StatusBadge only where emphasis is needed.
func StatusBadge(status string) string {
	color := StatusColor(status)
	dark := defaultTheme.BgText

	style := lipgloss.NewStyle().
		Foreground(dark).
		Background(color).
		Bold(true).
		Padding(0, 1)

	label := status
	if status == "WORKING" {
		label = "BUSY"
	}

	return style.Render(label)
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
func TaskIcon(status string) string {
	switch status {
	case "active":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Muted).
			Render("○")
	case "in_progress":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Success).
			Render("●")
	case "pending_user_confirmation":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Warning).
			Render("⬤")
	case "done":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Muted).
			Render("○")
	case "cancelled":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Muted).
			Render("○")
	case "failed":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Danger).
			Render("✕")
	default:
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Muted).
			Render("○")
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

// SectionPill renders an inverted-color pill badge for section headers.
// Inspired by omm's title pill pattern: foreground=dark, background=color.
func SectionPill(label string, bg lipgloss.AdaptiveColor) string {
	return lipgloss.NewStyle().
		Foreground(defaultTheme.BgText).
		Background(bg).
		Bold(true).
		Padding(0, 1).
		Render(label)
}

// SubtaskProgress renders a colored subtask progress indicator.
// Shows "(done/total done)" with green when fully complete.
func SubtaskProgress(done, total int) string {
	if total == 0 {
		return ""
	}
	label := fmt.Sprintf("(%d/%d done)", done, total)
	color := defaultTheme.Muted
	if done == total {
		color = defaultTheme.Success
	} else if done > 0 {
		color = defaultTheme.Warning
	}
	return lipgloss.NewStyle().Foreground(color).Render(label)
}

// LogEventBadge returns a styled pill badge for a log event type.
func LogEventBadge(theme Theme, eventType string) string {
	var bg lipgloss.AdaptiveColor
	switch eventType {
	case "info":
		bg = theme.Info
		if bg == (lipgloss.AdaptiveColor{}) {
			bg = lipgloss.AdaptiveColor{Light: "#2563EB", Dark: "#3B82F6"}
		}
	case "warn", "warning":
		bg = theme.Warning
	case "error":
		bg = theme.Danger
	case "task":
		bg = theme.Primary
	case "dispatch":
		bg = theme.Accent
	case "research":
		bg = theme.Success
	case "commit", "git":
		bg = lipgloss.AdaptiveColor{Light: "#6B7280", Dark: "#6B7280"}
	default:
		bg = theme.Muted
	}

	label := strings.ToUpper(eventType)
	return lipgloss.NewStyle().
		Foreground(theme.BgText).
		Background(bg).
		Bold(true).
		Padding(0, 1).
		Render(label)
}

// LogTimestamp renders a timestamp in a subtle, non-distracting style.
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

// LogPaneLabel renders a pane identifier with subtle styling.
func LogPaneLabel(theme Theme, pane string) string {
	return lipgloss.NewStyle().
		Foreground(theme.Muted).
		Padding(0, 1).
		Render(pane)
}
