package model

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
	"github.com/doey-cli/doey/tui/internal/taskcard"
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
	entries       []runtime.PersistentTask              // from persistent store + merged runtime
	subtaskMap    map[string][]runtime.Subtask          // task ID -> subtasks
	heartbeats    map[string]runtime.HeartbeatState     // task ID -> live heartbeat
	messages      []runtime.Message                     // IPC messages from snapshot
	paneStatuses  map[string]runtime.PaneStatus         // pane ID -> live status
	paneResults   map[string]runtime.PaneResult         // pane ID -> results
	theme         styles.Theme

	// Card-based list
	list list.Model

	// Navigation
	summaryMode bool // true = list, false = detail
	keyMap      keys.KeyMap

	// Input modes
	creating  bool   // inline create mode
	inputText string // current input text

	// Expanded card view (nil = not expanded)
	expanded *taskcard.ExpandedCard

	// Layout
	width   int
	height  int
	focused  bool
	showHelp bool // ? key toggles keyboard help overlay
}

// NewTasksModel creates a tasks panel starting in list mode.
func NewTasksModel() TasksModel {
	theme := styles.DefaultTheme()
	delegate := taskcard.NewCardDelegate(theme)
	l := list.New([]list.Item{}, delegate, 0, 0)
	l.SetShowTitle(false)
	l.SetShowStatusBar(false)
	l.SetShowFilter(false)
	l.SetShowHelp(false)
	l.SetShowPagination(true)
	l.KeyMap.CursorUp = key.NewBinding(key.WithKeys("k", "up"))
	l.KeyMap.CursorDown = key.NewBinding(key.WithKeys("j", "down"))

	return TasksModel{
		theme:       theme,
		summaryMode: true,
		keyMap:      keys.DefaultKeyMap(),
		subtaskMap:  make(map[string][]runtime.Subtask),
		list:        l,
	}
}

// Init is a no-op for the tasks sub-model.
func (m TasksModel) Init() tea.Cmd { return nil }

// SetSize updates the panel dimensions.
func (m *TasksModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.list.SetSize(w, h-4)
	if m.expanded != nil {
		m.expanded.Width = w
		m.expanded.Height = h - 4
	}
}

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

	// Aggregate heartbeat state for live activity display
	m.heartbeats = runtime.AggregateHeartbeats(snap)

	// Store IPC messages for expanded card filtering
	m.messages = snap.Messages

	// Cache live pane data for worker assignment indicators
	m.paneStatuses = snap.Panes
	m.paneResults = snap.Results

	// Convert entries to list items
	items := make([]list.Item, len(m.entries))
	for i, entry := range m.entries {
		ti := taskcard.TaskItem{Task: entry}
		if subs, ok := m.subtaskMap[entry.ID]; ok {
			ti.Subtasks = subs
			ti.SubtaskTotal = len(subs)
			for _, s := range subs {
				if s.Status == "done" {
					ti.SubtaskDone++
				}
			}
		}
		items[i] = ti
	}
	m.list.SetItems(items)

	// Update delegate with current heartbeat data
	delegate := taskcard.NewCardDelegate(m.theme)
	delegate.Heartbeats = m.heartbeats
	m.list.SetDelegate(delegate)
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
		// Within active section, sort by heartbeat activity
		ha := m.heartbeats[a.ID]
		hb := m.heartbeats[b.ID]
		// Tasks with busy workers sort highest
		if ha.ActiveWorkers != hb.ActiveWorkers {
			return ha.ActiveWorkers > hb.ActiveWorkers
		}
		// Then by most recent heartbeat activity
		if !ha.LastActivity.Equal(hb.LastActivity) {
			return ha.LastActivity.After(hb.LastActivity)
		}
		// Fall back to task ID for stability
		return a.ID < b.ID
	})
}

// Update handles input modes, detail, and list navigation.
func (m TasksModel) Update(msg tea.Msg) (TasksModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.MouseMsg:
		return m.updateMouse(msg)

	case tea.KeyMsg:
		// Help overlay toggle (works in any mode)
		if msg.String() == "?" {
			m.showHelp = !m.showHelp
			return m, nil
		}
		// Dismiss help with any key when showing
		if m.showHelp {
			m.showHelp = false
			return m, nil
		}

		// Input mode (creating)
		if m.creating {
			return m.updateInput(msg)
		}

		// Detail mode
		if !m.summaryMode {
			return m.updateDetail(msg)
		}

		// List mode
		return m.updateList(msg)
	}

	return m, nil
}

