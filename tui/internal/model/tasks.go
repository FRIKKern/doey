package model

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// taskItem adapts runtime.Task for the bubbles/list component.
type taskItem struct {
	task  runtime.Task
	theme styles.Theme
}

func (i taskItem) Title() string {
	return statusIcon(i.task.Status, i.theme) + " " + i.task.Title
}

func (i taskItem) Description() string {
	age := ""
	if i.task.Created > 0 {
		age = formatAge(time.Since(time.Unix(i.task.Created, 0)))
	}
	return fmt.Sprintf("#%s · %s · %s", i.task.ID, i.task.Status, age)
}

func (i taskItem) FilterValue() string { return i.task.Title }

// statusIcon returns a colored icon for a task status.
func statusIcon(status string, t styles.Theme) string {
	switch status {
	case "pending_user_confirmation":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("⬤")
	case "active":
		return lipgloss.NewStyle().Foreground(t.Success).Render("●")
	case "done":
		return lipgloss.NewStyle().Foreground(t.Muted).Render("○")
	case "cancelled":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("✕")
	default:
		return lipgloss.NewStyle().Foreground(t.Muted).Render("·")
	}
}

// formatAge returns a human-readable age string.
func formatAge(d time.Duration) string {
	d = d.Round(time.Second)
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	if h > 24 {
		return fmt.Sprintf("%dd", h/24)
	}
	if h > 0 {
		return fmt.Sprintf("%dh", h)
	}
	return fmt.Sprintf("%dm", m)
}

// TasksModel displays a filterable list of session tasks.
type TasksModel struct {
	list   list.Model
	tasks  []runtime.Task
	theme  styles.Theme
	width  int
	height int
}

// NewTasksModel creates a tasks panel with an empty list.
func NewTasksModel() TasksModel {
	t := styles.DefaultTheme()
	delegate := list.NewDefaultDelegate()
	delegate.Styles.SelectedTitle = delegate.Styles.SelectedTitle.
		Foreground(t.Primary).
		BorderLeftForeground(t.Primary)
	delegate.Styles.SelectedDesc = delegate.Styles.SelectedDesc.
		Foreground(t.Muted).
		BorderLeftForeground(t.Primary)

	l := list.New([]list.Item{}, delegate, 0, 0)
	l.SetShowTitle(false)
	l.SetShowStatusBar(false)
	l.SetShowHelp(false)

	return TasksModel{
		list:  l,
		theme: t,
	}
}

// Init is a no-op for the tasks sub-model.
func (m TasksModel) Init() tea.Cmd {
	return nil
}

// Update forwards messages to the underlying list.
func (m TasksModel) Update(msg tea.Msg) (TasksModel, tea.Cmd) {
	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	return m, cmd
}

// SetSnapshot replaces the task list with fresh data.
func (m *TasksModel) SetSnapshot(snap runtime.Snapshot) {
	m.tasks = snap.Tasks
	items := make([]list.Item, len(snap.Tasks))
	for i, t := range snap.Tasks {
		items[i] = taskItem{task: t, theme: m.theme}
	}
	m.list.SetItems(items)
}

// SetSize updates the panel dimensions.
func (m *TasksModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	// Reserve lines for: header + separator + summary + blank + bottom margin
	listH := h - 5
	if listH < 3 {
		listH = 3
	}
	m.list.SetSize(w, listH)
}

// taskSummary returns a styled summary like "3 tasks (1 active, 1 pending, 1 done)".
func (m TasksModel) taskSummary() string {
	t := m.theme
	active, pending, done, cancelled := 0, 0, 0, 0
	for _, task := range m.tasks {
		switch task.Status {
		case "active":
			active++
		case "pending_user_confirmation":
			pending++
		case "done":
			done++
		case "cancelled":
			cancelled++
		}
	}

	total := lipgloss.NewStyle().Bold(true).Foreground(t.Text).
		Render(fmt.Sprintf("%d tasks", len(m.tasks)))

	var parts []string
	if active > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Success).
			Render(fmt.Sprintf("%d active", active)))
	}
	if pending > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Warning).
			Render(fmt.Sprintf("%d pending", pending)))
	}
	if done > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Muted).
			Render(fmt.Sprintf("%d done", done)))
	}
	if cancelled > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Danger).
			Render(fmt.Sprintf("%d cancelled", cancelled)))
	}

	if len(parts) == 0 {
		return "  " + total
	}
	sep := lipgloss.NewStyle().Foreground(t.Muted).Render(", ")
	return "  " + total + " (" + strings.Join(parts, sep) + ")"
}

// View renders the task list panel.
func (m TasksModel) View() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	// Section header
	header := t.SectionHeader.Copy().PaddingLeft(2).Render("TASKS")

	// Thin separator
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.tasks) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No tasks yet. Tasks will appear as the team works.")

		content := header + "\n" + rule + "\n" + empty
		return lipgloss.NewStyle().
			Width(w).
			Height(m.height).
			Render(content)
	}

	summary := m.taskSummary()
	content := header + "\n" + rule + "\n" + summary + "\n\n" + m.list.View()

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Render(content)
}
