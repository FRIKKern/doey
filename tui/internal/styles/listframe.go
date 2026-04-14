package styles

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// RenderEmptyState renders a styled empty-state message with muted text and
// left/top padding. Used by scrollable list views when they have no items.
func RenderEmptyState(msg string, t Theme) string {
	return lipgloss.NewStyle().
		Foreground(t.Muted).
		PaddingLeft(3).
		PaddingTop(1).
		Render(msg)
}

// RenderListFrame joins content parts with newlines and wraps the result in a
// fixed-size container. This is the common outer frame for all scrollable list
// views (activity, interactions, messages, violations, logview, debug).
func RenderListFrame(parts []string, w, h int) string {
	content := strings.Join(parts, "\n")
	return lipgloss.NewStyle().
		Width(w).
		Height(h).
		MaxHeight(h).
		Render(content)
}
