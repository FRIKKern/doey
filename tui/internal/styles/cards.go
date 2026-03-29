package styles

import (
	"github.com/charmbracelet/lipgloss"
)

// StatusAccentColor maps a task status string to an accent color from the theme.
func StatusAccentColor(t Theme, status string) lipgloss.AdaptiveColor {
	switch status {
	case "done":
		return t.Success
	case "in_progress":
		return t.Warning
	case "active":
		return t.Primary
	case "failed":
		return t.Danger
	case "cancelled":
		return t.Muted
	case "pending_user_confirmation":
		return t.Warning
	default:
		return t.Muted
	}
}

// accentBorder returns a rounded border with a left-side block accent.
// The left edge uses "▎" (left 1/8 block) for a subtle colored stripe.
func accentBorder() lipgloss.Border {
	r := lipgloss.RoundedBorder()
	r.Left = "▎"
	r.TopLeft = "▎"
	r.BottomLeft = "▎"
	return r
}

// CardStyle returns a bordered card style for task cards.
// The left border uses the status accent color; when selected the entire
// border switches to Primary and the background gets a subtle highlight.
func CardStyle(t Theme, status string, selected bool, width int) lipgloss.Style {
	if selected {
		return lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(t.Primary).
			Background(lipgloss.AdaptiveColor{Light: "#F0F9FF", Dark: "#1E293B"}).
			Width(width).
			Padding(0, 1)
	}

	accent := StatusAccentColor(t, status)
	border := accentBorder()

	return lipgloss.NewStyle().
		Border(border).
		BorderForeground(t.Muted).
		BorderLeftForeground(accent).
		Width(width).
		Padding(0, 1)
}

// CardTitleStyle returns the style for a card's title line.
// Bold text in the default color, switching to Primary when selected.
func CardTitleStyle(t Theme, selected bool) lipgloss.Style {
	fg := t.Text
	if selected {
		fg = t.Primary
	}
	return lipgloss.NewStyle().
		Foreground(fg).
		Bold(true)
}

// CardDescStyle returns the style for a card's description preview (1-2 lines).
func CardDescStyle(t Theme) lipgloss.Style {
	return lipgloss.NewStyle().
		Foreground(t.Muted)
}

// CardMetaStyle returns a faint style for card metadata (age, subtask count).
func CardMetaStyle(t Theme) lipgloss.Style {
	return lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true)
}

// StatusBadgeCard renders a compact pill badge for a task status.
// The background is the status accent color and the foreground is BgText.
func StatusBadgeCard(status string, t Theme) string {
	bg := StatusAccentColor(t, status)
	return lipgloss.NewStyle().
		Foreground(t.BgText).
		Background(bg).
		Padding(0, 1).
		Render(status)
}

// TypeTagCard renders a bracketed type tag with a category-appropriate color,
// e.g. "[feature]" in Primary or "[bug]" in Danger.
func TypeTagCard(taskType string, t Theme) string {
	if taskType == "" {
		return ""
	}
	color := CategoryColor(taskType)
	return lipgloss.NewStyle().
		Foreground(color).
		Bold(true).
		Render("[" + taskType + "]")
}
