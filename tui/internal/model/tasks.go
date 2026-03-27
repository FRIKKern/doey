package model

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

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

// TasksModel displays a kanban-style task board with sections, CRUD, and subtask nesting.
type TasksModel struct {
	// Data
	entries    []runtime.PersistentTask     // from persistent store + merged runtime
	subtaskMap map[string][]runtime.Subtask // task ID -> subtasks
	theme      styles.Theme

	// Navigation
	cursor      int
	summaryMode bool // true = list, false = detail
	keyMap      keys.KeyMap

	// Input modes
	creating  bool   // inline create mode
	inputText string // current input text

	// Layout
	width   int
	height  int
	focused bool
}

// NewTasksModel creates a tasks panel starting in list mode.
func NewTasksModel() TasksModel {
	return TasksModel{
		theme:       styles.DefaultTheme(),
		summaryMode: true,
		keyMap:      keys.DefaultKeyMap(),
		subtaskMap:  make(map[string][]runtime.Subtask),
	}
}

// Init is a no-op for the tasks sub-model.
func (m TasksModel) Init() tea.Cmd { return nil }

// SetSize updates the panel dimensions.
func (m *TasksModel) SetSize(w, h int) { m.width = w; m.height = h }

// SetFocused toggles focus state.
func (m *TasksModel) SetFocused(focused bool) { m.focused = focused }

// SetSnapshot merges persistent + runtime tasks and rebuilds the view.
func (m *TasksModel) SetSnapshot(snap runtime.Snapshot) {
	store, _ := runtime.ReadTaskStore()
	store.MergeRuntimeTasks(snap.Tasks)

	m.entries = store.Tasks
	m.sortEntries()

	// Build subtask map
	m.subtaskMap = make(map[string][]runtime.Subtask)
	for _, st := range snap.Subtasks {
		m.subtaskMap[st.TaskID] = append(m.subtaskMap[st.TaskID], st)
	}

	if m.cursor >= len(m.entries) {
		m.cursor = max(0, len(m.entries)-1)
	}
}

func (m *TasksModel) sortEntries() {
	sectionOrder := map[string]int{"active": 0, "upcoming": 1, "done": 2}
	sort.SliceStable(m.entries, func(i, j int) bool {
		a, b := m.entries[i], m.entries[j]
		sa := sectionOrder[a.Section]
		sb := sectionOrder[b.Section]
		if sa != sb {
			return sa < sb
		}
		if a.Priority != b.Priority {
			return a.Priority < b.Priority
		}
		return a.Created > b.Created
	})
}

// Update handles input modes, detail, and list navigation.
func (m TasksModel) Update(msg tea.Msg) (TasksModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	kmsg, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}

	// Input mode (creating)
	if m.creating {
		return m.updateInput(kmsg)
	}

	// Detail mode
	if !m.summaryMode {
		return m.updateDetail(kmsg)
	}

	// List mode
	return m.updateList(kmsg)
}

func (m TasksModel) updateInput(msg tea.KeyMsg) (TasksModel, tea.Cmd) {
	switch msg.Type {
	case tea.KeyEnter:
		if m.inputText != "" {
			title := m.inputText
			m.creating = false
			m.inputText = ""
			return m, func() tea.Msg {
				return CreateTaskMsg{Title: title}
			}
		}
	case tea.KeyEsc:
		m.creating = false
		m.inputText = ""
	case tea.KeyBackspace:
		if len(m.inputText) > 0 {
			m.inputText = m.inputText[:len(m.inputText)-1]
		}
	default:
		if msg.Type == tea.KeyRunes {
			m.inputText += string(msg.Runes)
		} else if msg.Type == tea.KeySpace {
			m.inputText += " "
		}
	}
	return m, nil
}

func (m TasksModel) updateList(msg tea.KeyMsg) (TasksModel, tea.Cmd) {
	total := len(m.entries)
	if total == 0 {
		if msg.String() == "n" {
			m.creating = true
			m.inputText = ""
		}
		return m, nil
	}

	switch {
	case key.Matches(msg, m.keyMap.Up):
		m.cursor--
		if m.cursor < 0 {
			m.cursor = total - 1
		}
	case key.Matches(msg, m.keyMap.Down):
		m.cursor++
		if m.cursor >= total {
			m.cursor = 0
		}
	case key.Matches(msg, m.keyMap.Select):
		m.summaryMode = false

	default:
		switch msg.String() {
		case "n":
			m.creating = true
			m.inputText = ""
		case "m":
			// Move to next section
			if m.cursor >= 0 && m.cursor < total {
				task := m.entries[m.cursor]
				next := nextSection(task.Section)
				return m, func() tea.Msg {
					return MoveTaskMsg{ID: task.ID, Section: next}
				}
			}
		case "d":
			if m.cursor >= 0 && m.cursor < total {
				task := m.entries[m.cursor]
				return m, func() tea.Msg {
					return DispatchTaskMsg{ID: task.ID, Title: task.Title}
				}
			}
		case "x":
			if m.cursor >= 0 && m.cursor < total {
				task := m.entries[m.cursor]
				return m, func() tea.Msg {
					return CancelTaskMsg{ID: task.ID}
				}
			}
		}
	}

	return m, nil
}

