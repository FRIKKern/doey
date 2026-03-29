package taskcard

import (
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// TaskItem wraps a PersistentTask for use in a bubbles list.
// It implements list.Item and list.DefaultItem.
type TaskItem struct {
	Task         runtime.PersistentTask
	Subtasks     []runtime.Subtask
	SubtaskDone  int
	SubtaskTotal int
}

// Title returns the task title for the list.
func (t TaskItem) Title() string { return t.Task.Title }

// Description returns the task description for the list.
func (t TaskItem) Description() string { return t.Task.Description }

// FilterValue returns the filterable string (the title).
func (t TaskItem) FilterValue() string { return t.Task.Title }

// CardDelegate renders task cards with status-colored borders.
// It implements list.ItemDelegate.
type CardDelegate struct {
	Theme styles.Theme
}

// NewCardDelegate creates a CardDelegate with the given theme.
func NewCardDelegate(t styles.Theme) CardDelegate {
	return CardDelegate{Theme: t}
}

// Height returns the fixed card height (title + status line + 2 desc lines + bottom padding).
func (d CardDelegate) Height() int { return 5 }

// Spacing returns the gap between cards.
func (d CardDelegate) Spacing() int { return 1 }

// Update is a no-op; the delegate does not handle messages.
func (d CardDelegate) Update(_ tea.Msg, _ *list.Model) tea.Cmd { return nil }

// Render draws a single task card into w.
func (d CardDelegate) Render(w io.Writer, m list.Model, index int, item list.Item) {
	ti, ok := item.(TaskItem)
	if !ok {
		return
	}

	selected := index == m.Index()
	cardWidth := m.Width() - 4
	if cardWidth < 20 {
		cardWidth = 20
	}

	task := ti.Task
	status := task.Status
	statusClr := d.taskStatusColor(status)

	// Border colors
	borderColor := d.Theme.Muted
	if selected {
		borderColor = d.Theme.Primary
	}

	// Build a rounded border with a left accent character.
	accentBorder := lipgloss.Border{
		Top:         "─",
		Bottom:      "─",
		Left:        "▎",
		Right:       "│",
		TopLeft:     "╭",
		TopRight:    "╮",
		BottomLeft:  "╰",
		BottomRight: "╯",
	}

	cardStyle := lipgloss.NewStyle().
		Border(accentBorder).
		BorderForeground(borderColor).
		BorderLeft(true).
		BorderRight(true).
		BorderTop(true).
		BorderBottom(true).
		Width(cardWidth).
		BorderLeftForeground(statusClr)

	// --- Line 1: icon + #ID + [type] + title ---
	icon := statusIcon(status, d.Theme)
	idStr := lipgloss.NewStyle().Foreground(d.Theme.Muted).Render("#" + task.ID)

	typeBadge := ""
	if task.Type != "" {
		typeClr := styles.CategoryColor(task.Type)
		typeBadge = lipgloss.NewStyle().Foreground(typeClr).Bold(true).Render("["+task.Type+"]") + " "
	}

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(d.Theme.Text)
	if selected {
		titleStyle = titleStyle.Foreground(d.Theme.Primary)
	}

	// Calculate how much space the title can occupy.
	// Content width = cardWidth minus horizontal border chars (2).
	contentWidth := cardWidth - 2
	if contentWidth < 10 {
		contentWidth = 10
	}

	prefix := icon + " " + idStr + " " + typeBadge
	prefixWidth := lipgloss.Width(prefix)
	titleMaxWidth := contentWidth - prefixWidth
	if titleMaxWidth < 4 {
		titleMaxWidth = 4
	}
	titleText := task.Title
	if lipgloss.Width(titleText) > titleMaxWidth {
		titleText = titleText[:titleMaxWidth-3] + "..."
	}
	line1 := prefix + titleStyle.Render(titleText)

	// --- Line 2: status badge + subtask progress + age ---
	badge := lipgloss.NewStyle().Foreground(statusClr).Render(status)
	progress := ""
	if ti.SubtaskTotal > 0 {
		progress = "  " + styles.SubtaskProgress(ti.SubtaskDone, ti.SubtaskTotal)
	}
	age := ""
	if task.Created > 0 {
		elapsed := time.Since(time.Unix(task.Created, 0))
		age = "  " + lipgloss.NewStyle().Foreground(d.Theme.Muted).Render(formatAge(elapsed))
	}
	line2 := badge + progress + age

	// --- Lines 3-4: description preview ---
	descLines := truncateDesc(task.Description, 2, contentWidth)

	descStyle := lipgloss.NewStyle().Foreground(d.Theme.Muted)
	renderedDesc := descStyle.Render(descLines)

	content := lipgloss.JoinVertical(lipgloss.Left, line1, line2, renderedDesc)
	fmt.Fprint(w, cardStyle.Render(content))
}

// taskStatusColor returns the accent color for a given task status.
func (d CardDelegate) taskStatusColor(status string) lipgloss.AdaptiveColor {
	switch status {
	case "done":
		return d.Theme.Success
	case "in_progress":
		return d.Theme.Warning
	case "active":
		return d.Theme.Primary
	case "failed":
		return d.Theme.Danger
	case "blocked":
		return d.Theme.Danger
	case "paused":
		return d.Theme.Accent
	case "pending_user_confirmation":
		return d.Theme.Warning
	default:
		return d.Theme.Muted
	}
}

// statusIcon returns a colored status icon for the given task status.
func statusIcon(status string, t styles.Theme) string {
	switch status {
	case "done":
		return lipgloss.NewStyle().Foreground(t.Success).Render("✓")
	case "in_progress":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("●")
	case "active":
		return lipgloss.NewStyle().Foreground(t.Primary).Render("●")
	case "failed":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("✕")
	case "blocked":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("○")
	case "pending_user_confirmation":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("⬤")
	case "cancelled":
		return lipgloss.NewStyle().Foreground(t.Muted).Render("○")
	default:
		return lipgloss.NewStyle().Foreground(t.Muted).Render("○")
	}
}

// truncateDesc truncates a description string to at most maxLines lines,
// each no wider than maxWidth. Adds "..." if truncation occurs.
func truncateDesc(s string, maxLines int, maxWidth int) string {
	if s == "" {
		return ""
	}

	// Split into words and wrap manually.
	words := strings.Fields(s)
	if len(words) == 0 {
		return ""
	}

	var lines []string
	var current strings.Builder

	for _, word := range words {
		if current.Len() == 0 {
			current.WriteString(word)
			continue
		}
		// Check if adding the next word would exceed width.
		if current.Len()+1+len(word) > maxWidth {
			lines = append(lines, current.String())
			current.Reset()
			current.WriteString(word)
			if len(lines) >= maxLines {
				break
			}
		} else {
			current.WriteString(" ")
			current.WriteString(word)
		}
	}

	// Flush remaining.
	if current.Len() > 0 && len(lines) < maxLines {
		lines = append(lines, current.String())
	}

	truncated := len(lines) >= maxLines && len(words) > 0

	// Ensure we have at most maxLines.
	if len(lines) > maxLines {
		lines = lines[:maxLines]
	}

	// Check if we actually consumed all words.
	totalChars := 0
	for _, l := range lines {
		totalChars += len(l)
	}
	allText := strings.Join(words, " ")
	if totalChars < len(allText) {
		truncated = true
	}

	// If truncated, add "..." to the last line.
	if truncated && len(lines) > 0 {
		last := lines[len(lines)-1]
		if len(last)+3 > maxWidth {
			last = last[:maxWidth-3]
		}
		lines[len(lines)-1] = last + "..."
	}

	// Pad to maxLines for consistent card height.
	for len(lines) < maxLines {
		lines = append(lines, "")
	}

	return strings.Join(lines, "\n")
}

// formatAge formats a duration into a human-readable short string.
func formatAge(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "<1m"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		days := int(d.Hours() / 24)
		return fmt.Sprintf("%dd", days)
	}
}
