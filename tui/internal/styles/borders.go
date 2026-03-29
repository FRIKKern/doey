package styles

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// PanelStyle returns a hidden-border panel style for inactive sections.
// HiddenBorder preserves the same spacing as RoundedBorder, preventing
// layout jitter when focus switches between panels (Kancli pattern).
func PanelStyle(t Theme) lipgloss.Style {
	return lipgloss.NewStyle().
		Border(lipgloss.HiddenBorder()).
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

// ThickSeparator returns a "═" line of the given width, rendered in the Faint style.
func ThickSeparator(t Theme, width int) string {
	if width < 1 {
		width = 1
	}
	return t.Faint.Render(strings.Repeat("═", width))
}

// ThinSeparator returns a "─" line of the given width, rendered in the Faint style.
func ThinSeparator(t Theme, width int) string {
	if width < 1 {
		width = 1
	}
	return t.Faint.Render(strings.Repeat("─", width))
}