func (m TasksModel) updateDetail(msg tea.KeyMsg) (TasksModel, tea.Cmd) {
	total := len(m.entries)
	if total == 0 {
		m.summaryMode = true
		return m, nil
	}

	switch {
	case key.Matches(msg, m.keyMap.Back):
		m.summaryMode = true
	default:
		switch msg.String() {
		case "m":
			if m.cursor >= 0 && m.cursor < total {
				task := m.entries[m.cursor]
				next := nextSection(task.Section)
				return m, func() tea.Msg {
					return MoveTaskMsg{ID: task.ID, Section: next}
				}
			}
		case "d":
			if m.cursor >= 0 && m.cursor < total {
				task := m.entries[m.cursor]
				return m, func() tea.Msg {
					return DispatchTaskMsg{ID: task.ID, Title: task.Title}
				}
			}
		case "x":
			if m.cursor >= 0 && m.cursor < total {
				task := m.entries[m.cursor]
				return m, func() tea.Msg {
					return CancelTaskMsg{ID: task.ID}
				}
			}
		}
	}

	return m, nil
}

// nextSection cycles: active → upcoming → done → active.
func nextSection(s string) string {
	switch s {
	case "active":
		return "upcoming"
	case "upcoming":
		return "done"
	default:
		return "active"
	}
}

// View renders list or detail mode.
func (m TasksModel) View() string {
	if m.summaryMode {
		return m.viewList()
	}
	return m.viewDetail()
}

func (m TasksModel) viewList() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("TASKS")
	rule := t.Faint.Render(strings.Repeat("\u2500", w))

	if len(m.entries) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No tasks yet. Press n to create one.")
		hint := ""
		if m.focused {
			hint = "\n" + lipgloss.NewStyle().
				Foreground(t.Muted).Faint(true).PaddingLeft(3).PaddingTop(1).
				Render("n = new task")
		}
		content := header + "\n" + rule + "\n" + empty + hint
		if m.creating {
			content += "\n" + m.renderInputBar()
		}
		return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
	}

	summary := m.taskSummary()
	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	// Build rows with section headers
	var lines []string
	lastSection := ""
	for i, entry := range m.entries {
		section := sectionLabel(entry.Section)
		if section != lastSection {
			if lastSection != "" {
				lines = append(lines, "")
			}
			sectionHeader := t.SectionHeader.Copy().PaddingLeft(1).Render(section)
			lines = append(lines, sectionHeader)
			lastSection = section
		}

		line := m.renderTaskRow(entry, w)
		if m.focused && i == m.cursor {
			line = lipgloss.NewStyle().
				Background(selectedBg).
				Width(w - 4).
				Render(line)
		}
		lines = append(lines, line)
	}

	body := lipgloss.NewStyle().
		Padding(0, 2).
		Render(strings.Join(lines, "\n"))

	hint := ""
	if m.focused && !m.creating {
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Padding(1, 3).
			Render("enter = detail  n = new  m = move  d = dispatch  x = cancel")
	}

	content := header + "\n" + rule + "\n" + summary + "\n" + body + "\n" + hint
	if m.creating {
		content += "\n" + m.renderInputBar()
	}
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}

// taskSummary returns section counts.
func (m TasksModel) taskSummary() string {
	t := m.theme
	active, upcoming, done := 0, 0, 0
	for _, task := range m.entries {
		switch task.Section {
		case "active":
			active++
		case "upcoming":
			upcoming++
		default:
			done++
		}
	}

	total := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(fmt.Sprintf("%d tasks", len(m.entries)))

	var parts []string
	if active > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Success).
			Render(fmt.Sprintf("%d active", active)))
	}
	if upcoming > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Warning).
			Render(fmt.Sprintf("%d upcoming", upcoming)))
	}
	if done > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Muted).
			Render(fmt.Sprintf("%d done", done)))
	}

	if len(parts) > 0 {
		return total + "  " + strings.Join(parts, "  ")
	}
	return total
}

// sectionLabel returns the display name for a section.
func sectionLabel(section string) string {
	switch section {
	case "active":
		return "ACTIVE"
	case "upcoming":
		return "UPCOMING"
	default:
		return "DONE"
	}
}

