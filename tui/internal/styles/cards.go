package styles

import (
	"fmt"
	"strings"

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

// ExpandedCardStyle returns a full-width card frame for the expanded task view.
// Uses a rounded border with status-colored left accent and subtle background.
func ExpandedCardStyle(theme Theme, status string, width int) lipgloss.Style {
	accent := StatusAccentColor(theme, status)
	border := accentBorder()

	return lipgloss.NewStyle().
		Border(border).
		BorderForeground(theme.Muted).
		BorderLeftForeground(accent).
		Background(lipgloss.AdaptiveColor{Light: "#F8FAFC", Dark: "#0F172A"}).
		Width(width).
		Padding(1, 1)
}

// SubtaskCheckbox returns a styled checkbox: "☑" (Success) or "☐" (Muted).
func SubtaskCheckbox(theme Theme, done bool) string {
	if done {
		return lipgloss.NewStyle().Foreground(theme.Success).Render("☑")
	}
	return lipgloss.NewStyle().Foreground(theme.Muted).Render("☐")
}

// SubtaskRow renders a full subtask row with indent, checkbox, title, and
// status badge. Selected rows get a Primary-colored ▎ indicator.
func SubtaskRow(theme Theme, title string, status string, done bool, selected bool, indent int) string {
	prefix := strings.Repeat("  ", indent)

	indicator := " "
	if selected {
		indicator = lipgloss.NewStyle().
			Foreground(theme.Primary).
			Render("▎")
	}

	checkbox := SubtaskCheckbox(theme, done)

	titleStyle := lipgloss.NewStyle().Foreground(theme.Text)
	if done {
		titleStyle = titleStyle.Faint(true)
	}

	badge := ""
	if status != "" {
		bg := StatusAccentColor(theme, status)
		badge = " " + lipgloss.NewStyle().
			Foreground(theme.BgText).
			Background(bg).
			Padding(0, 1).
			Render(status)
	}

	return fmt.Sprintf("%s%s %s %s%s",
		prefix, indicator, checkbox, titleStyle.Render(title), badge)
}

// ExpandedSectionHeader renders a section header pill for expanded card
// sections (Description, Subtasks, Decisions, Notes).
func ExpandedSectionHeader(theme Theme, title string) string {
	return SectionPill(title, theme.Primary)
}

// DecisionLogEntry renders a single decision log line with dim timestamp.
func DecisionLogEntry(theme Theme, text string, timestamp string) string {
	ts := lipgloss.NewStyle().Foreground(theme.Muted).Faint(true).Render(timestamp)
	body := lipgloss.NewStyle().Foreground(theme.Text).Render(text)
	return fmt.Sprintf("%s  %s", ts, body)
}

// NotesBlock renders styled notes text, word-wrapped to width, in Muted.
func NotesBlock(theme Theme, text string, width int) string {
	if width < 1 {
		width = 1
	}
	return lipgloss.NewStyle().
		Foreground(theme.Muted).
		Width(width).
		Render(text)
}

// ExpandedProgressBar renders a progress bar with "done/total" label.
// Uses Primary for filled segments and Faint for empty.
func ExpandedProgressBar(theme Theme, done int, total int, width int) string {
	if total == 0 {
		return ""
	}

	label := fmt.Sprintf("%d/%d", done, total)
	labelWidth := lipgloss.Width(label) + 1 // +1 for space
	barWidth := width - labelWidth
	if barWidth < 2 {
		barWidth = 2
	}

	filled := barWidth * done / total
	empty := barWidth - filled

	filledStyle := lipgloss.NewStyle().Foreground(theme.Primary)
	emptyStyle := lipgloss.NewStyle().Foreground(theme.Muted).Faint(true)

	bar := filledStyle.Render(strings.Repeat("█", filled)) +
		emptyStyle.Render(strings.Repeat("░", empty))

	labelStyled := lipgloss.NewStyle().Foreground(theme.Text).Render(label)
	return fmt.Sprintf("%s %s", labelStyled, bar)
}
