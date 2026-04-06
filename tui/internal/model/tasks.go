package model

import (
	"fmt"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
	"github.com/doey-cli/doey/tui/internal/taskcard"
)

// SwitchToPlanMsg requests the root model to switch to the Plans tab for a specific plan.
type SwitchToPlanMsg struct{ PlanID string }

// taskStatusClearMsg clears the status message after a delay.
type taskStatusClearMsg struct{}

// taskStatusClearCmd returns a command that clears the status message after 2 seconds.
func taskStatusClearCmd() tea.Cmd {
	return tea.Tick(2*time.Second, func(time.Time) tea.Msg { return taskStatusClearMsg{} })
}

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
		return lipgloss.NewStyle().Foreground(t.Danger).Render("✗")
	case "deferred":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("⏸")
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

// attachmentEmoji returns an emoji for the attachment type.
func attachmentEmoji(t string) string {
	switch t {
	case "research":
		return "🔍"
	case "build":
		return "🔨"
	case "test":
		return "✅"
	case "review":
		return "👁"
	case "error":
		return "⚠️"
	case "progress":
		return "📊"
	case "completion":
		return "🏁"
	case "decision":
		return "⚖️"
	case "report":
		return "📋"
	default:
		return "📄"
	}
}

// extractPlanSteps parses markdown content and extracts numbered/bulleted items or heading lines.
// If limit > 0, returns at most that many lines. If limit == 0, returns all.
func extractPlanSteps(content string, limit int) []string {
	var steps []string
	for _, line := range strings.Split(content, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		// Match numbered items (1. ..., 1) ...), bullets (- ..., * ...), or headings (## ...)
		isStep := false
		if len(trimmed) > 2 {
			if trimmed[0] >= '0' && trimmed[0] <= '9' {
				// Numbered: "1. text" or "1) text"
				for i := 1; i < len(trimmed); i++ {
					if trimmed[i] == '.' || trimmed[i] == ')' {
						isStep = true
						break
					}
					if trimmed[i] < '0' || trimmed[i] > '9' {
						break
					}
				}
			}
			if trimmed[0] == '-' || trimmed[0] == '*' || strings.HasPrefix(trimmed, "##") {
				isStep = true
			}
		}
		if isStep {
			steps = append(steps, trimmed)
			if limit > 0 && len(steps) >= limit {
				break
			}
		}
	}
	return steps
}

// renderFileTree builds a directory-grouped file tree from task and result file lists.
func renderFileTree(t styles.Theme, taskFiles []string, result *runtime.TaskResult) string {
	// Merge and dedup
	seen := make(map[string]bool)
	var allFiles []string
	for _, f := range taskFiles {
		if f != "" && !seen[f] {
			seen[f] = true
			allFiles = append(allFiles, f)
		}
	}
	if result != nil {
		for _, f := range result.FilesChanged {
			if f != "" && !seen[f] {
				seen[f] = true
				allFiles = append(allFiles, f)
			}
		}
	}
	if len(allFiles) == 0 {
		return ""
	}

	// Group by directory
	dirFiles := make(map[string][]string)
	for _, f := range allFiles {
		dir := filepath.Dir(f)
		if dir == "." {
			dir = ""
		}
		base := filepath.Base(f)
		dirFiles[dir] = append(dirFiles[dir], base)
	}

	// Sort directories and files within each
	var dirs []string
	for d := range dirFiles {
		dirs = append(dirs, d)
	}
	sort.Strings(dirs)
	for _, d := range dirs {
		sort.Strings(dirFiles[d])
	}

	totalFiles := len(allFiles)
	cap := 20
	overflow := 0
	if totalFiles > cap {
		overflow = totalFiles - cap
	}

	sep := lipgloss.NewStyle().Foreground(t.Separator)
	dirStyle := lipgloss.NewStyle().Foreground(t.Accent).Bold(true)
	fileStyle := lipgloss.NewStyle().Foreground(t.Text)

	var lines []string
	lines = append(lines, sep.Render("╭ ")+lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(fmt.Sprintf("Files Changed (%d)", totalFiles)))

	remaining := cap
	for _, dir := range dirs {
		if remaining <= 0 {
			break
		}
		displayDir := dir
		if displayDir == "" {
			displayDir = "./"
		} else {
			displayDir += "/"
		}
		lines = append(lines, sep.Render("│  ")+dirStyle.Render(displayDir))

		files := dirFiles[dir]
		if len(files) > remaining {
			files = files[:remaining]
		}
		for i, f := range files {
			connector := "├─"
			if i == len(files)-1 {
				connector = "└─"
			}
			lines = append(lines, sep.Render("│    ")+sep.Render(connector+" ")+fileStyle.Render(f))
			remaining--
		}
	}

	if overflow > 0 {
		lines = append(lines, sep.Render("│  ")+lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render(fmt.Sprintf("... and %d more", overflow)))
	}
	lines = append(lines, sep.Render("╰"))

	return strings.Join(lines, "\n")
}

// TasksModel displays tasks in a split-pane layout with list left, detail right.
type TasksModel struct {
	SplitPaneModel

	// Data
	entries      []runtime.PersistentTask
	subtaskMap   map[string][]runtime.Subtask
	heartbeats   map[string]runtime.HeartbeatState
	messages     []runtime.Message
	paneStatuses map[string]runtime.PaneStatus
	paneResults  map[string]runtime.PaneResult
	events       []runtime.Event

	// Input modes
	creating  bool
	inputText string

	// Expanded card (used for subtask nav in right panel)
	expanded         *taskcard.ExpandedCard
	expandedSubtasks map[int]bool // tracks which subtasks are toggled open in detail view

	// Sidecar/result for detail view
	detailSidecar *runtime.TaskSidecar
	detailResult  *runtime.TaskResult
	detailPlan    *runtime.Plan
	projectDir    string

	// UI state
	showHelp bool
}

// NewTasksModel creates a tasks panel starting with left panel focused.
func NewTasksModel() TasksModel {
	theme := styles.DefaultTheme()
	delegate := taskcard.NewCardDelegate(theme)
	return TasksModel{
		SplitPaneModel: NewSplitPane(theme, delegate, SplitPaneConfig{
			CardHeight:     2,
			HeaderLines:    2,
			HasSeparator:   false,
			VPHeightOffset: 3,
			VPWidthPad:     3,
		}),
		subtaskMap: make(map[string][]runtime.Subtask),
	}
}

// Init is a no-op for the tasks sub-model.
func (m TasksModel) Init() tea.Cmd { return nil }

// SetSize updates the panel dimensions.
func (m *TasksModel) SetSize(w, h int) {
	m.SplitPaneModel.SetSize(w, h)
	rightW := m.RightWidth()
	vpH := h - m.config.VPHeightOffset
	if vpH < 1 {
		vpH = 1
	}
	if m.expanded != nil {
		m.expanded.Width = rightW - m.config.VPWidthPad
		m.expanded.Height = vpH
	}
}