// renderTaskRow renders a single task as a one-liner.
func (m TasksModel) renderTaskRow(task runtime.PersistentTask, maxW int) string {
	t := m.theme

	icon := statusIcon(task.Status, t)
	id := t.Dim.Render(fmt.Sprintf("#%s", task.ID))
	title := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(task.Title)

	age := ""
	if task.Created > 0 {
		age = t.Faint.Render(formatAge(time.Since(time.Unix(task.Created, 0))))
	}

	// Subtask count
	subtaskBadge := ""
	if subs, ok := m.subtaskMap[task.ID]; ok && len(subs) > 0 {
		done := 0
		for _, s := range subs {
			if s.Status == "done" {
				done++
			}
		}
		subtaskBadge = t.Dim.Render(fmt.Sprintf(" [%d/%d]", done, len(subs)))
	}

	// Team badge
	teamBadge := ""
	if task.Team != "" {
		teamBadge = " " + lipgloss.NewStyle().Foreground(t.Accent).Render("["+task.Team+"]")
	}

	return "  " + icon + " " + id + " " + title + subtaskBadge + teamBadge + " " + age
}

// renderInputBar renders the inline text input for creating a task.
func (m TasksModel) renderInputBar() string {
	t := m.theme
	prompt := lipgloss.NewStyle().Bold(true).Foreground(t.Primary).
		Render("New task: ")
	input := lipgloss.NewStyle().Foreground(t.Text).
		Render(m.inputText + "\u2588")
	return lipgloss.NewStyle().Padding(1, 3).Render(prompt + input)
}

// --- Detail view ---

func (m TasksModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	if m.cursor < 0 || m.cursor >= len(m.entries) {
		m.summaryMode = true
		return m.viewList()
	}

	task := m.entries[m.cursor]

	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(fmt.Sprintf("TASK \u2014 #%s", task.ID))
	rule := t.Faint.Render(strings.Repeat("\u2500", w))
	backHint := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc = back  m = move  d = dispatch  x = cancel")

	labelStyle := t.StatLabel.Copy().Width(14)
	valueStyle := t.Body

	// Status with color
	statusColor := t.Muted
	switch task.Status {
	case "active":
		statusColor = t.Success
	case "pending_user_confirmation":
		statusColor = t.Warning
	case "cancelled":
		statusColor = t.Danger
	}

	var fields []string
	fields = append(fields, labelStyle.Render("Title")+valueStyle.Render(task.Title))
	fields = append(fields, labelStyle.Render("Status")+
		lipgloss.NewStyle().Foreground(statusColor).Render(task.Status))
	fields = append(fields, labelStyle.Render("Section")+valueStyle.Render(sectionLabel(task.Section)))

	if task.Team != "" {
		fields = append(fields, labelStyle.Render("Team")+
			lipgloss.NewStyle().Foreground(t.Accent).Render(task.Team))
	}
	if task.Created > 0 {
		fields = append(fields, labelStyle.Render("Created")+
			valueStyle.Render(time.Unix(task.Created, 0).Format("2006-01-02 15:04:05")))
	}
	if task.Updated > 0 {
		fields = append(fields, labelStyle.Render("Updated")+
			valueStyle.Render(time.Unix(task.Updated, 0).Format("2006-01-02 15:04:05")))
	}
	if task.Description != "" {
		descWidth := w - 20
		if descWidth < 20 {
			descWidth = 20
		}
		fields = append(fields, labelStyle.Render("Description")+
			lipgloss.NewStyle().Foreground(t.Text).Width(descWidth).Render(task.Description))
	}

	fieldBlock := lipgloss.NewStyle().Padding(1, 3).Render(strings.Join(fields, "\n"))

	// Subtasks
	subtaskBlock := ""
	if subs, ok := m.subtaskMap[task.ID]; ok && len(subs) > 0 {
		subHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("SUBTASKS")
		subRule := lipgloss.NewStyle().PaddingLeft(3).
			Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))

		var subLines []string
		for _, st := range subs {
			dot := lipgloss.NewStyle().Foreground(t.Muted).Render("\u25cb")
			if st.Status == "done" {
				dot = lipgloss.NewStyle().Foreground(t.Success).Render("\u25cf")
			} else if st.Status == "active" {
				dot = lipgloss.NewStyle().Foreground(t.Primary).Render("\u25cf")
			} else if st.Status == "failed" {
				dot = lipgloss.NewStyle().Foreground(t.Danger).Render("\u2715")
			}
			pane := t.Dim.Render(st.Pane)
			title := valueStyle.Render(st.Title)
			status := lipgloss.NewStyle().Foreground(t.Muted).Render(st.Status)
			subLines = append(subLines, fmt.Sprintf("  %s %s  %s  %s", dot, pane, title, status))
		}
		subtaskBlock = "\n" + subHeader + "\n" + subRule + "\n" +
			lipgloss.NewStyle().Padding(0, 3).Render(strings.Join(subLines, "\n"))
	}

	content := header + "\n" + rule + "\n" + backHint + "\n" + fieldBlock + subtaskBlock
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}
