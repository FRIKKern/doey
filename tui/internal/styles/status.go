package styles

import "github.com/charmbracelet/lipgloss"

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
		Padding(0, 1)

	if status == "ERROR" {
		style = style.Bold(true)
	}

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
