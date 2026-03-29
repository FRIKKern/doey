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

// sectionOfStatus derives a display section from a canonical task status.
func sectionOfStatus(status string) string {
	switch status {
	case "active", "in_progress", "pending_user_confirmation":
		return "active"
	case "done", "cancelled", "failed":
		return "complete"
	default:
		return "active"
	}
}

// statusIcon returns a colored icon for a task status.
func statusIcon(status string, t styles.Theme) string {
	switch status {
	case "active":
		return lipgloss.NewStyle().Foreground(t.Muted).Render("○")
	case "in_progress":
		return lipgloss.NewStyle().Foreground(t.Primary).Render("●")
	case "pending_user_confirmation":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("◉")
	case "done":
		return lipgloss.NewStyle().Foreground(t.Success).Render("✓")
	case "cancelled":
		return lipgloss.NewStyle().Foreground(t.Muted).Render("—")
	case "failed":
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
	runtime.SetProjectDir(snap.Session.ProjectDir)
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
	sectionOrder := map[string]int{"active": 0, "complete": 1}
	sort.SliceStable(m.entries, func(i, j int) bool {
		a, b := m.entries[i], m.entries[j]
		sa := sectionOrder[sectionOfStatus(a.Status)]
		sb := sectionOrder[sectionOfStatus(b.Status)]
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
			// Move to next status
			if m.cursor >= 0 && m.cursor < total {
				task := m.entries[m.cursor]
				next := nextMoveStatus(task.Status)
				return m, func() tea.Msg {
					return MoveTaskMsg{ID: task.ID, Status: next}
				}
			}
		case "d":
			if m.cursor >= 0 && m.cursor < total {
				task := m.entries[m.cursor]
				return m, func() tea.Msg {
					return DispatchTaskMsg{ID: task.ID, Title: task.Title}
				}
			}
		case "s":
			// Cycle through all statuses
			if m.cursor >= 0 && m.cursor < total {
				task := m.entries[m.cursor]
				next := nextStatus(task.Status)
				return m, func() tea.Msg {
					return SetStatusTaskMsg{ID: task.ID, Status: next}
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
				next := nextMoveStatus(task.Status)
				return m, func() tea.Msg {
					return MoveTaskMsg{ID: task.ID, Status: next}
				}
			}
		case "s":
			if m.cursor >= 0 && m.cursor < total {
				task := m.entries[m.cursor]
				next := nextStatus(task.Status)
				return m, func() tea.Msg {
					return SetStatusTaskMsg{ID: task.ID, Status: next}
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

// nextMoveStatus cycles through the main statuses: active → in_progress → done → active.
func nextMoveStatus(s string) string {
	switch s {
	case "active":
		return "in_progress"
	case "in_progress":
		return "done"
	case "done":
		return "active"
	default:
		return "active"
	}
}

// allStatuses is the full list of task statuses for cycling.
var allStatuses = []string{"active", "in_progress", "pending_user_confirmation", "done", "cancelled", "failed"}

// nextStatus cycles through all statuses.
func nextStatus(s string) string {
	for i, st := range allStatuses {
		if st == s {
			return allStatuses[(i+1)%len(allStatuses)]
		}
	}
	return allStatuses[0]
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

	// Build rows with section headers (inverted pill badges)
	var lines []string
	lastSection := ""
	for i, entry := range m.entries {
		sec := sectionOfStatus(entry.Status)
		section := sectionLabel(sec)
		if section != lastSection {
			if lastSection != "" {
				lines = append(lines, "")
			}
			// Inverted-color pill for section headers (omm pattern)
			pillColor := t.Primary
			if sec == "complete" {
				pillColor = t.Success
			}
			sectionHeader := " " + styles.SectionPill(section, pillColor)
			lines = append(lines, sectionHeader)
			lastSection = section
		}

		selected := m.focused && i == m.cursor
		line := m.renderTaskRow(entry, w, selected)
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
			Render("enter = detail  n = new  m = move  s = status  d = dispatch  x = cancel")
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
	active, complete := 0, 0
	for _, task := range m.entries {
		switch sectionOfStatus(task.Status) {
		case "active":
			active++
		default:
			complete++
		}
	}

	total := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(fmt.Sprintf("%d tasks", len(m.entries)))

	var parts []string
	if active > 0 {
		parts = append(parts, styles.SectionPill(fmt.Sprintf("%d active", active), t.Primary))
	}
	if complete > 0 {
		parts = append(parts, styles.SectionPill(fmt.Sprintf("%d complete", complete), t.Success))
	}

	if len(parts) > 0 {
		return total + "  " + strings.Join(parts, " ")
	}
	return total
}

// sectionLabel returns the display name for a derived section.
func sectionLabel(section string) string {
	switch section {
	case "active":
		return "ACTIVE"
	default:
		return "COMPLETE"
	}
}

// renderTaskRow renders a single task as a one-liner.
// When selected, uses ▎ (left 1/8 block) indicator instead of background highlight (omm pattern).
func (m TasksModel) renderTaskRow(task runtime.PersistentTask, maxW int, selected bool) string {
	t := m.theme

	icon := statusIcon(task.Status, t)
	id := t.Dim.Render(fmt.Sprintf("#%s", task.ID))

	// Category badge
	catBadge := ""
	if task.Category != "" {
		catBadge = " " + styles.CategoryBadge(task.Category)
	}

	title := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(task.Title)

	age := ""
	if task.Created > 0 {
		age = t.Faint.Render(formatAge(time.Since(time.Unix(task.Created, 0))))
	}

	// Subtask progress — colored "(done/total done)" indicator
	subtaskBadge := ""
	if subs, ok := m.subtaskMap[task.ID]; ok && len(subs) > 0 {
		done := 0
		for _, s := range subs {
			if s.Status == "done" {
				done++
			}
		}
		subtaskBadge = " " + styles.SubtaskProgress(done, len(subs))
	}

	// Priority badge (show for P0 and P1 only)
	priBadge := ""
	if task.Priority <= 1 {
		priColor := t.Danger
		if task.Priority == 1 {
			priColor = t.Warning
		}
		priBadge = " " + lipgloss.NewStyle().Bold(true).Foreground(priColor).
			Render(fmt.Sprintf("P%d", task.Priority))
	}

	// Team badge
	teamBadge := ""
	if task.Team != "" {
		teamBadge = " " + lipgloss.NewStyle().Foreground(t.Accent).Render("["+task.Team+"]")
	}

	// Tags (max 3 in list view)
	tagStr := ""
	if len(task.Tags) > 0 {
		limit := len(task.Tags)
		if limit > 3 {
			limit = 3
		}
		var tagParts []string
		for _, tag := range task.Tags[:limit] {
			tagParts = append(tagParts, styles.TagBadge(tag))
		}
		tagStr = " " + strings.Join(tagParts, " ")
	}

	// Blocker indicator
	blockerBadge := ""
	if task.Blockers != "" {
		blockerBadge = " " + lipgloss.NewStyle().Bold(true).Foreground(t.Danger).Render("⚠")
	}

	// Type badge (compact)
	typeBadge := ""
	if task.Type != "" {
		typeBadge = " " + t.Dim.Render("["+task.Type+"]")
	}

	// Selection indicator: ▎ (left 1/8 block) when selected, space when not (omm pattern)
	indicator := "  "
	if selected {
		indicator = lipgloss.NewStyle().Foreground(t.Primary).Render("▎") + " "
	}

	row := indicator + icon + " " + id + catBadge + typeBadge + " " + title + priBadge + blockerBadge + subtaskBadge + teamBadge + tagStr + " " + age

	// Selected rows get primary-colored text for the entire line
	if selected {
		row = lipgloss.NewStyle().Foreground(t.Primary).Render(row)
	}

	// Merged tasks are dimmed with a merge indicator
	if task.MergedInto != "" {
		row = lipgloss.NewStyle().Faint(true).Render(row) +
			t.Dim.Render(" -> #"+task.MergedInto)
	}

	return row
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
		Render("esc = back  m = move  s = status  d = dispatch  x = cancel")

	labelStyle := t.StatLabel.Copy().Width(14)
	valueStyle := t.Body

	// Status with color
	statusColor := t.Muted
	switch task.Status {
	case "active":
		statusColor = t.Muted
	case "in_progress":
		statusColor = t.Primary
	case "pending_user_confirmation":
		statusColor = t.Warning
	case "done":
		statusColor = t.Success
	case "cancelled":
		statusColor = t.Muted
	case "failed":
		statusColor = t.Danger
	}

	var fields []string
	fields = append(fields, labelStyle.Render("Title")+valueStyle.Render(task.Title))
	fields = append(fields, labelStyle.Render("Status")+
		statusIcon(task.Status, t)+" "+lipgloss.NewStyle().Foreground(statusColor).Render(task.Status))

	// Type
	if task.Type != "" {
		fields = append(fields, labelStyle.Render("Type")+valueStyle.Render(task.Type))
	}

	// Team — prominent, right after status
	if task.Team != "" {
		fields = append(fields, labelStyle.Render("Team")+
			lipgloss.NewStyle().Bold(true).Foreground(t.Accent).Render(task.Team))
	}
	// Owner info
	if task.CreatedBy != "" {
		fields = append(fields, labelStyle.Render("Created by")+valueStyle.Render(task.CreatedBy))
	}
	if task.AssignedTo != "" {
		fields = append(fields, labelStyle.Render("Assigned to")+
			lipgloss.NewStyle().Bold(true).Foreground(t.Accent).Render(task.AssignedTo))
	}
	// Priority
	{
		priLabel := fmt.Sprintf("P%d", task.Priority)
		priColor := t.Muted
		switch {
		case task.Priority == 0:
			priColor = t.Danger
			priLabel += " (critical)"
		case task.Priority == 1:
			priColor = t.Warning
			priLabel += " (high)"
		case task.Priority == 2:
			priColor = t.Primary
			priLabel += " (medium)"
		default:
			priLabel += " (low)"
		}
		fields = append(fields, labelStyle.Render("Priority")+
			lipgloss.NewStyle().Foreground(priColor).Render(priLabel))
	}
	if task.Category != "" {
		fields = append(fields, labelStyle.Render("Category")+styles.CategoryBadge(task.Category))
	}
	if len(task.Tags) > 0 {
		var tagParts []string
		for _, tag := range task.Tags {
			tagParts = append(tagParts, styles.TagBadge(tag))
		}
		fields = append(fields, labelStyle.Render("Tags")+strings.Join(tagParts, " "))
	}
	if task.MergedInto != "" {
		fields = append(fields, labelStyle.Render("Merged into")+
			lipgloss.NewStyle().Foreground(t.Accent).Render("#"+task.MergedInto))
	}
	if task.ParentTaskID != "" {
		fields = append(fields, labelStyle.Render("Parent")+
			t.Dim.Render("#"+task.ParentTaskID))
	}
	if task.Created > 0 {
		fields = append(fields, labelStyle.Render("Created")+
			valueStyle.Render(time.Unix(task.Created, 0).Format("2006-01-02 15:04:05")))
	}
	if task.Updated > 0 {
		fields = append(fields, labelStyle.Render("Updated")+
			valueStyle.Render(time.Unix(task.Updated, 0).Format("2006-01-02 15:04:05")))
	}
	if task.Result != "" {
		fields = append(fields, labelStyle.Render("Result")+valueStyle.Render(task.Result))
	}
	fieldBlock := lipgloss.NewStyle().Padding(1, 3).Render(strings.Join(fields, "\n"))

	// Description
	descBlock := ""
	if task.Description != "" {
		descWidth := w - 10
		if descWidth < 30 {
			descWidth = 30
		}
		descHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("DESCRIPTION")
		descRule := lipgloss.NewStyle().PaddingLeft(3).
			Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))
		descBody := lipgloss.NewStyle().
			Foreground(t.Muted).
			Width(descWidth).
			Padding(0, 3).
			Render(task.Description)
		descBlock = "\n" + descHeader + "\n" + descRule + "\n" + descBody
	}

	// Attachments
	attachBlock := ""
	if len(task.Attachments) > 0 {
		attHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("LINKS & ATTACHMENTS")
		attRule := lipgloss.NewStyle().PaddingLeft(3).
			Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))
		var attLines []string
		for _, att := range task.Attachments {
			link := lipgloss.NewStyle().Foreground(t.Accent).Render(att)
			attLines = append(attLines, "  \U0001F517 "+link)
		}
		attachBlock = "\n" + attHeader + "\n" + attRule + "\n" +
			lipgloss.NewStyle().Padding(0, 3).Render(strings.Join(attLines, "\n"))
	}

	// Subtasks
	subtaskBlock := ""
	if subs, ok := m.subtaskMap[task.ID]; ok && len(subs) > 0 {
		// Count done/total for progress
		doneCount := 0
		for _, st := range subs {
			if st.Status == "done" {
				doneCount++
			}
		}
		total := len(subs)

		// Progress bar
		barWidth := 20
		filled := 0
		if total > 0 {
			filled = (doneCount * barWidth) / total
		}
		bar := lipgloss.NewStyle().Foreground(t.Success).Render(strings.Repeat("█", filled)) +
			lipgloss.NewStyle().Foreground(t.Muted).Render(strings.Repeat("░", barWidth-filled))
		progressLabel := fmt.Sprintf(" %d/%d", doneCount, total)
		progressLine := "   " + bar + t.Dim.Render(progressLabel)

		subHeader := t.SectionHeader.Copy().PaddingLeft(3).
			Render(fmt.Sprintf("SUBTASKS (%d/%d)", doneCount, total))
		subRule := lipgloss.NewStyle().PaddingLeft(3).
			Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))

		var subLines []string
		subLines = append(subLines, progressLine)
		now := time.Now()
		for _, st := range subs {
			dot := lipgloss.NewStyle().Foreground(t.Muted).Render("○")
			switch st.Status {
			case "done":
				dot = lipgloss.NewStyle().Foreground(t.Success).Render("●")
			case "active":
				dot = lipgloss.NewStyle().Foreground(t.Warning).Render("●")
			case "failed":
				dot = lipgloss.NewStyle().Foreground(t.Danger).Render("✕")
			}
			pane := lipgloss.NewStyle().Foreground(t.Accent).Render(st.Pane)
			title := valueStyle.Render(st.Title)
			age := ""
			if st.Created > 0 {
				age = t.Faint.Render(formatAge(now.Sub(time.Unix(st.Created, 0))))
			}
			subLines = append(subLines, fmt.Sprintf("  %s %-6s %s  %s", dot, pane, title, age))
		}
		subtaskBlock = "\n" + subHeader + "\n" + subRule + "\n" +
			lipgloss.NewStyle().Padding(0, 3).Render(strings.Join(subLines, "\n"))
	}

	// Activity Log
	logBlock := ""
	if len(task.Logs) > 0 {
		logHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("ACTIVITY LOG")
		logRule := lipgloss.NewStyle().PaddingLeft(3).
			Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))

		// Reverse chronological — most recent first
		logs := task.Logs
		reversed := make([]runtime.PersistentTaskLog, len(logs))
		for i, l := range logs {
			reversed[len(logs)-1-i] = l
		}

		maxEntries := 10
		truncated := 0
		if len(reversed) > maxEntries {
			truncated = len(reversed) - maxEntries
			reversed = reversed[:maxEntries]
		}

		now := time.Now()
		var logLines []string
		for _, entry := range reversed {
			age := "     "
			if entry.Timestamp > 0 {
				age = fmt.Sprintf("%-5s", formatAge(now.Sub(time.Unix(entry.Timestamp, 0))))
			}
			ts := t.Faint.Render(age)
			text := lipgloss.NewStyle().Foreground(t.Muted).Render(entry.Entry)
			logLines = append(logLines, "  "+ts+" "+text)
		}
		if truncated > 0 {
			logLines = append(logLines, t.Faint.Render(fmt.Sprintf("  (%d more)", truncated)))
		}

		logBlock = "\n" + logHeader + "\n" + logRule + "\n" +
			lipgloss.NewStyle().Padding(0, 3).Render(strings.Join(logLines, "\n"))
	}

	// Blockers — highlighted red
	blockerBlock := ""
	if task.Blockers != "" {
		bHeader := lipgloss.NewStyle().Bold(true).Foreground(t.Danger).PaddingLeft(3).
			Render("⚠ BLOCKERS")
		bRule := lipgloss.NewStyle().PaddingLeft(3).
			Render(lipgloss.NewStyle().Foreground(t.Danger).Render(strings.Repeat("\u2500", w-6)))
		bBody := lipgloss.NewStyle().
			Foreground(t.Danger).
			Width(w - 10).
			Padding(0, 3).
			Render(task.Blockers)
		blockerBlock = "\n" + bHeader + "\n" + bRule + "\n" + bBody
	}

	// Acceptance Criteria
	criteriaBlock := ""
	if task.AcceptanceCriteria != "" {
		acHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("ACCEPTANCE CRITERIA")
		acRule := lipgloss.NewStyle().PaddingLeft(3).
			Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))
		// Render each line as a checklist item
		var acLines []string
		for _, line := range strings.Split(task.AcceptanceCriteria, "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			acLines = append(acLines, "  "+lipgloss.NewStyle().Foreground(t.Muted).Render("□")+" "+valueStyle.Render(line))
		}
		if len(acLines) > 0 {
			criteriaBlock = "\n" + acHeader + "\n" + acRule + "\n" +
				lipgloss.NewStyle().Padding(0, 3).Render(strings.Join(acLines, "\n"))
		}
	}

	// Decision Log (last 3 entries)
	decisionBlock := ""
	if task.DecisionLog != "" {
		dlHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("DECISIONS")
		dlRule := lipgloss.NewStyle().PaddingLeft(3).
			Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))
		lines := strings.Split(strings.TrimSpace(task.DecisionLog), "\n")
		// Show last 3
		start := 0
		if len(lines) > 3 {
			start = len(lines) - 3
		}
		var dlLines []string
		for _, line := range lines[start:] {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			dlLines = append(dlLines, "  "+lipgloss.NewStyle().Foreground(t.Accent).Render("→")+" "+
				lipgloss.NewStyle().Foreground(t.Muted).Render(line))
		}
		if start > 0 {
			dlLines = append(dlLines, t.Faint.Render(fmt.Sprintf("  (%d more)", start)))
		}
		if len(dlLines) > 0 {
			decisionBlock = "\n" + dlHeader + "\n" + dlRule + "\n" +
				lipgloss.NewStyle().Padding(0, 3).Render(strings.Join(dlLines, "\n"))
		}
	}

	// Notes (truncated to 5 lines)
	notesBlock := ""
	if task.Notes != "" {
		nHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("NOTES")
		nRule := lipgloss.NewStyle().PaddingLeft(3).
			Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))
		lines := strings.Split(strings.TrimSpace(task.Notes), "\n")
		truncated := false
		if len(lines) > 5 {
			lines = lines[:5]
			truncated = true
		}
		body := lipgloss.NewStyle().
			Foreground(t.Muted).
			Width(w - 10).
			Padding(0, 3).
			Render(strings.Join(lines, "\n"))
		if truncated {
			body += "\n" + lipgloss.NewStyle().PaddingLeft(3).Render(t.Faint.Render("  (truncated)"))
		}
		notesBlock = "\n" + nHeader + "\n" + nRule + "\n" + body
	}

	content := header + "\n" + rule + "\n" + backHint + "\n" + fieldBlock +
		blockerBlock + descBlock + criteriaBlock + attachBlock + subtaskBlock +
		decisionBlock + notesBlock + logBlock
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}