// updateMouse handles all mouse interactions for the tasks panel.
func (m TasksModel) updateMouse(msg tea.MouseMsg) (TasksModel, tea.Cmd) {
	// Dismiss help overlay on any click
	if m.showHelp && msg.Action == tea.MouseActionRelease {
		m.showHelp = false
		return m, nil
	}

	// Expanded card mode
	if !m.summaryMode && m.expanded != nil {
		return m.updateMouseExpanded(msg)
	}

	// List mode — only handle click release to prevent double-fire
	if m.summaryMode && msg.Action == tea.MouseActionRelease {
		for i := range m.entries {
			if zone.Get(fmt.Sprintf("task-card-%d", i)).InBounds(msg) {
				m.list.Select(i)
				// Open expanded card (same as Enter)
				item := m.list.SelectedItem()
				if item == nil {
					return m, nil
				}
				ti := item.(taskcard.TaskItem)
				card := taskcard.ExpandedCard{
					Item:          ti,
					Theme:         m.theme,
					Width:         m.width,
					Height:        m.height - 4,
					SubtaskCursor: -1,
					ScrollOffset:  0,
					Messages:      filterMessagesForTask(m.messages, ti.Task.ID, ti.Task.Team),
					PaneStatuses:  paneStatusSlice(m.paneStatuses),
					Results:       m.paneResults,
				}
				m.expanded = &card
				m.summaryMode = false
				return m, nil
			}
		}
	}

	// Mouse wheel in list mode — forward to list model for scrolling
	if m.summaryMode && msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp || msg.Button == tea.MouseButtonWheelDown {
			var cmd tea.Cmd
			m.list, cmd = m.list.Update(msg)
			return m, cmd
		}
	}

	return m, nil
}

// updateMouseExpanded handles mouse in expanded card view.
func (m TasksModel) updateMouseExpanded(msg tea.MouseMsg) (TasksModel, tea.Cmd) {
	// Click release — check zones
	if msg.Action == tea.MouseActionRelease {
		// Close button
		if zone.Get("detail-close").InBounds(msg) {
			m.expanded = nil
			m.summaryMode = true
			return m, nil
		}
		// Subtask clicks
		for i := range m.expanded.Item.Subtasks {
			if zone.Get(fmt.Sprintf("subtask-%d", i)).InBounds(msg) {
				m.expanded.SubtaskCursor = i
				return m, nil
			}
		}
	}

	// Mouse wheel — scroll expanded card
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp {
			if m.expanded.ScrollOffset > 0 {
				m.expanded.ScrollOffset--
			}
			return m, nil
		}
		if msg.Button == tea.MouseButtonWheelDown {
			maxOff := m.expanded.ContentHeight() - m.expanded.Height
			if maxOff < 0 {
				maxOff = 0
			}
			if m.expanded.ScrollOffset < maxOff {
				m.expanded.ScrollOffset++
			}
			return m, nil
		}
	}

	return m, nil
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

	// Handle custom keys first
	switch msg.String() {
	case "n":
		m.creating = true
		m.inputText = ""
		return m, nil
	case "enter":
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		card := taskcard.ExpandedCard{
			Item:          ti,
			Theme:         m.theme,
			Width:         m.width,
			Height:        m.height - 4,
			SubtaskCursor: -1,
			ScrollOffset:  0,
			Messages:      filterMessagesForTask(m.messages, ti.Task.ID, ti.Task.Team),
			PaneStatuses:  paneStatusSlice(m.paneStatuses),
			Results:       m.paneResults,
		}
		m.expanded = &card
		m.summaryMode = false
		return m, nil
	case "m":
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		task := ti.Task
		next := nextMoveStatus(task.Status)
		return m, func() tea.Msg {
			return MoveTaskMsg{ID: task.ID, Status: next}
		}
	case "d":
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		task := ti.Task
		return m, func() tea.Msg {
			return DispatchTaskMsg{ID: task.ID, Title: task.Title}
		}
	case "s":
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		task := ti.Task
		next := nextStatus(task.Status)
		return m, func() tea.Msg {
			return SetStatusTaskMsg{ID: task.ID, Status: next}
		}
	case "x":
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		task := ti.Task
		return m, func() tea.Msg {
			return CancelTaskMsg{ID: task.ID}
		}
	}

	// Delegate everything else (j/k/scroll) to the list model
	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	return m, cmd
}

