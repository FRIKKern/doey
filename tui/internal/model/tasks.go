package model

import (
	"fmt"
	"time"

	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// taskItem adapts runtime.Task for the bubbles/list component.
type taskItem struct {
	task runtime.Task
}

func (i taskItem) Title() string {
	return statusIcon(i.task.Status) + " " + i.task.Title
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
func statusIcon(status string) string {
	switch status {
	case "pending_user_confirmation":
		return "⬤" // yellow — styled at render time
	case "active":
		return "●" // green
	case "done":
		return "○" // dim
	case "cancelled":
		return "✕" // red
	default:
		return "·"
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
	l.Title = "Tasks"
	l.SetShowStatusBar(false)
	l.SetShowHelp(false)
	l.Styles.Title = lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		Padding(0, 1)

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
		items[i] = taskItem{task: t}
	}
	m.list.SetItems(items)
	m.list.Title = fmt.Sprintf("Tasks (%d)", len(snap.Tasks))
}

// SetSize updates the panel dimensions.
func (m *TasksModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.list.SetSize(w-2, h-2) // account for border padding
}

// View renders the task list panel.
func (m TasksModel) View() string {
	if len(m.tasks) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(m.theme.Muted).
			Padding(1, 2).
			Render("No tasks yet")
		return lipgloss.NewStyle().
			Width(m.width).
			Height(m.height).
			Render(m.list.View() + "\n" + empty)
	}
	return m.list.View()
}