// SetSnapshot merges persistent + runtime tasks and rebuilds the view.
func (m *TasksModel) SetSnapshot(snap runtime.Snapshot) {
	runtime.SetProjectDir(snap.Session.ProjectDir)
	m.projectDir = snap.Session.ProjectDir
	store, _ := runtime.ReadTaskStore()
	store.MergeRuntimeTasks(snap.Tasks)

	m.entries = store.Tasks

	// Aggregate heartbeat state BEFORE sorting — sortEntries uses heartbeats
	m.heartbeats = runtime.AggregateHeartbeats(snap)
	m.sortEntries()

	// Build subtask map
	m.subtaskMap = make(map[string][]runtime.Subtask)
	for _, st := range snap.Subtasks {
		m.subtaskMap[st.TaskID] = append(m.subtaskMap[st.TaskID], st)
	}

	// Store IPC messages for expanded card filtering
	m.messages = snap.Messages

	// Cache live pane data for worker assignment indicators
	m.paneStatuses = snap.Panes
	m.paneResults = snap.Results
	m.events = snap.Events

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
				} else if s.Status == "deferred" {
					ti.SubtaskDeferred++
				}
			}
		}
		// Fallback: if no runtime subtasks but persistent task has them, use persistent counts
		if ti.SubtaskTotal == 0 && len(entry.Subtasks) > 0 {
			ti.SubtaskTotal = len(entry.Subtasks)
			for _, ps := range entry.Subtasks {
				if ps.Status == "done" {
					ti.SubtaskDone++
				} else if ps.Status == "deferred" {
					ti.SubtaskDeferred++
				}
			}
		}
		items[i] = ti
	}
	prevIdx := m.list.Index()
	m.list.SetItems(items)
	if len(items) > 0 {
		if prevIdx >= len(items) {
			prevIdx = len(items) - 1
		}
		if prevIdx < 0 {
			prevIdx = 0
		}
		m.list.Select(prevIdx)
	}

	// Update delegate with current heartbeat data
	delegate := taskcard.NewCardDelegate(m.theme)
	delegate.Heartbeats = m.heartbeats
	m.list.SetDelegate(delegate)

	// Refresh expanded detail card with updated snapshot data
	if m.expanded != nil {
		m.loadSelectedDetail()
	}
}

// statusPriority returns a sort group for the given task status.
// Lower values sort to the top of the list.
func statusPriority(status string) int {
	switch status {
	case "active", "in_progress":
		return 0
	case "paused", "blocked":
		return 1
	case "pending_user_confirmation":
		return 2
	case "draft":
		return 3
	case "done", "cancelled":
		return 4
	default:
		return 3 // unknown statuses sort with drafts
	}
}

// taskActivityTime returns the best activity timestamp for a task:
// heartbeat LastActivity > task Updated > task Created.
func (m *TasksModel) taskActivityTime(t runtime.PersistentTask) time.Time {
	if hb, ok := m.heartbeats[t.ID]; ok && !hb.LastActivity.IsZero() {
		return hb.LastActivity
	}
	if t.Updated > 0 {
		return time.Unix(t.Updated, 0)
	}
	if t.Created > 0 {
		return time.Unix(t.Created, 0)
	}
	return time.Time{}
}

func (m *TasksModel) sortEntries() {
	sort.SliceStable(m.entries, func(i, j int) bool {
		a, b := m.entries[i], m.entries[j]
		// Sort by most recently updated first (TASK_UPDATED descending).
		// Tasks with no update timestamp sort to the bottom.
		ta, tb := m.taskActivityTime(a), m.taskActivityTime(b)
		if !ta.Equal(tb) {
			return ta.After(tb)
		}
		// Tiebreaker: task ID descending (newest first).
		ai, errA := strconv.Atoi(a.ID)
		bi, errB := strconv.Atoi(b.ID)
		if errA == nil && errB == nil {
			return ai > bi
		}
		return a.ID > b.ID
	})

	// Group child tasks immediately after their parent for hierarchy display.
	m.groupChildrenUnderParents()
}

// groupChildrenUnderParents reorders entries so child tasks appear directly
// after their parent task, preserving relative order within each group.
func (m *TasksModel) groupChildrenUnderParents() {
	// Build index of parent positions
	parentIdx := make(map[string]int, len(m.entries))
	hasChildren := false
	for i, e := range m.entries {
		if e.ParentTaskID == "" {
			parentIdx[e.ID] = i
		} else {
			hasChildren = true
		}
	}
	if !hasChildren {
		return
	}

	// Collect parents (in order) and their children
	var result []runtime.PersistentTask
	childrenOf := make(map[string][]runtime.PersistentTask)
	for _, e := range m.entries {
		if e.ParentTaskID != "" {
			childrenOf[e.ParentTaskID] = append(childrenOf[e.ParentTaskID], e)
		}
	}
	for _, e := range m.entries {
		if e.ParentTaskID != "" {
			continue // skip children; they'll be inserted after parent
		}
		result = append(result, e)
		if children, ok := childrenOf[e.ID]; ok {
			result = append(result, children...)
		}
	}
	// Append orphaned children (parent not in list)
	for _, e := range m.entries {
		if e.ParentTaskID != "" {
			if _, ok := parentIdx[e.ParentTaskID]; !ok {
				result = append(result, e)
			}
		}
	}
	m.entries = result
}

// loadSelectedDetail loads sidecar/result data for the currently selected task.
func (m *TasksModel) loadSelectedDetail() {
	idx := m.list.Index()
	if idx < 0 || idx >= len(m.entries) {
		m.detailSidecar = nil
		m.detailResult = nil
		m.expanded = nil
		m.detailViewport.SetContent("")
		return
	}
	task := m.entries[idx]
	item := m.list.SelectedItem()
	if item == nil {
		return
	}
	ti := item.(taskcard.TaskItem)
	leftW := m.width * 40 / 100
	if leftW < 28 {
		leftW = 28
	}
	rightW := m.width - leftW - 1
	if rightW < 24 {
		rightW = 24
	}
	// Preserve subtask cursor if refreshing the same task; reset expanded state on task switch
	prevCursor := -1
	if m.expanded != nil && m.expanded.Item.Task.ID == task.ID {
		prevCursor = m.expanded.SubtaskCursor
	} else {
		m.expandedSubtasks = nil
	}
	m.expanded = &taskcard.ExpandedCard{
		Item:          ti,
		Theme:         m.theme,
		Width:         rightW - 3,
		Height:        m.height - 2,
		SubtaskCursor: prevCursor,
		Messages:      FilterMessagesForTask(m.messages, task.ID, task.Team),
		Events:        m.events,
		PaneStatuses:  paneStatusSlice(m.paneStatuses),
		Results:       m.paneResults,
		ProjectDir:    m.projectDir,
	}
	if m.projectDir != "" {
		tasksDir := filepath.Join(m.projectDir, ".doey", "tasks")
		m.detailSidecar = runtime.ReadTaskSidecar(tasksDir, task.ID)
		m.detailResult = runtime.ReadTaskResult(tasksDir, task.ID)
		m.expanded.Sidecar = m.detailSidecar
		m.expanded.TaskResult = m.detailResult
	}
	// Fetch linked plan if task has a plan_id
	m.detailPlan = nil
	if task.PlanID != "" {
		if pid, err := strconv.Atoi(task.PlanID); err == nil {
			m.detailPlan = runtime.ReadPlan(m.projectDir, pid)
		}
	}

	// Pre-render content into the viewport so Update() can process scroll events.
	// Without this, the viewport has 0 lines and ignores all scroll input.
	savedYOffset := m.detailViewport.YOffset
	m.detailViewport.SetContent(m.expanded.Render())
	// Restore scroll position after content refresh (prevents jump-to-top on tick)
	maxY := m.detailViewport.TotalLineCount() - m.detailViewport.Height
	if maxY < 0 { maxY = 0 }
	if savedYOffset > maxY { savedYOffset = maxY }
	m.detailViewport.SetYOffset(savedYOffset)
}