func (m TasksModel) updateDetail(msg tea.KeyMsg) (TasksModel, tea.Cmd) {
	total := len(m.entries)
	if total == 0 {
		m.summaryMode = true
		m.expanded = nil
		return m, nil
	}

	idx := m.list.Index()

	// Expanded card mode — handle scrolling and subtask nav
	if m.expanded != nil {
		switch msg.String() {
		case "enter", "esc":
			m.expanded = nil
			m.summaryMode = true
			return m, nil
		case "tab":
			n := len(m.expanded.Item.Subtasks)
			if n > 0 {
				if m.expanded.SubtaskCursor >= n-1 {
					m.expanded.SubtaskCursor = -1
				} else {
					m.expanded.SubtaskCursor++
				}
			}
			return m, nil
		case "shift+tab":
			n := len(m.expanded.Item.Subtasks)
			if n > 0 {
				if m.expanded.SubtaskCursor <= -1 {
					m.expanded.SubtaskCursor = n - 1
				} else {
					m.expanded.SubtaskCursor--
				}
			}
			return m, nil
		case "up", "k":
			if m.expanded.ScrollOffset > 0 {
				m.expanded.ScrollOffset--
			}
			return m, nil
		case "down", "j":
			maxOff := m.expanded.ContentHeight() -
				m.expanded.Height
			if maxOff < 0 {
				maxOff = 0
			}
			if m.expanded.ScrollOffset < maxOff {
				m.expanded.ScrollOffset++
			}
			return m, nil
		case "m":
			task := m.expanded.Item.Task
			next := nextMoveStatus(task.Status)
			return m, func() tea.Msg {
				return MoveTaskMsg{
					ID: task.ID, Status: next,
				}
			}
		case "s":
			task := m.expanded.Item.Task
			next := nextStatus(task.Status)
			return m, func() tea.Msg {
				return SetStatusTaskMsg{
					ID: task.ID, Status: next,
				}
			}
		case "d":
			task := m.expanded.Item.Task
			return m, func() tea.Msg {
				return DispatchTaskMsg{
					ID: task.ID, Title: task.Title,
				}
			}
		case "x":
			task := m.expanded.Item.Task
			return m, func() tea.Msg {
				return CancelTaskMsg{ID: task.ID}
			}
		}
		return m, nil
	}

	// Legacy detail mode (fallback)
	switch {
	case key.Matches(msg, m.keyMap.Back):
		m.summaryMode = true
	default:
		switch msg.String() {
		case "m":
			if idx >= 0 && idx < total {
				task := m.entries[idx]
				next := nextMoveStatus(task.Status)
				return m, func() tea.Msg {
					return MoveTaskMsg{ID: task.ID, Status: next}
				}
			}
		case "s":
			if idx >= 0 && idx < total {
				task := m.entries[idx]
				next := nextStatus(task.Status)
				return m, func() tea.Msg {
					return SetStatusTaskMsg{ID: task.ID, Status: next}
				}
			}
		case "d":
			if idx >= 0 && idx < total {
				task := m.entries[idx]
				return m, func() tea.Msg {
					return DispatchTaskMsg{ID: task.ID, Title: task.Title}
				}
			}
		case "x":
			if idx >= 0 && idx < total {
				task := m.entries[idx]
				return m, func() tea.Msg {
					return CancelTaskMsg{ID: task.ID}
				}
			}
		}
	}

	return m, nil
}

// nextMoveStatus cycles through the main statuses: active -> in_progress -> done -> active.
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

