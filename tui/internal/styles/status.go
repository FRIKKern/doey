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
		return defaultTheme.Muted
	default:
		return defaultTheme.Muted
	}
}

// StatusBadge returns a styled, padded badge string for the given status.
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
	case "pending":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Warning).
			Render("⬤")
	case "active":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Success).
			Render("●")
	case "done":
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Muted).
			Render("○")
	default:
		return lipgloss.NewStyle().
			Foreground(defaultTheme.Muted).
			Render("○")
	}
}