// Update handles input modes, detail, and list navigation.
func (m TasksModel) Update(msg tea.Msg) (TasksModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg.(type) {
	case taskStatusClearMsg:
		m.statusMsg = ""
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

		// Right panel focused — detail navigation
		if !m.leftFocused {
			return m.updateDetail(msg)
		}

		// Left panel focused — list navigation
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

	// Click release — check zones
	if msg.Action == tea.MouseActionRelease {
		// Action button clicks (zone-based)
		if !m.leftFocused && len(m.entries) > 0 {
			idx := m.list.Index()
			if idx >= 0 && idx < len(m.entries) {
				task := m.entries[idx]

				// Review decision buttons (pending_user_confirmation only)
				if task.Status == "pending_user_confirmation" {
					if zone.Get("task-deny-btn").InBounds(msg) {
						m.statusMsg = "Task denied — sent back"
						return m, tea.Batch(
							func() tea.Msg { return SetStatusTaskMsg{ID: task.ID, Status: "in_progress"} },
							func() tea.Msg { return ReviewVerdictMsg{ID: task.ID, Verdict: "rejected"} },
							taskStatusClearCmd(),
						)
					}
					if zone.Get("task-skip-btn").InBounds(msg) {
						m.statusMsg = "Review skipped — marked done"
						return m, tea.Batch(
							func() tea.Msg { return MoveTaskMsg{ID: task.ID, Status: "done"} },
							func() tea.Msg { return BossMarkDoneMsg{ID: task.ID} },
							taskStatusClearCmd(),
						)
					}
					if zone.Get("task-accept-btn").InBounds(msg) {
						m.statusMsg = "Task accepted"
						return m, tea.Batch(
							func() tea.Msg { return MoveTaskMsg{ID: task.ID, Status: "done"} },
							func() tea.Msg { return BossMarkDoneMsg{ID: task.ID} },
							func() tea.Msg { return ReviewVerdictMsg{ID: task.ID, Verdict: "accepted"} },
							taskStatusClearCmd(),
						)
					}
				}

				// Undo completion button (done tasks only)
				if task.Status == "done" {
					if zone.Get("task-undo-btn").InBounds(msg) {
						m.statusMsg = "Completion undone"
						return m, tea.Batch(func() tea.Msg {
							return SetStatusTaskMsg{ID: task.ID, Status: "pending_user_confirmation"}
						}, taskStatusClearCmd())
					}
				}

				// Standard action buttons (non-review statuses)
				if zone.Get("task-move-btn").InBounds(msg) {
					next := nextMoveStatus(task.Status)
					m.statusMsg = "Task moved"
					moveCmd := func() tea.Msg { return MoveTaskMsg{ID: task.ID, Status: next} }
					if next == "done" {
						bossCmd := func() tea.Msg { return BossMarkDoneMsg{ID: task.ID} }
						return m, tea.Batch(moveCmd, bossCmd, taskStatusClearCmd())
					}
					return m, tea.Batch(moveCmd, taskStatusClearCmd())
				}
				if zone.Get("task-dispatch-btn").InBounds(msg) {
					m.statusMsg = "Task dispatched"
					return m, tea.Batch(func() tea.Msg {
						return DispatchTaskMsg{ID: task.ID, Title: task.Title}
					}, taskStatusClearCmd())
				}
				if zone.Get("task-status-btn").InBounds(msg) {
					next := nextStatus(task.Status)
					m.statusMsg = "Status updated"
					return m, tea.Batch(func() tea.Msg {
						return SetStatusTaskMsg{ID: task.ID, Status: next}
					}, taskStatusClearCmd())
				}
				if zone.Get("task-cancel-btn").InBounds(msg) {
					m.statusMsg = "Task cancelled"
					cancelCmd := func() tea.Msg { return CancelTaskMsg{ID: task.ID} }
					bossCmd := func() tea.Msg { return BossCancelTaskBossMsg{ID: task.ID} }
					return m, tea.Batch(cancelCmd, bossCmd, taskStatusClearCmd())
				}
			}
		}

		// Card clicks in left panel — Y-coordinate math
		leftW := m.width * 40 / 100
		if leftW < 28 {
			leftW = 28
		}
		if msg.X < leftW && len(m.entries) > 0 {
			const cardHeight = 3
			const headerLines = 2 // "TASKS" header + summary line
			relY := msg.Y - m.panelOffsetY - headerLines
			if relY >= 0 {
				firstVisible := m.list.Paginator.Page * m.list.Paginator.PerPage
				index := firstVisible + relY/cardHeight
				perPage := m.list.Paginator.PerPage
				if index >= firstVisible+perPage {
					return m, nil
				}
				if index >= 0 && index < len(m.entries) {
					m.list.Select(index)
					m.leftFocused = false
					m.detailViewport.GotoTop()
					m.loadSelectedDetail()
					return m, nil
				}
			}
		}
		// Subtask clicks in right panel — toggle expanded details
		if !m.leftFocused && m.expanded != nil {
			for i := range m.expanded.Item.Subtasks {
				if zone.Get(fmt.Sprintf("subtask-%d", i)).InBounds(msg) {
					m.expanded.SubtaskCursor = i
					if m.expandedSubtasks == nil {
						m.expandedSubtasks = make(map[int]bool)
					}
					m.expandedSubtasks[i] = !m.expandedSubtasks[i]
					// Re-render detail with updated expanded state
					m.detailViewport.SetContent(m.expanded.Render())
					return m, nil
				}
			}
			// Also check persistent subtask zones
			for i := range m.expanded.Item.Task.Subtasks {
				if zone.Get(fmt.Sprintf("subtask-%d", i)).InBounds(msg) {
					m.expanded.SubtaskCursor = i
					if m.expandedSubtasks == nil {
						m.expandedSubtasks = make(map[int]bool)
					}
					m.expandedSubtasks[i] = !m.expandedSubtasks[i]
					m.detailViewport.SetContent(m.expanded.Render())
					return m, nil
				}
			}
		}
	}

	// Mouse wheel — route based on cursor position, not focus state
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp || msg.Button == tea.MouseButtonWheelDown {
			leftW := m.width * 40 / 100
			if leftW < 28 {
				leftW = 28
			}
			if msg.X < leftW {
				var cmd tea.Cmd
				m.list, cmd = m.list.Update(msg)
				return m, cmd
			}
			var cmd tea.Cmd
			m.detailViewport, cmd = m.detailViewport.Update(msg)
			return m, cmd
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

	switch {
	// Focus right panel
	case key.Matches(msg, m.keyMap.RightPanel), key.Matches(msg, m.keyMap.Select):
		if total > 0 {
			m.leftFocused = false
			m.detailViewport.GotoTop()
			m.loadSelectedDetail()
		}
		return m, nil
	}

	// Handle custom keys
	switch msg.String() {
	case "n":
		m.creating = true
		m.inputText = ""
		return m, nil
	case "a":
		// Accept (pending_user_confirmation only)
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		task := ti.Task
		if task.Status == "pending_user_confirmation" {
			m.statusMsg = "Task accepted"
			return m, tea.Batch(
				func() tea.Msg { return MoveTaskMsg{ID: task.ID, Status: "done"} },
				func() tea.Msg { return BossMarkDoneMsg{ID: task.ID} },
				func() tea.Msg { return ReviewVerdictMsg{ID: task.ID, Verdict: "accepted"} },
				taskStatusClearCmd(),
			)
		}
		return m, nil
	case "m":
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		task := ti.Task
		next := nextMoveStatus(task.Status)
		m.statusMsg = "Task moved"
		moveCmd := func() tea.Msg { return MoveTaskMsg{ID: task.ID, Status: next} }
		if next == "done" {
			bossCmd := func() tea.Msg { return BossMarkDoneMsg{ID: task.ID} }
			return m, tea.Batch(moveCmd, bossCmd, taskStatusClearCmd())
		}
		return m, tea.Batch(moveCmd, taskStatusClearCmd())
	case "d":
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		task := ti.Task
		if task.Status == "pending_user_confirmation" {
			// Deny — send back to in_progress
			m.statusMsg = "Task denied — sent back"
			return m, tea.Batch(
				func() tea.Msg { return SetStatusTaskMsg{ID: task.ID, Status: "in_progress"} },
				func() tea.Msg { return ReviewVerdictMsg{ID: task.ID, Verdict: "rejected"} },
				taskStatusClearCmd(),
			)
		}
		m.statusMsg = "Task dispatched"
		return m, tea.Batch(func() tea.Msg {
			return DispatchTaskMsg{ID: task.ID, Title: task.Title}
		}, taskStatusClearCmd())
	case "s":
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		task := ti.Task
		if task.Status == "pending_user_confirmation" {
			// Skip Review — mark done without human review
			m.statusMsg = "Review skipped — marked done"
			return m, tea.Batch(
				func() tea.Msg { return MoveTaskMsg{ID: task.ID, Status: "done"} },
				func() tea.Msg { return BossMarkDoneMsg{ID: task.ID} },
				taskStatusClearCmd(),
			)
		}
		next := nextStatus(task.Status)
		m.statusMsg = "Status updated"
		return m, tea.Batch(func() tea.Msg {
			return SetStatusTaskMsg{ID: task.ID, Status: next}
		}, taskStatusClearCmd())
	case "p":
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		if ti.Task.PlanID != "" {
			planID := ti.Task.PlanID
			return m, func() tea.Msg { return SwitchToPlanMsg{PlanID: planID} }
		}
		return m, nil
	case "x":
		item := m.list.SelectedItem()
		if item == nil {
			return m, nil
		}
		ti := item.(taskcard.TaskItem)
		task := ti.Task
		m.statusMsg = "Task cancelled"
		cancelCmd := func() tea.Msg { return CancelTaskMsg{ID: task.ID} }
		bossCmd := func() tea.Msg { return BossCancelTaskBossMsg{ID: task.ID} }
		return m, tea.Batch(cancelCmd, bossCmd, taskStatusClearCmd())
	}

	// Delegate everything else (j/k/scroll) to the list model
	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	return m, cmd
}

func (m TasksModel) updateDetail(msg tea.KeyMsg) (TasksModel, tea.Cmd) {
	total := len(m.entries)
	if total == 0 {
		m.leftFocused = true
		m.expanded = nil
		return m, nil
	}

	switch {
	// Focus left panel
	case key.Matches(msg, m.keyMap.LeftPanel), key.Matches(msg, m.keyMap.Back):
		m.leftFocused = true
		return m, nil
	}

	switch msg.String() {
	case "up", "k", "down", "j", "pgup", "pgdown", "home", "end":
		var cmd tea.Cmd
		m.detailViewport, cmd = m.detailViewport.Update(msg)
		return m, cmd
	case "tab":
		if m.expanded != nil {
			n := len(m.expanded.Item.Subtasks)
			if n > 0 {
				if m.expanded.SubtaskCursor >= n-1 {
					m.expanded.SubtaskCursor = -1
				} else {
					m.expanded.SubtaskCursor++
				}
			}
		}
		return m, nil
	case "shift+tab":
		if m.expanded != nil {
			n := len(m.expanded.Item.Subtasks)
			if n > 0 {
				if m.expanded.SubtaskCursor <= -1 {
					m.expanded.SubtaskCursor = n - 1
				} else {
					m.expanded.SubtaskCursor--
				}
			}
		}
		return m, nil
	case "a":
		idx := m.list.Index()
		if idx >= 0 && idx < total {
			task := m.entries[idx]
			if task.Status == "pending_user_confirmation" {
				m.statusMsg = "Task accepted"
				return m, tea.Batch(
					func() tea.Msg { return MoveTaskMsg{ID: task.ID, Status: "done"} },
					func() tea.Msg { return BossMarkDoneMsg{ID: task.ID} },
					func() tea.Msg { return ReviewVerdictMsg{ID: task.ID, Verdict: "accepted"} },
					taskStatusClearCmd(),
				)
			}
		}
	case "u":
		idx := m.list.Index()
		if idx >= 0 && idx < total {
			task := m.entries[idx]
			if task.Status == "done" {
				m.statusMsg = "Completion undone"
				return m, tea.Batch(func() tea.Msg {
					return SetStatusTaskMsg{ID: task.ID, Status: "pending_user_confirmation"}
				}, taskStatusClearCmd())
			}
		}
	case "m":
		idx := m.list.Index()
		if idx >= 0 && idx < total {
			task := m.entries[idx]
			next := nextMoveStatus(task.Status)
			m.statusMsg = "Task moved"
			moveCmd := func() tea.Msg { return MoveTaskMsg{ID: task.ID, Status: next} }
			if next == "done" {
				bossCmd := func() tea.Msg { return BossMarkDoneMsg{ID: task.ID} }
				return m, tea.Batch(moveCmd, bossCmd, taskStatusClearCmd())
			}
			return m, tea.Batch(moveCmd, taskStatusClearCmd())
		}
	case "s":
		idx := m.list.Index()
		if idx >= 0 && idx < total {
			task := m.entries[idx]
			if task.Status == "pending_user_confirmation" {
				m.statusMsg = "Review skipped — marked done"
				return m, tea.Batch(
					func() tea.Msg { return MoveTaskMsg{ID: task.ID, Status: "done"} },
					func() tea.Msg { return BossMarkDoneMsg{ID: task.ID} },
					taskStatusClearCmd(),
				)
			}
			next := nextStatus(task.Status)
			m.statusMsg = "Status updated"
			return m, tea.Batch(func() tea.Msg {
				return SetStatusTaskMsg{ID: task.ID, Status: next}
			}, taskStatusClearCmd())
		}
	case "d":
		idx := m.list.Index()
		if idx >= 0 && idx < total {
			task := m.entries[idx]
			if task.Status == "pending_user_confirmation" {
				m.statusMsg = "Task denied — sent back"
				return m, tea.Batch(
					func() tea.Msg { return SetStatusTaskMsg{ID: task.ID, Status: "in_progress"} },
					func() tea.Msg { return ReviewVerdictMsg{ID: task.ID, Verdict: "rejected"} },
					taskStatusClearCmd(),
				)
			}
			m.statusMsg = "Task dispatched"
			return m, tea.Batch(func() tea.Msg {
				return DispatchTaskMsg{ID: task.ID, Title: task.Title}
			}, taskStatusClearCmd())
		}
	case "x":
		idx := m.list.Index()
		if idx >= 0 && idx < total {
			task := m.entries[idx]
			m.statusMsg = "Task cancelled"
			cancelCmd := func() tea.Msg { return CancelTaskMsg{ID: task.ID} }
			bossCmd := func() tea.Msg { return BossCancelTaskBossMsg{ID: task.ID} }
			return m, tea.Batch(cancelCmd, bossCmd, taskStatusClearCmd())
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

// FilterMessagesForTask returns IPC messages relevant to the given task,
// sorted chronologically (oldest first).
func FilterMessagesForTask(messages []runtime.Message, taskID string, taskTeam string) []runtime.Message {
	var filtered []runtime.Message
	idPattern := fmt.Sprintf("Task #%s", taskID)
	idPattern2 := fmt.Sprintf("task_%s", taskID)
	idPattern3 := fmt.Sprintf("#%s", taskID)
	for _, msg := range messages {
		bodyLower := strings.ToLower(msg.Body)
		subjectLower := strings.ToLower(msg.Subject)

		if strings.Contains(msg.Body, idPattern) ||
			strings.Contains(bodyLower, strings.ToLower(idPattern2)) ||
			strings.Contains(msg.Body, idPattern3) {
			filtered = append(filtered, msg)
			continue
		}

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

// View renders the split-pane layout or help overlay.
func (m TasksModel) View() string {
	if m.showHelp {
		return m.viewHelp()
	}

	w := m.width
	if w < 52 {
		w = 52
	}
	h := m.height
	if h < 10 {
		h = 10
	}

	// Panel widths: 40% left, 60% right
	leftW := w * 40 / 100
	if leftW < 28 {
		leftW = 28
	}
	rightW := w - leftW
	if rightW < 24 {
		rightW = 24
	}

	leftPanel := m.renderLeftPanel(leftW, h)
	rightPanel := m.renderExpandedRightPanel(rightW, h)

	return m.RenderPanels(leftPanel, rightPanel)
}

// renderLeftPanel renders the task list.
func (m TasksModel) renderLeftPanel(w, h int) string {
	t := m.theme

	borderColor := t.Separator
	if m.focused && m.leftFocused {
		borderColor = t.Primary
	}
	_ = borderColor // used in panel style below

	// Header
	header := t.SectionHeader.Copy().Width(w).PaddingLeft(1).Render("TASKS")

	if len(m.entries) == 0 {
		icon := styles.EmptyStateIcon(t)
		title := styles.EmptyStateTitle(t)
		hint := styles.EmptyStateHint(t)

		emptyBox := lipgloss.NewStyle().
			Align(lipgloss.Center).
			Width(w).
			PaddingTop(2).
			Render(icon + "\n\n" + title + "\n" + hint)

		content := header + "\n" + emptyBox
		if m.creating {
			content += "\n" + m.renderInputBar()
		}
		return lipgloss.NewStyle().Width(w).Height(h).Render(content)
	}

	summary := m.taskSummary()

	// Set list size for left panel
	listH := h - 2 // header + summary
	if listH < 1 {
		listH = 1
	}
	// Create a temporary copy for rendering at correct size
	l := m.list
	l.SetSize(w, listH)
	listView := l.View()

	content := header + "\n" + summary + "\n" + listView

	if m.statusMsg != "" {
		content += "\n" + lipgloss.NewStyle().Foreground(t.Success).PaddingLeft(1).Render(m.statusMsg)
	}

	if m.creating {
		content += "\n" + m.renderInputBar()
	}
	return lipgloss.NewStyle().Width(w).Height(h).Render(content)
}

// renderRightPanel renders the detail pane for the selected task.
func (m TasksModel) renderRightPanel(w, h int) string {
	t := m.theme

	borderColor := t.Separator
	if m.focused && !m.leftFocused {
		borderColor = t.Primary
	}

	idx := m.list.Index()
	if len(m.entries) == 0 || idx < 0 || idx >= len(m.entries) {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			Padding(2, 3).
			Width(w).
			Height(h).
			Render("No task selected")
		return empty
	}

	task := m.entries[idx]
	contentW := w - 6
	if contentW < 20 {
		contentW = 20
	}

	var sections []string

	// Title
	title := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(task.Title)
	sections = append(sections, statusIcon(task.Status, t)+" "+title)
	sections = append(sections, "")

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
	case "deferred":
		statusColor = t.Warning
	}
	sections = append(sections, styles.MetaLine(t, "Status", lipgloss.NewStyle().Foreground(statusColor).Render(task.Status)))

	// Live workers
	if ws := m.workerSummaryForTask(task.ID); ws != "" {
		sections = append(sections, styles.MetaLine(t, "Workers", ws))
	}

	// Type
	if task.Type != "" {
		sections = append(sections, styles.MetaLine(t, "Type", task.Type))
	}

	// Team
	if task.Team != "" {
		sections = append(sections, styles.MetaLine(t, "Team",
			lipgloss.NewStyle().Bold(true).Foreground(t.Accent).Render(task.Team)))
	}

	// Owner
	if task.CreatedBy != "" {
		sections = append(sections, styles.MetaLine(t, "Created by", task.CreatedBy))
	}
	if task.AssignedTo != "" {
		sections = append(sections, styles.MetaLine(t, "Assigned to",
			lipgloss.NewStyle().Bold(true).Foreground(t.Accent).Render(task.AssignedTo)))
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
		sections = append(sections, styles.MetaLine(t, "Priority",
			lipgloss.NewStyle().Foreground(priColor).Render(priLabel)))
	}

	if task.Category != "" {
		sections = append(sections, styles.MetaLine(t, "Category", styles.CategoryBadge(task.Category)))
	}
	if len(task.Tags) > 0 {
		var tagParts []string
		for _, tag := range task.Tags {
			tagParts = append(tagParts, styles.TagBadge(tag))
		}
		sections = append(sections, styles.MetaLine(t, "Tags", strings.Join(tagParts, " ")))
	}
	if task.MergedInto != "" {
		sections = append(sections, styles.MetaLine(t, "Merged into",
			lipgloss.NewStyle().Foreground(t.Accent).Render("#"+task.MergedInto)))
	}
	if task.ParentTaskID != "" {
		sections = append(sections, styles.MetaLine(t, "Parent", t.Dim.Render("#"+task.ParentTaskID)))
	}
	if task.Created > 0 {
		sections = append(sections, styles.MetaLine(t, "Created",
			time.Unix(task.Created, 0).Format("2006-01-02 15:04:05")))
	}
	if task.Updated > 0 {
		sections = append(sections, styles.MetaLine(t, "Updated",
			time.Unix(task.Updated, 0).Format("2006-01-02 15:04:05")))
	}
	if task.Result != "" {
		sections = append(sections, styles.MetaLine(t, "Result", task.Result))
	}

	// Plan section — show linked plan with steps preview
	if task.PlanID != "" {
		planTitle := task.PlanTitle
		if planTitle == "" {
			planTitle = "Plan"
		}
		sep := lipgloss.NewStyle().Foreground(t.Separator)
		planLink := lipgloss.NewStyle().Foreground(t.Accent).Bold(true).
			Render(fmt.Sprintf("#%s — %s", task.PlanID, planTitle))
		sections = append(sections, "")
		sections = append(sections, sep.Render("╭ ")+
			lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render("Plan"))
		sections = append(sections, sep.Render("│ ")+planLink)

		// Render plan body steps if we have the full plan data
		if p := m.detailPlan; p != nil && p.Content != "" {
			steps := extractPlanSteps(p.Content, 8)
			stepStyle := lipgloss.NewStyle().Foreground(t.Muted)
			for _, step := range steps {
				sections = append(sections, sep.Render("│   ")+stepStyle.Render(step))
			}
			// Count total lines to show overflow
			allSteps := extractPlanSteps(p.Content, 0)
			if len(allSteps) > 8 {
				sections = append(sections, sep.Render("│   ")+
					lipgloss.NewStyle().Faint(true).Foreground(t.Muted).
						Render(fmt.Sprintf("… +%d more", len(allSteps)-8)))
			}
		}
		sections = append(sections, sep.Render("╰"))
	}

	// Blockers — highlighted red
	if task.Blockers != "" {
		sections = append(sections, "")
		sections = append(sections, lipgloss.NewStyle().Bold(true).Foreground(t.Danger).Render("✗ BLOCKERS"))
		sections = append(sections, lipgloss.NewStyle().Foreground(t.Danger).Width(contentW).Render(task.Blockers))
	}

	// Description
	if task.Description != "" {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(t, "DESCRIPTION"))
		sections = append(sections, styles.DescriptionBlock(t, task.Description, contentW))
	}

	// Acceptance Criteria
	if task.AcceptanceCriteria != "" {
		var acLines []string
		for _, line := range strings.Split(task.AcceptanceCriteria, "\n") {
			line = strings.TrimSpace(line)
			if line != "" {
				acLines = append(acLines, line)
			}
		}
		if len(acLines) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "ACCEPTANCE CRITERIA"))
			sections = append(sections, styles.BulletList(t, acLines, contentW))
		}
	}

	// Reports
	if len(task.Reports) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(t, fmt.Sprintf("REPORTS (%d)", len(task.Reports))))
		for _, report := range task.Reports {
			var typeColor lipgloss.AdaptiveColor
			switch report.Type {
			case "research":
				typeColor = t.Info
			case "progress":
				typeColor = t.Success
			case "decision":
				typeColor = t.Accent
			case "completion":
				typeColor = t.Warning
			case "error":
				typeColor = t.Danger
			default:
				typeColor = t.Muted
			}
			badge := lipgloss.NewStyle().Foreground(typeColor).Bold(true).Render("[" + report.Type + "]")
			titleText := lipgloss.NewStyle().Foreground(t.Text).Bold(true).Render(report.Title)
			author := ""
			if report.Author != "" {
				author = "  " + lipgloss.NewStyle().Foreground(t.Muted).Render(report.Author)
			}
			timeStr := ""
			if report.Created > 0 {
				timeStr = "  " + lipgloss.NewStyle().Foreground(t.Subtle).Faint(true).
					Render(time.Unix(report.Created, 0).Format("15:04"))
			}
			sections = append(sections, fmt.Sprintf("  %s %s%s%s", badge, titleText, author, timeStr))

			if report.Body != "" {
				bodyLines := strings.Split(report.Body, "\n")
				if len(bodyLines) > 3 {
					bodyLines = bodyLines[:3]
					bodyLines = append(bodyLines, "...")
				}
				bodyStyle := lipgloss.NewStyle().Foreground(t.Muted).PaddingLeft(4)
				for _, line := range bodyLines {
					sections = append(sections, bodyStyle.Render(line))
				}
			}
			sections = append(sections, "")
		}
	}

	// Subtasks
	if subs, ok := m.subtaskMap[task.ID]; ok && len(subs) > 0 {
		doneCount := 0
		for _, st := range subs {
			if st.Status == "done" {
				doneCount++
			}
		}
		total := len(subs)

		barWidth := 20
		filled := 0
		if total > 0 {
			filled = (doneCount * barWidth) / total
		}
		bar := lipgloss.NewStyle().Foreground(t.Success).Render(strings.Repeat("█", filled)) +
			lipgloss.NewStyle().Foreground(t.Muted).Render(strings.Repeat("░", barWidth-filled))
		progressLabel := fmt.Sprintf(" %d/%d", doneCount, total)

		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(t, fmt.Sprintf("SUBTASKS (%d/%d)", doneCount, total)))
		sections = append(sections, bar+t.Dim.Render(progressLabel))

		now := time.Now()
		for i, st := range subs {
			dot := lipgloss.NewStyle().Foreground(t.Muted).Render("○")
			switch st.Status {
			case "done":
				dot = lipgloss.NewStyle().Foreground(t.Success).Render("●")
			case "active":
				dot = lipgloss.NewStyle().Foreground(t.Warning).Render("●")
			case "failed":
				dot = lipgloss.NewStyle().Foreground(t.Danger).Render("✗")
			case "deferred":
				dot = lipgloss.NewStyle().Foreground(t.Warning).Render("⏸")
			}
			pane := lipgloss.NewStyle().Foreground(t.Accent).Render(st.Pane)
			stTitle := t.Body.Render(st.Title)
			age := ""
			if st.Created > 0 {
				age = t.Faint.Render(formatAge(now.Sub(time.Unix(st.Created, 0))))
			}
			reason := ""
			if st.Reason != "" {
				reason = t.Faint.Render(" (" + st.Reason + ")")
			}

			// Highlight selected subtask
			line := fmt.Sprintf("%s %-6s %s%s  %s", dot, pane, stTitle, reason, age)
			if m.expanded != nil && m.expanded.SubtaskCursor == i {
				line = lipgloss.NewStyle().Bold(true).Render(line)
			}
			sections = append(sections, zone.Mark(fmt.Sprintf("subtask-%d", i), line))
		}
	}

	// Split attachments into research and other
	if len(task.TaskAttachments) > 0 {
		var research, other []runtime.PersistentAttachment
		for _, att := range task.TaskAttachments {
			if att.Type == "research" {
				research = append(research, att)
			} else {
				other = append(other, att)
			}
		}

		now := time.Now()
		bodyStyle := lipgloss.NewStyle().Foreground(t.Muted).PaddingLeft(4)

		// Research section — shown first with extended preview
		if len(research) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, fmt.Sprintf("RESEARCH (%d)", len(research))))
			for _, att := range research {
				titleText := att.Title
				if titleText == "" {
					titleText = att.Filename
				}
				title := lipgloss.NewStyle().Foreground(t.Text).Bold(true).Render(titleText)
				meta := ""
				if att.Author != "" {
					meta += " — " + lipgloss.NewStyle().Foreground(t.Muted).Render(att.Author)
				}
				if att.Timestamp > 0 {
					elapsed := now.Sub(time.Unix(att.Timestamp, 0))
					meta += ", " + lipgloss.NewStyle().Foreground(t.Subtle).Faint(true).Render(formatAge(elapsed)+" ago")
				}
				sections = append(sections, fmt.Sprintf("  %s %s%s", attachmentEmoji("research"), title, meta))

				// Body preview — first 5 non-empty lines for research
				if att.Body != "" {
					lines := strings.Split(att.Body, "\n")
					shown := 0
					for _, line := range lines {
						if strings.TrimSpace(line) == "" {
							continue
						}
						if shown >= 5 {
							sections = append(sections, bodyStyle.Render(
								lipgloss.NewStyle().Faint(true).Render(fmt.Sprintf("… +%d more lines", len(lines)-shown))))
							break
						}
						sections = append(sections, bodyStyle.Render(line))
						shown++
					}
				}
				sections = append(sections, "")
			}
		}

		// Other attachments
		if len(other) > 0 {
			display := other
			if len(display) > 20 {
				display = display[:20]
			}
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, fmt.Sprintf("ATTACHMENTS (%d)", len(other))))
			for _, att := range display {
				emoji := attachmentEmoji(att.Type)
				typeColor := styles.AttachmentTypeColor(t, att.Type)
				badge := lipgloss.NewStyle().Foreground(typeColor).Bold(true).Render(emoji)

				titleText := att.Title
				if titleText == "" {
					titleText = att.Filename
				}
				title := lipgloss.NewStyle().Foreground(t.Text).Bold(true).Render(titleText)

				meta := ""
				if att.Author != "" {
					meta += " — " + lipgloss.NewStyle().Foreground(t.Muted).Render(att.Author)
				}
				if att.Timestamp > 0 {
					elapsed := now.Sub(time.Unix(att.Timestamp, 0))
					meta += ", " + lipgloss.NewStyle().Foreground(t.Subtle).Faint(true).Render(formatAge(elapsed)+" ago")
				}
				sections = append(sections, fmt.Sprintf("  %s %s%s", badge, title, meta))

				// Body preview — first 4 non-empty lines
				if att.Body != "" {
					lines := strings.Split(att.Body, "\n")
					shown := 0
					for _, line := range lines {
						if strings.TrimSpace(line) == "" {
							continue
						}
						if shown >= 4 {
							sections = append(sections, bodyStyle.Render(
								lipgloss.NewStyle().Faint(true).Render(fmt.Sprintf("… +%d more lines", len(lines)-shown))))
							break
						}
						sections = append(sections, bodyStyle.Render(line))
						shown++
					}
				}
			}
		}
	} else if len(task.Attachments) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(t, "LINKS & ATTACHMENTS"))
		for _, att := range task.Attachments {
			sections = append(sections, lipgloss.NewStyle().Foreground(t.Accent).Render("→ "+att))
		}
	}

	// --- Sidecar: Planning ---
	if sc := m.detailSidecar; sc != nil {
		if sc.Intent != "" {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "INTENT"))
			sections = append(sections, styles.DescriptionBlock(t, sc.Intent, contentW))
		}
		if len(sc.Hypotheses) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "HYPOTHESES"))
			for _, h := range sc.Hypotheses {
				name := h.Text
				if name == "" {
					name = h.Name
				}
				if h.ID != "" {
					name = h.ID + ": " + name
				}
				conf := h.Confidence
				if conf == "" {
					conf = "medium"
				}
				sections = append(sections, styles.HypothesisRow(t, name, conf, contentW))
			}
		}
		if len(sc.Constraints) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "CONSTRAINTS"))
			sections = append(sections, styles.BulletList(t, sc.Constraints, contentW))
		}
		if len(sc.SuccessCriteria) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "SUCCESS CRITERIA"))
			sections = append(sections, styles.BulletList(t, sc.SuccessCriteria, contentW))
		}
		if len(sc.Deliverables) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "DELIVERABLES"))
			sections = append(sections, styles.BulletList(t, sc.Deliverables, contentW))
		}
	}

	// --- Sidecar: Execution ---
	if sc := m.detailSidecar; sc != nil {
		if sc.Phase != "" || sc.TotalPhases > 0 {
			badge := styles.PhaseBadge(t, sc.Phase, sc.CurrentPhase, sc.TotalPhases)
			if badge != "" {
				sections = append(sections, "")
				sections = append(sections, styles.MetaLine(t, "Phase", badge))
			}
		}
		if sc.DispatchMode != "" {
			sections = append(sections, styles.MetaLine(t, "Dispatch", sc.DispatchMode))
		}
		if sc.DispatchPlan != nil && len(sc.DispatchPlan.Phases) > 0 {
			var phaseLines []string
			for _, p := range sc.DispatchPlan.Phases {
				label := p.Title
				if label == "" {
					label = p.Brief
				}
				if label == "" {
					label = fmt.Sprintf("Phase %d", p.Phase)
				}
				phaseLines = append(phaseLines, label)
			}
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "DISPATCH PLAN"))
			sections = append(sections, styles.NumberedList(t, phaseLines, contentW))
		}
		if len(sc.EvidencePlan) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "EVIDENCE PLAN"))
			sections = append(sections, styles.BulletList(t, sc.EvidencePlan, contentW))
		}
	}

	// --- Sidecar: Semantic ---
	if sc := m.detailSidecar; sc != nil {
		if len(sc.Concepts) > 0 {
			var names []string
			for _, c := range sc.Concepts {
				label := c.Name
				if c.ID != "" {
					label = c.ID + ": " + label
				}
				names = append(names, label)
			}
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "CONCEPTS"))
			sections = append(sections, styles.BulletList(t, names, contentW))
		}
		if sc.BridgeProblem != "" {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "BRIDGE PROBLEM"))
			sections = append(sections, styles.DescriptionBlock(t, sc.BridgeProblem, contentW))
		}
		if len(sc.RepresentationLayer) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "REPRESENTATION LAYER"))
			sections = append(sections, styles.BulletList(t, sc.RepresentationLayer, contentW))
		}
	}

	// --- Result data ---
	if res := m.detailResult; res != nil {
		if res.NeedsFollowUp {
			sections = append(sections, "")
			sections = append(sections, styles.FollowUpBadge(t))
		}
		if len(res.HypothesisUpdates) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "HYPOTHESIS UPDATES"))
			for _, hu := range res.HypothesisUpdates {
				name := hu.ID
				if hu.Evidence != "" {
					name += ": " + hu.Evidence
				}
				conf := hu.Confidence
				if conf == "" {
					conf = hu.Status
				}
				sections = append(sections, styles.HypothesisRow(t, name, conf, contentW))
			}
		}
		if len(res.Evidence) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "EVIDENCE"))
			sections = append(sections, styles.BulletList(t, res.Evidence, contentW))
		}
		if res.ToolCalls > 0 {
			sections = append(sections, styles.MetaLine(t, "Tool Calls", fmt.Sprintf("%d", res.ToolCalls)))
		}
	}

	// Files Changed — directory-grouped tree
	if fileTree := renderFileTree(t, task.FilesChanged, m.detailResult); fileTree != "" {
		sections = append(sections, "")
		sections = append(sections, fileTree)
	}

	// Decision Log (last 3 entries)
	if task.DecisionLog != "" {
		lines := strings.Split(strings.TrimSpace(task.DecisionLog), "\n")
		start := 0
		if len(lines) > 3 {
			start = len(lines) - 3
		}
		var dlLines []string
		for _, line := range lines[start:] {
			line = strings.TrimSpace(line)
			if line != "" {
				dlLines = append(dlLines, line)
			}
		}
		if len(dlLines) > 0 {
			sections = append(sections, "")
			sections = append(sections, styles.SectionTitle(t, "DECISIONS"))
			sections = append(sections, styles.BulletList(t, dlLines, contentW))
			if start > 0 {
				sections = append(sections, t.Faint.Render(fmt.Sprintf("(%d more)", start)))
			}
		}
	}

	// Notes (truncated to 5 lines)
	if task.Notes != "" {
		lines := strings.Split(strings.TrimSpace(task.Notes), "\n")
		truncated := false
		if len(lines) > 5 {
			lines = lines[:5]
			truncated = true
		}
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(t, "NOTES"))
		sections = append(sections, styles.DescriptionBlock(t, strings.Join(lines, "\n"), contentW))
		if truncated {
			sections = append(sections, t.Faint.Render("(truncated)"))
		}
	}

	// Activity Log (chronological: oldest first, newest last)
	if len(task.Logs) > 0 {
		logs := task.Logs
		maxEntries := 10
		truncated := 0
		if len(logs) > maxEntries {
			truncated = len(logs) - maxEntries
			logs = logs[len(logs)-maxEntries:]
		}
		now := time.Now()
		var logLines []string
		if truncated > 0 {
			logLines = append(logLines, t.Faint.Render(fmt.Sprintf("(%d older)", truncated)))
		}
		for _, entry := range logs {
			age := "     "
			if entry.Timestamp > 0 {
				age = fmt.Sprintf("%-5s", formatAge(now.Sub(time.Unix(entry.Timestamp, 0))))
			}
			logLines = append(logLines, lipgloss.NewStyle().Foreground(t.Muted).Render(age+" "+entry.Entry))
		}
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(t, "ACTIVITY LOG"))
		sections = append(sections, strings.Join(logLines, "\n"))
	}

	// Nav hint
	sections = append(sections, "")
	if m.focused {
		hint := "← back to list"
		if m.leftFocused {
			hint = "→ or enter for details"
		} else {
			// Show review actions for pending tasks, standard actions otherwise
			idx := m.list.Index()
			if idx >= 0 && idx < len(m.entries) && m.entries[idx].Status == "pending_user_confirmation" {
				hint += "  d deny  s skip  a accept  tab subtask"
			} else {
				hint += "  m move  s status  d dispatch  x cancel  tab subtask"
			}
		}
		sections = append(sections, lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render(hint))
	}

	fullContent := strings.Join(sections, "\n")

	// Apply scroll
	lines := strings.Split(fullContent, "\n")
	viewport := h - 2
	if viewport < 1 {
		viewport = 1
	}

	maxScroll := len(lines) - viewport
	if maxScroll < 0 {
		maxScroll = 0
	}
	scrollOff := m.detailViewport.YOffset
	if scrollOff > maxScroll {
		scrollOff = maxScroll
	}

	if scrollOff > 0 && scrollOff < len(lines) {
		lines = lines[scrollOff:]
	}
	if len(lines) > viewport {
		lines = lines[:viewport]
	}

	displayed := strings.Join(lines, "\n")

	panelStyle := lipgloss.NewStyle().
		Width(w).
		Height(h).
		Padding(1, 2).
		BorderLeft(true).
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(borderColor)

	return panelStyle.Render(displayed)
}