// filterMessagesForTask returns IPC messages relevant to the given task,
// sorted chronologically (oldest first).
func filterMessagesForTask(messages []runtime.Message, taskID string, taskTeam string) []runtime.Message {
	var filtered []runtime.Message
	idPattern := fmt.Sprintf("Task #%s", taskID)
	idPattern2 := fmt.Sprintf("task_%s", taskID)
	idPattern3 := fmt.Sprintf("#%s", taskID)
	for _, msg := range messages {
		bodyLower := strings.ToLower(msg.Body)
		subjectLower := strings.ToLower(msg.Subject)

		// Check if message mentions this task by ID
		if strings.Contains(msg.Body, idPattern) ||
			strings.Contains(bodyLower, strings.ToLower(idPattern2)) ||
			strings.Contains(msg.Body, idPattern3) {
			filtered = append(filtered, msg)
			continue
		}

		// Check if message is from/to the task's team with a task-related subject
		if taskTeam != "" && (strings.Contains(msg.From, taskTeam) || strings.Contains(msg.To, taskTeam)) {
			if subjectLower == "task_complete" || subjectLower == "worker_finished" ||
				subjectLower == "commit_request" {
				filtered = append(filtered, msg)
			}
		}
	}
	sort.Slice(filtered, func(i, j int) bool {
		return filtered[i].Timestamp < filtered[j].Timestamp
	})
	return filtered
}

// paneStatusSlice converts a pane status map to a slice for the expanded card.
func paneStatusSlice(m map[string]runtime.PaneStatus) []runtime.PaneStatus {
	if m == nil {
		return nil
	}
	out := make([]runtime.PaneStatus, 0, len(m))
	for _, ps := range m {
		out = append(out, ps)
	}
	return out
}

// View renders list, expanded card, or detail mode.
func (m TasksModel) View() string {
	if m.showHelp {
		return m.viewHelp()
	}
	if m.summaryMode {
		return m.viewList()
	}
	if m.expanded != nil {
		return m.viewExpanded()
	}
	return m.viewDetail()
}

// viewExpanded renders the expanded card with header.
func (m TasksModel) viewExpanded() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}
	task := m.expanded.Item.Task
	headerText := fmt.Sprintf("TASK — #%s", task.ID)
	if ws := m.workerSummaryForTask(task.ID); ws != "" {
		headerText += "  " + ws
	}
	header := t.SectionHeader.Copy().PaddingLeft(2).Render(headerText)
	rule := t.Faint.Render(strings.Repeat("─", w))
	body := m.expanded.ViewportSlice()
	closeHint := zone.Mark("detail-close", "enter/esc close")
	hint := styles.FooterHintBarStyle(t).
		Render("↑/↓ scroll  " + closeHint + "  tab subtask  m move  s status  ? help")
	content := header + "\n" + rule + "\n" + body + "\n" + hint
	return lipgloss.NewStyle().
		Width(w).Height(m.height).Render(content)
}

// viewHelp renders a floating keyboard help overlay.
func (m TasksModel) viewHelp() string {
	t := m.theme
	w := m.width
	if w > styles.MaxCardWidth {
		w = styles.MaxCardWidth
	}

	title := lipgloss.NewStyle().Bold(true).Foreground(t.Primary).
		Render("⌨  Keyboard Shortcuts")
	sep := t.Faint.Render(strings.Repeat("─", w-6))

	keyStyle := styles.HelpKeyStyle(t)
	descStyle := styles.HelpDescStyle(t)

	bindings := []struct{ key, desc string }{
		{"j / k", "Navigate cards up/down"},
		{"Enter", "Expand selected card"},
		{"Esc", "Collapse / go back"},
		{"n", "Create new task"},
		{"m", "Move task (active → in_progress → done)"},
		{"s", "Cycle through all statuses"},
		{"d", "Dispatch task to a team"},
		{"x", "Cancel task"},
		{"Tab", "Next subtask (expanded view)"},
		{"Shift+Tab", "Previous subtask (expanded view)"},
		{"↑ / ↓", "Scroll expanded card"},
		{"?", "Toggle this help"},
	}

	var rows []string
	for _, b := range bindings {
		rows = append(rows, keyStyle.Render(b.key)+descStyle.Render(b.desc))
	}

	hint := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).
		Render("Press any key to dismiss")

	content := title + "\n" + sep + "\n\n" + strings.Join(rows, "\n") + "\n\n" + hint

	overlay := styles.HelpOverlayStyle(t, w).Render(content)

	// Center vertically
	topPad := (m.height - lipgloss.Height(overlay)) / 2
	if topPad < 0 {
		topPad = 0
	}

	return lipgloss.NewStyle().
		Width(m.width).
		Height(m.height).
		PaddingTop(topPad).
		Render(overlay)
}

