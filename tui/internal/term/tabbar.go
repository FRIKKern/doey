package term

import (
	"strings"

	"charm.land/lipgloss/v2"
)

// renderTabBar draws a horizontal row of tab labels. The active tab is
// highlighted; inactive tabs are dimmed. The bar fills the full width.
func renderTabBar(tabs []Tab, active int, width int) string {
	if len(tabs) == 0 {
		return ""
	}

	activeStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("#FFFFFF")).
		Background(lipgloss.Color("#5F5FD7")).
		PaddingLeft(1).
		PaddingRight(1)

	inactiveStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("#AAAAAA")).
		Background(lipgloss.Color("#333333")).
		PaddingLeft(1).
		PaddingRight(1)

	var parts []string
	for i, tab := range tabs {
		if i == active {
			parts = append(parts, activeStyle.Render(tab.Name))
		} else {
			parts = append(parts, inactiveStyle.Render(tab.Name))
		}
	}

	bar := strings.Join(parts, "")

	// Fill remaining width with background color.
	barWidth := lipgloss.Width(bar)
	if barWidth < width {
		fill := lipgloss.NewStyle().
			Background(lipgloss.Color("#222222")).
			Width(width - barWidth)
		bar += fill.Render("")
	}

	return bar
}