// renderExpandedRightPanel renders the detail pane using the ExpandedCard
// for rich display including reports, proof of completion, live updates,
// worker status, grammar-parsed activity log, and IPC messages.
func (m TasksModel) renderExpandedRightPanel(w, h int) string {
	t := m.theme

	idx := m.list.Index()
	if len(m.entries) == 0 || idx < 0 || idx >= len(m.entries) {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			Padding(2, 3).
			Width(w).
			Height(h).
			Render("No task selected")
		return empty
	}

	// Use the pre-built expanded card, or create a temporary one for this render
	expanded := m.expanded
	if expanded == nil {
		item := m.list.SelectedItem()
		if item == nil {
			return lipgloss.NewStyle().Width(w).Height(h).Render("")
		}
		ti := item.(taskcard.TaskItem)
		task := m.entries[idx]
		expanded = &taskcard.ExpandedCard{
			Item:          ti,
			Theme:         m.theme,
			Width:         w - 1,
			Height:        h - 2,
			SubtaskCursor: -1,
			Messages:      FilterMessagesForTask(m.messages, task.ID, task.Team),
			PaneStatuses:  paneStatusSlice(m.paneStatuses),
			Results:       m.paneResults,
			ProjectDir:    m.projectDir,
		}
	}

	// Sync dimensions to current layout (account for left border + right padding)
	renderW := w - 2
	if renderW < 20 {
		renderW = 20
	}
	expanded.Width = renderW
	vpH := h - 2
	if vpH < 1 {
		vpH = 1
	}
	expanded.Height = vpH

	// Render full content and feed to viewport
	content := expanded.Render()
	savedYOffset := m.detailViewport.YOffset
	m.detailViewport.Width = renderW
	m.detailViewport.Height = vpH - 1 // leave room for hint bar
	m.detailViewport.SetContent(content)
	maxY := m.detailViewport.TotalLineCount() - m.detailViewport.Height
	if maxY < 0 { maxY = 0 }
	if savedYOffset > maxY { savedYOffset = maxY }
	m.detailViewport.SetYOffset(savedYOffset)

	displayed := m.detailViewport.View()

	// Scroll hint — only show when content overflows
	if m.detailViewport.TotalLineCount() > m.detailViewport.Height {
		pct := m.detailViewport.ScrollPercent()
		scrollHint := lipgloss.NewStyle().Foreground(t.Subtle).Faint(true).
			Align(lipgloss.Right).Width(renderW).
			Render(fmt.Sprintf("%.0f%%", pct*100))
		displayed += "\n" + scrollHint
	}

	// Action buttons (only when detail focused and task selected)
	if !m.leftFocused && len(m.entries) > 0 {
		idx := m.list.Index()
		if idx >= 0 && idx < len(m.entries) {
			task := m.entries[idx]
			var buttons []string
			status := task.Status
			btnStyle := func(bg lipgloss.AdaptiveColor) lipgloss.Style {
				return lipgloss.NewStyle().Bold(true).Foreground(t.BgText).Background(bg).Padding(0, 2)
			}

			if status == "done" {
				// Done tasks: only show undo button
				buttons = append(buttons, zone.Mark("task-undo-btn", btnStyle(t.Warning).Render("Undo Completion (u)")))
			} else if status == "pending_user_confirmation" {
				// Review decision buttons
				buttons = append(buttons, zone.Mark("task-deny-btn", btnStyle(t.Danger).Render("Deny (d)")))
				buttons = append(buttons, zone.Mark("task-skip-btn", btnStyle(t.Muted).Render("Skip Review (s)")))
				buttons = append(buttons, zone.Mark("task-accept-btn", btnStyle(t.Success).Render("Accept (a)")))
			} else {
				// Standard action buttons
				if status != "done" && status != "cancelled" {
					buttons = append(buttons, zone.Mark("task-move-btn", btnStyle(t.Primary).Render("Move (m)")))
				}
				if status == "in_progress" || status == "active" || status == "pending" || status == "ready" {
					buttons = append(buttons, zone.Mark("task-dispatch-btn", btnStyle(t.Accent).Render("Dispatch (d)")))
				}
				buttons = append(buttons, zone.Mark("task-status-btn", btnStyle(t.Muted).Render("Status (s)")))
				if status != "cancelled" {
					buttons = append(buttons, zone.Mark("task-cancel-btn", btnStyle(t.Danger).Render("Cancel (x)")))
				}
			}

			if len(buttons) > 0 {
				row := strings.Join(buttons, " ")
				displayed += "\n" + lipgloss.NewStyle().Width(renderW).Align(lipgloss.Center).Render(row)
			}
		}
	}

	borderColor := t.Separator
	if m.focused && !m.leftFocused {
		borderColor = t.Primary
	}
	panelStyle := lipgloss.NewStyle().
		Width(w).
		Height(h).
		PaddingRight(1).
		BorderLeft(true).
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(borderColor)

	return panelStyle.Render(displayed)
}

