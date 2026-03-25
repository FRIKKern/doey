package styles

import "github.com/charmbracelet/lipgloss"

// PanelStyle returns a rounded-border panel style for inactive sections.
func PanelStyle(t Theme) lipgloss.Style {
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Muted).
		Padding(0, 1)
}

// ActivePanelStyle returns a highlighted panel style for the focused section.
func ActivePanelStyle(t Theme) lipgloss.Style {
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Primary).
		Padding(0, 1)
}

// HeaderStyle returns a style for section headers with a bottom border.
func HeaderStyle(t Theme) lipgloss.Style {
	b := lipgloss.Border{
		Bottom: "─",
	}
	return lipgloss.NewStyle().
		Border(b, false, false, true, false).
		BorderForeground(t.Muted).
		Foreground(t.Primary).
		Bold(true).
		PaddingBottom(0).
		MarginBottom(1)
}