func (m TasksModel) viewList() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	// Cap card content area for readability
	listWidth := w
	if listWidth > styles.MaxCardWidth {
		listWidth = styles.MaxCardWidth
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("TASKS")
	rule := t.Faint.Render(strings.Repeat("\u2500", listWidth))

	if len(m.entries) == 0 {
		icon := styles.EmptyStateIcon(t)
		title := styles.EmptyStateTitle(t)
		hint := styles.EmptyStateHint(t)

		emptyBox := lipgloss.NewStyle().
			Align(lipgloss.Center).
			Width(w).
			PaddingTop(2).
			Render(icon + "\n\n" + title + "\n" + hint)

		content := header + "\n" + rule + "\n" + emptyBox
		if m.creating {
			content += "\n" + m.renderInputBar()
		}
		return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
	}

	summary := m.taskSummary()

	// Use the list view instead of manual rows
	listView := m.list.View()

	hint := ""
	if m.focused && !m.creating {
		hint = styles.FooterHintBarStyle(t).
			Render("j/k navigate  enter detail  n new  m move  s status  d dispatch  x cancel  ? help")
	}

	content := header + "\n" + rule + "\n" + summary + "\n" + listView + "\n" + hint
	if m.creating {
		content += "\n" + m.renderInputBar()
	}
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}

// taskSummary returns section counts with live worker assignment info.
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

	// Count total busy workers across all tasks
	busyWorkers := 0
	for _, hs := range m.heartbeats {
		busyWorkers += hs.ActiveWorkers
	}
	if busyWorkers > 0 {
		label := fmt.Sprintf("%d worker", busyWorkers)
		if busyWorkers != 1 {
			label += "s"
		}
		parts = append(parts, styles.SectionPill(label+" active", t.Warning))
	}

	if len(parts) > 0 {
		return total + "  " + strings.Join(parts, " ")
	}
	return total
}

// workerSummaryForTask returns a compact live status string for a task.
// Checks heartbeat data and pane statuses for workers assigned to this task.
func (m TasksModel) workerSummaryForTask(taskID string) string {
	t := m.theme
	hs, ok := m.heartbeats[taskID]
	if !ok || hs.ActiveWorkers == 0 {
		// Check pane statuses as fallback — match task title
		return ""
	}

	dot := lipgloss.NewStyle().Foreground(t.Success).Render("●")
	if hs.Health == "degraded" || hs.Health == "amber" {
		dot = lipgloss.NewStyle().Foreground(t.Warning).Render("●")
	} else if hs.Health == "stale" || hs.Health == "red" {
		dot = lipgloss.NewStyle().Foreground(t.Danger).Render("●")
	}

	label := fmt.Sprintf("%d worker", hs.ActiveWorkers)
	if hs.ActiveWorkers != 1 {
		label += "s"
	}
	return dot + " " + lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render(label+" active")
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

	idx := m.list.Index()
	if idx < 0 || idx >= len(m.entries) {
		m.summaryMode = true
		return m.viewList()
	}

	task := m.entries[idx]

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

	// Live worker assignment
	if ws := m.workerSummaryForTask(task.ID); ws != "" {
		fields = append(fields, labelStyle.Render("Workers")+ws)
	}

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
		bar := lipgloss.NewStyle().Foreground(t.Success).Render(strings.Repeat("\u2588", filled)) +
			lipgloss.NewStyle().Foreground(t.Muted).Render(strings.Repeat("\u2591", barWidth-filled))
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
			dot := lipgloss.NewStyle().Foreground(t.Muted).Render("\u25CB")
			switch st.Status {
			case "done":
				dot = lipgloss.NewStyle().Foreground(t.Success).Render("\u25CF")
			case "active":
				dot = lipgloss.NewStyle().Foreground(t.Warning).Render("\u25CF")
			case "failed":
				dot = lipgloss.NewStyle().Foreground(t.Danger).Render("\u2715")
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
			Render("\u26A0 BLOCKERS")
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
			acLines = append(acLines, "  "+lipgloss.NewStyle().Foreground(t.Muted).Render("\u25A1")+" "+valueStyle.Render(line))
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
			dlLines = append(dlLines, "  "+lipgloss.NewStyle().Foreground(t.Accent).Render("\u2192")+" "+
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