// viewHelp renders a floating keyboard help overlay.
func (m TasksModel) viewHelp() string {
	t := m.theme
	w := m.width
	if w > styles.MaxCardWidth {
		w = styles.MaxCardWidth
	}

	title := lipgloss.NewStyle().Bold(true).Foreground(t.Primary).
		Render("⟫ Keyboard Shortcuts")
	sep := t.Faint.Render(strings.Repeat("─", w-6))

	keyStyle := styles.HelpKeyStyle(t)
	descStyle := styles.HelpDescStyle(t)

	bindings := []struct{ key, desc string }{
		{"j / k", "Navigate cards up/down (list)"},
		{"Enter / →", "Focus detail panel"},
		{"Esc / ←", "Focus list panel"},
		{"↑ / ↓", "Scroll detail panel"},
		{"n", "Create new task"},
		{"m", "Move task (active → in_progress → done)"},
		{"s", "Cycle statuses / Skip Review (pending)"},
		{"d", "Dispatch task / Deny (pending)"},
		{"a", "Accept task (pending confirmation)"},
		{"u", "Undo completion (done tasks)"},
		{"p", "View linked plan"},
		{"x", "Cancel task"},
		{"Tab", "Next subtask (detail panel)"},
		{"Shift+Tab", "Previous subtask (detail panel)"},
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

	total := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(1).
		Render(fmt.Sprintf("%d tasks", len(m.entries)))

	var parts []string
	if active > 0 {
		parts = append(parts, styles.SectionPill(fmt.Sprintf("%d active", active), t.Primary))
	}
	if complete > 0 {
		parts = append(parts, styles.SectionPill(fmt.Sprintf("%d complete", complete), t.Success))
	}

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
func (m TasksModel) workerSummaryForTask(taskID string) string {
	t := m.theme
	hs, ok := m.heartbeats[taskID]
	if !ok || hs.ActiveWorkers == 0 {
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
		Render(m.inputText + "█")
	return lipgloss.NewStyle().Padding(1, 3).Render(prompt + input)
}
