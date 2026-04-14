package model

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
	"github.com/doey-cli/doey/tui/internal/taskcard"
)

// SwitchToTaskMsg requests the root model switch to the Tasks tab and select a task.
type SwitchToTaskMsg struct{ TaskID int }

// ReservedFreelancerMsg requests launching a reserved freelancer pool.
type ReservedFreelancerMsg struct{}

// GetStatusMsg requests a status refresh.
type GetStatusMsg struct{}

// CreateTeamMsg requests team creation.
type CreateTeamMsg struct{}

// ViewTasksMsg requests switching to the Tasks tab.
type ViewTasksMsg struct{}

// CreateSpecializedTeamMsg requests spawning a team from a definition file.
// Name is empty when requesting the picker, or set when a team was selected.
type CreateSpecializedTeamMsg struct {
	Name string
}

// dashTickMsg is the internal tick for reloading task data.
type dashTickMsg time.Time

// quickAction defines a quick action card.
type quickAction struct {
	icon        string
	label       string
	description string
	zoneID      string
}

// quickActions is the ordered list of dashboard spawn cards.
var quickActions = []quickAction{
	{"◇", "Freelancer", "Independent, no manager", "dash-spawn-freelancer"},
	{"◆", "Team", "Subtaskmaster + Workers", "dash-create-team"},
	{"◈", "Specialized", "R&D, Deployment, etc.", "dash-create-specialized"},
}

// DashboardModel is the primary landing tab (command center).
type DashboardModel struct {
	runtimeDir     string
	projectDir     string
	width          int
	height         int
	theme          styles.Theme
	focused        bool
	tasks          []runtime.PersistentTask
	heartbeats     map[string]runtime.HeartbeatState
	keyMap         keys.KeyMap
	scrollOffset   int
	actionCursor   int              // selected quick action card (0..2)
	snapshot       runtime.Snapshot // live snapshot for pane/result/message data
	feedbackMsg    string
	feedbackTime   time.Time
	pickerActive   bool               // true when team def picker is visible
	pickerDefs     []runtime.TeamDef  // available team defs
	pickerCursor   int                // selected item in picker
}

// NewDashboardModel creates the dashboard command center panel.
func NewDashboardModel(runtimeDir, projectDir string, width, height int, theme styles.Theme) DashboardModel {
	m := DashboardModel{
		runtimeDir: runtimeDir,
		projectDir: projectDir,
		width:      width,
		height:     height,
		theme:      theme,
		keyMap:     keys.DefaultKeyMap(),
	}
	m.loadTasks()
	return m
}

// Update handles messages for the dashboard panel.
func (m DashboardModel) Update(msg tea.Msg) (DashboardModel, tea.Cmd) {
	switch msg := msg.(type) {
	case dashTickMsg:
		m.loadTasks()
		if m.feedbackMsg != "" && time.Since(m.feedbackTime) > 3*time.Second {
			m.feedbackMsg = ""
		}
		return m, m.tickCmd()

	case SnapshotMsg:
		m.snapshot = runtime.Snapshot(msg)
		return m, nil

	case tea.KeyMsg:
		// Team def picker intercepts all keys when active
		if m.pickerActive {
			switch msg.String() {
			case "esc":
				m.pickerActive = false
				return m, nil
			case "up", "k":
				if m.pickerCursor > 0 {
					m.pickerCursor--
				}
				return m, nil
			case "down", "j":
				if m.pickerCursor < len(m.pickerDefs)-1 {
					m.pickerCursor++
				}
				return m, nil
			case "enter":
				if len(m.pickerDefs) > 0 && m.pickerCursor < len(m.pickerDefs) {
					name := m.pickerDefs[m.pickerCursor].Name
					m.pickerActive = false
					return m, func() tea.Msg { return CreateSpecializedTeamMsg{Name: name} }
				}
				return m, nil
			}
			return m, nil
		}

		switch {
		case key.Matches(msg, m.keyMap.Up):
			if m.scrollOffset > 0 {
				m.scrollOffset--
			}
			return m, nil
		case key.Matches(msg, m.keyMap.Down):
			maxOff := m.maxScrollOffset()
			if m.scrollOffset < maxOff {
				m.scrollOffset++
			}
			return m, nil
		}
		// Quick action card navigation: h/l = left/right, Enter = activate
		switch msg.String() {
		case "h":
			if m.actionCursor > 0 {
				m.actionCursor--
			}
			return m, nil
		case "l":
			if m.actionCursor < len(quickActions)-1 {
				m.actionCursor++
			}
			return m, nil
		case "enter":
			return m, m.activateAction(m.actionCursor)
		}

	case tea.MouseMsg:
		return m.updateMouse(msg)
	}

	return m, nil
}

// View renders the dashboard command center.
func (m DashboardModel) View() string {
	w := m.width
	if w < 40 {
		w = 40
	}

	var sections []string
	if m.feedbackMsg != "" && time.Since(m.feedbackTime) < 3*time.Second {
		fbColor := m.theme.Success
		prefix := "✓ "
		if strings.HasPrefix(m.feedbackMsg, "Error:") {
			fbColor = m.theme.Danger
			prefix = "✗ "
		}
		feedbackStyle := lipgloss.NewStyle().
			Foreground(fbColor).
			Bold(true).
			PaddingLeft(2)
		sections = append(sections, feedbackStyle.Render(prefix+m.feedbackMsg))
	}
	if m.pickerActive {
		sections = append(sections, m.renderTeamPicker(w))
	}
	sections = append(sections, m.renderActiveTasks(w))
	sections = append(sections, m.renderTeamGrid(w))

	content := strings.Join(sections, "\n")

	// Apply scroll offset
	lines := strings.Split(content, "\n")
	if m.scrollOffset > len(lines)-1 {
		m.scrollOffset = len(lines) - 1
	}
	if m.scrollOffset < 0 {
		m.scrollOffset = 0
	}
	if m.scrollOffset > 0 && m.scrollOffset < len(lines) {
		lines = lines[m.scrollOffset:]
	}
	content = strings.Join(lines, "\n")

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Render(content)
}

// SetSize updates panel dimensions (value receiver to match required signature).
func (m DashboardModel) SetSize(w, h int) DashboardModel {
	m.width = w
	m.height = h
	return m
}

// SetFocused toggles focus state (value receiver to match required signature).
func (m DashboardModel) SetFocused(f bool) DashboardModel {
	m.focused = f
	return m
}

// maxScrollOffset computes the maximum scroll offset based on rendered content height.
func (m DashboardModel) maxScrollOffset() int {
	// Build the same content as View to count total lines.
	var sections []string
	w := m.width
	if w < 40 {
		w = 40
	}
	sections = append(sections, m.renderActiveTasks(w))
	sections = append(sections, m.renderTeamGrid(w))
	totalLines := len(strings.Split(strings.Join(sections, "\n"), "\n"))
	maxOff := totalLines - m.height
	if maxOff < 0 {
		maxOff = 0
	}
	return maxOff
}

// Init returns the initial tick command.
func (m DashboardModel) Init() tea.Cmd {
	return m.tickCmd()
}

// tickCmd returns a tick command that fires every 3 seconds.
func (m DashboardModel) tickCmd() tea.Cmd {
	return tea.Tick(3*time.Second, func(t time.Time) tea.Msg {
		return dashTickMsg(t)
	})
}

// SetHeartbeats updates the heartbeat state map for all tasks.
func (m *DashboardModel) SetHeartbeats(hb map[string]runtime.HeartbeatState) {
	m.heartbeats = hb
}

// ShowTeamPicker opens the team definition picker overlay.
func (m *DashboardModel) ShowTeamPicker(defs []runtime.TeamDef) {
	m.pickerActive = true
	m.pickerDefs = defs
	m.pickerCursor = 0
}

// SetFeedback sets a temporary feedback message shown for 3 seconds.
func (m *DashboardModel) SetFeedback(msg string) {
	m.feedbackMsg = msg
	m.feedbackTime = time.Now()
}

// loadTasks reads .doey/tasks/ and filters for active/in_progress tasks.
func (m *DashboardModel) loadTasks() {
	if m.projectDir != "" {
		runtime.SetProjectDir(m.projectDir)
	}
	store, err := runtime.ReadTaskStore()
	if err != nil {
		m.tasks = nil
		return
	}

	// Merge .task files so dashboard sees tasks that only exist on disk
	reader := runtime.NewReader(m.runtimeDir)
	if m.projectDir != "" {
		reader.SetProjectDir(m.projectDir)
	}
	if runtimeTasks := reader.ParseTasks(); len(runtimeTasks) > 0 {
		store.MergeRuntimeTasks(runtimeTasks)
	}

	var active []runtime.PersistentTask
	for _, t := range store.Tasks {
		if t.Status == "active" || t.Status == "in_progress" {
			active = append(active, t)
		}
	}
	m.tasks = active
}

// activateAction returns the tea.Cmd for the given action index.
func (m DashboardModel) activateAction(idx int) tea.Cmd {
	if idx < 0 || idx >= len(quickActions) {
		return nil
	}
	switch quickActions[idx].zoneID {
	case "dash-spawn-freelancer":
		return func() tea.Msg { return ReservedFreelancerMsg{} }
	case "dash-create-team":
		return func() tea.Msg { return CreateTeamMsg{} }
	case "dash-create-specialized":
		return func() tea.Msg { return CreateSpecializedTeamMsg{} }
	}
	return nil
}

// --- Mouse handling ---

func (m DashboardModel) updateMouse(msg tea.MouseMsg) (DashboardModel, tea.Cmd) {
	// Click release — check zones
	if msg.Action == tea.MouseActionRelease {
		// Picker item clicks
		if m.pickerActive {
			for i, def := range m.pickerDefs {
				if zone.Get(fmt.Sprintf("picker-team-%d", i)).InBounds(msg) {
					name := def.Name
					m.pickerActive = false
					return m, func() tea.Msg { return CreateSpecializedTeamMsg{Name: name} }
				}
			}
			// Click outside picker dismisses it
			m.pickerActive = false
			return m, nil
		}

		// Task card clicks
		for _, t := range m.tasks {
			if zone.Get(fmt.Sprintf("dash-task-%s", t.ID)).InBounds(msg) {
				id, _ := strconv.Atoi(t.ID)
				return m, func() tea.Msg { return SwitchToTaskMsg{TaskID: id} }
			}
		}

		// Pane status clicks
		for _, ps := range m.snapshot.Panes {
			zoneID := fmt.Sprintf("dash-pane-%d-%d", ps.WindowIdx, ps.PaneIdx)
			if zone.Get(zoneID).InBounds(msg) {
				return m, nil // click acknowledged
			}
		}

		// Quick action clicks
		if zone.Get("dash-spawn-freelancer").InBounds(msg) {
			return m, func() tea.Msg { return ReservedFreelancerMsg{} }
		}
		if zone.Get("dash-get-status").InBounds(msg) {
			return m, func() tea.Msg { return GetStatusMsg{} }
		}
		if zone.Get("dash-create-team").InBounds(msg) {
			return m, func() tea.Msg { return CreateTeamMsg{} }
		}
		if zone.Get("dash-create-specialized").InBounds(msg) {
			return m, func() tea.Msg { return CreateSpecializedTeamMsg{} }
		}
		if zone.Get("dash-view-tasks").InBounds(msg) {
			return m, func() tea.Msg { return ViewTasksMsg{} }
		}
		if zone.Get("dash-compact-taskmaster").InBounds(msg) {
			return m, func() tea.Msg { return CompactTaskmasterMsg{} }
		}
	}

	// Mouse wheel — scroll content
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp {
			if m.scrollOffset > 0 {
				m.scrollOffset--
			}
			return m, nil
		}
		if msg.Button == tea.MouseButtonWheelDown {
			maxOff := m.maxScrollOffset()
			if m.scrollOffset < maxOff {
				m.scrollOffset++
			}
			return m, nil
		}
	}

	return m, nil
}

// --- Rendering ---

func (m DashboardModel) renderActiveTasks(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("ACTIVE TASKS")
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.tasks) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			Align(lipgloss.Center).
			Width(w).
			PaddingTop(2).
			PaddingBottom(1).
			Render("All clear — no active tasks ✓")
		return "\n" + header + "\n" + rule + "\n" + empty + "\n"
	}

	// Flex-wrap grid: calculate columns dynamically from available width
	const minCardW = 50
	const gapH = 2
	availW := w - 4
	cols := (availW + gapH) / (minCardW + gapH)
	if cols < 1 {
		cols = 1
	}
	if cols > 3 {
		cols = 3
	}
	cardW := availW/cols - gapH
	if cardW < 40 {
		cardW = 40
	}

	sort.Slice(m.tasks, func(i, j int) bool {
		var timeI, timeJ time.Time
		if hb, ok := m.heartbeats[m.tasks[i].ID]; ok {
			timeI = hb.LastActivity
		} else {
			timeI = time.Unix(m.tasks[i].Updated, 0)
		}
		if hb, ok := m.heartbeats[m.tasks[j].ID]; ok {
			timeJ = hb.LastActivity
		} else {
			timeJ = time.Unix(m.tasks[j].Updated, 0)
		}
		return timeI.After(timeJ)
	})

	const maxDashTasks = 6
	shown := m.tasks
	overflow := 0
	if len(shown) > maxDashTasks {
		overflow = len(shown) - maxDashTasks
		shown = shown[:maxDashTasks]
	}

	var cards []string
	for _, task := range shown {
		card := m.renderHeartbeatCard(task, cardW)
		cards = append(cards, card)
	}

	if overflow > 0 {
		more := lipgloss.NewStyle().
			Foreground(t.Primary).
			PaddingLeft(2).
			Render(fmt.Sprintf("  ＋ %d more tasks → press 3 to view all", overflow))
		cards = append(cards, zone.Mark("dash-view-tasks", more))
	}

	// Grid layout: group cards into rows of 'cols' each
	spacer := strings.Repeat(" ", gapH)
	var rows []string
	for i := 0; i < len(cards); i += cols {
		end := i + cols
		if end > len(cards) {
			end = len(cards)
		}
		var parts []string
		for j, c := range cards[i:end] {
			if j > 0 {
				parts = append(parts, spacer)
			}
			parts = append(parts, lipgloss.NewStyle().Width(cardW).Render(c))
		}
		rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, parts...))
	}

	grid := lipgloss.JoinVertical(lipgloss.Left, rows...)
	body := lipgloss.NewStyle().
		Padding(1, 1).
		Render(grid)

	return "\n" + header + "\n" + rule + "\n" + body
}

// categoryAccentColor returns the accent color for a task category.
func categoryAccentColor(category string, t styles.Theme) lipgloss.AdaptiveColor {
	switch category {
	case "feature":
		return t.Info
	case "bug", "bugfix":
		return t.Warning
	case "infrastructure":
		return t.Accent
	case "refactor":
		return t.Primary
	case "docs":
		return t.Success
	default:
		return t.Primary
	}
}

// roleDisplayNames maps PaneStatus.Role values to human-readable names.
var roleDisplayNames = map[string]string{
	"boss":            "Boss",
	"coordinator":     "Taskmaster",
	"task_reviewer":   "Task Reviewer",
	"deployment":      "Deployment",
	"doey_expert":     "Doey Expert",
	"subtaskmaster":   "Subtaskmaster",
	"worker":          "Worker",
	"freelancer":      "Freelancer",
	"info_panel":      "Info Panel",
}

// roleIcons maps PaneStatus.Role values to Unicode icons.
var roleIcons = map[string]string{
	"boss":            "★",
	"coordinator":     "◈",
	"task_reviewer":   "○",
	"deployment":      "○",
	"doey_expert":     "○",
	"subtaskmaster":   "◆",
	"worker":          "●",
	"freelancer":      "◇",
	"info_panel":      "ℹ",
}

// taskTitleByID finds a task title by its ID in the snapshot.
func (m DashboardModel) taskTitleByID(id string) string {
	for _, t := range m.snapshot.Tasks {
		if t.ID == id {
			return t.Title
		}
	}
	return ""
}

// subtaskForPane finds a subtask assigned to the given pane key (e.g. "2.1")
// within the given task.
func (m DashboardModel) subtaskForPane(taskID, paneKey string) *runtime.Subtask {
	for i, st := range m.snapshot.Subtasks {
		if st.TaskID == taskID && (st.Pane == paneKey || st.Worker == paneKey) {
			return &m.snapshot.Subtasks[i]
		}
	}
	return nil
}

// truncateStr truncates s to maxLen runes, adding "…" if truncated.
func truncateStr(s string, maxLen int) string {
	runes := []rune(s)
	if len(runes) <= maxLen {
		return s
	}
	if maxLen <= 1 {
		return "…"
	}
	return string(runes[:maxLen-1]) + "…"
}

func (m DashboardModel) renderTeamGrid(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("TEAMS")
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.snapshot.Teams) == 0 {
		spawnRow := m.renderSpawnCards(w)
		return "\n" + header + "\n" + rule + "\n\n" + spawnRow + "\n"
	}

	// Sort teams by window index
	var indices []int
	for idx := range m.snapshot.Teams {
		indices = append(indices, idx)
	}
	sort.Ints(indices)

	var cards []string
	for _, winIdx := range indices {
		team := m.snapshot.Teams[winIdx]

		// Determine pane list based on window type
		var allPanes []int
		switch winIdx {
		case 0:
			// Boss window: pane 1 is Boss (pane 0 is info panel, not an agent)
			allPanes = []int{1}
		case 1:
			// Core Team: panes 0-3 (Taskmaster, Task Reviewer, Deployment, Doey Expert)
			allPanes = []int{0, 1, 2, 3}
		default:
			// Worker teams: pane 0 = Subtaskmaster, rest = Workers
			allPanes = []int{0}
			allPanes = append(allPanes, team.WorkerPanes...)
		}

		// Determine border color based on activity
		hasBusy := false
		allFinished := len(allPanes) > 0
		for _, pIdx := range allPanes {
			key := fmt.Sprintf("%d.%d", winIdx, pIdx)
			if ps, ok := m.snapshot.Panes[key]; ok {
				if ps.Status == "BUSY" || ps.Status == "WORKING" {
					hasBusy = true
				}
				if ps.Status != "FINISHED" {
					allFinished = false
				}
			} else {
				allFinished = false
			}
		}

		// Border color: special accents for Boss/Core Team, standard for workers
		borderColor := t.Muted
		switch {
		case winIdx == 0 && hasBusy:
			borderColor = t.Warning // amber for active Boss
		case winIdx == 0:
			borderColor = t.Highlight // warm gold for idle Boss
		case winIdx == 1 && hasBusy:
			borderColor = t.Info // cyan for active Core Team
		case winIdx == 1:
			borderColor = t.Primary // blue for idle Core Team
		case hasBusy:
			borderColor = t.Success
		case allFinished:
			borderColor = t.Info
		}

		// Build card title line
		var titleLine string
		switch winIdx {
		case 0:
			// Boss card
			titleLine = lipgloss.NewStyle().Bold(true).Foreground(t.Warning).Render("★ Boss") +
				t.RenderDim(" W0")
		case 1:
			// Core Team card
			titleLine = lipgloss.NewStyle().Bold(true).Foreground(t.Info).Render("◈ Core Team") +
				t.RenderDim(" W1")
		default:
			// Worker team: task-centric header
			badge := lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render(fmt.Sprintf(" W%d", winIdx))
			freelancerBadge := ""
			if team.TeamType == "freelancer" {
				freelancerBadge = t.RenderAccent(" [F]")
			}

			// Try to show task title + ID in header
			if team.TaskID != "" {
				taskTitle := m.taskTitleByID(team.TaskID)
				if taskTitle != "" {
					taskTitle = truncateStr(taskTitle, 30)
					titleLine = lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(
						fmt.Sprintf("Task #%s", team.TaskID)) + badge + freelancerBadge + "\n" +
						t.RenderDim("  "+taskTitle)
				} else {
					titleLine = lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(
						fmt.Sprintf("Task #%s", team.TaskID)) + badge + freelancerBadge
				}
			} else {
				title := team.TeamName
				if title == "" {
					title = fmt.Sprintf("Team %d", winIdx)
				}
				titleLine = lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(title) + badge + freelancerBadge
			}
		}

		// Render pane lines
		var paneLines []string
		for i, pIdx := range allPanes {
			shortKey := fmt.Sprintf("%d.%d", winIdx, pIdx)
			status := "—"
			var ps *runtime.PaneStatus
			if p, ok := m.snapshot.Panes[shortKey]; ok {
				status = p.Status
				ps = &p
			}

			// Separator between panes
			if i > 0 {
				sep := lipgloss.NewStyle().Foreground(t.Separator).Faint(true).Render("  " + strings.Repeat("┄", 18))
				paneLines = append(paneLines, sep)
			}

			// Resolve role icon and name from PaneStatus.Role, fallback to window/pane index
			icon := paneRoleIcon(winIdx, pIdx, team.TeamType, ps)
			roleName := paneRoleName(winIdx, pIdx, team.TeamType, ps)

			// For worker panes (window 2+, pane > 0): show subtask title instead of "Worker N"
			subtaskTitle := ""
			if winIdx >= 2 && pIdx > 0 && team.TaskID != "" {
				if st := m.subtaskForPane(team.TaskID, shortKey); st != nil {
					if cleaned := taskcard.CleanSubtaskTitle(st.Title); cleaned != "" {
						subtaskTitle = cleaned
						if st.Status == "done" || st.Status == "failed" {
							subtaskTitle += " [" + st.Status + "]"
						}
					}
				}
			}

			iconStyled := lipgloss.NewStyle().Foreground(styles.StatusColor(status)).Render(icon)
			nameStyled := lipgloss.NewStyle().Foreground(t.Text).Render(roleName)
			statusBadge := styles.StatusBadge(status)
			paneLines = append(paneLines, fmt.Sprintf("  %s %s  %s", iconStyled, nameStyled, statusBadge))

			// Line 2: subtask title (for workers) or task reference
			if subtaskTitle != "" {
				label := subtaskTitle
				if ps != nil && ps.SubtaskID != "" {
					label = "#" + ps.SubtaskID + " " + subtaskTitle
				}
				stLine := t.RenderDim("    " + truncateStr(label, 28))
				paneLines = append(paneLines, stLine)
			} else if ps != nil && ps.Task != "" && winIdx >= 2 {
				taskLine := t.RenderDim(fmt.Sprintf("    Task #%s", ps.Task))
				paneLines = append(paneLines, taskLine)
			}

			// Context usage bar
			if ctxPct, ok := m.snapshot.ContextPct[shortKey]; ok && ctxPct > 0 {
				bar := renderContextBar(ctxPct, 10, t)
				paneLines = append(paneLines, "    "+bar)
			}
		}

		content := titleLine + "\n" + strings.Join(paneLines, "\n")

		cardStyle := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(borderColor).
			Padding(0, 1)

		cards = append(cards, cardStyle.Render(content))
	}

	// Flex-wrap grid: calculate columns dynamically from available width
	const cardW = 36 // fixed card render width (content + border + padding)
	const gapH = 2   // horizontal gap between cards (spaces)

	availW := w - 2 // account for body padding
	cols := (availW + gapH) / (cardW + gapH)
	if cols < 1 {
		cols = 1
	}

	spacer := strings.Repeat(" ", gapH)
	var rows []string
	for i := 0; i < len(cards); i += cols {
		end := i + cols
		if end > len(cards) {
			end = len(cards)
		}
		// Size each card to fixed width and interleave spacers
		var parts []string
		for j, c := range cards[i:end] {
			if j > 0 {
				parts = append(parts, spacer)
			}
			parts = append(parts, lipgloss.NewStyle().Width(cardW).Render(c))
		}
		rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, parts...))
	}

	grid := lipgloss.JoinVertical(lipgloss.Left, rows...)
	body := lipgloss.NewStyle().Padding(1, 1).Render(grid)
	spawnRow := m.renderSpawnCards(w)
	return "\n" + header + "\n" + rule + "\n" + body + "\n" + spawnRow
}

// paneRoleIcon returns a Unicode icon for the pane's role.
// Uses PaneStatus.Role when available, falls back to window/pane index heuristics.
func paneRoleIcon(winIdx, paneIdx int, teamType string, ps *runtime.PaneStatus) string {
	if ps != nil && ps.Role != "" {
		if icon, ok := roleIcons[ps.Role]; ok {
			return icon
		}
	}
	if teamType == "freelancer" {
		return "◇"
	}
	switch winIdx {
	case 0:
		if paneIdx == 0 {
			return "ℹ"
		}
		return "★"
	case 1:
		if paneIdx == 0 {
			return "◈"
		}
		return "○"
	default:
		if paneIdx == 0 {
			return "◆"
		}
		return "●"
	}
}

// paneRoleName returns a human-readable role name for the pane.
// Uses PaneStatus.Role when available, falls back to window/pane index heuristics.
func paneRoleName(winIdx, paneIdx int, teamType string, ps *runtime.PaneStatus) string {
	if ps != nil && ps.Role != "" {
		if name, ok := roleDisplayNames[ps.Role]; ok {
			if ps.Role == "worker" || ps.Role == "freelancer" {
				return fmt.Sprintf("%s %d", name, paneIdx)
			}
			return name
		}
	}
	if teamType == "freelancer" {
		return fmt.Sprintf("Freelancer %d", paneIdx)
	}
	switch winIdx {
	case 0:
		if paneIdx == 0 {
			return "Info Panel"
		}
		return "Boss"
	case 1:
		coreRoles := []string{"Taskmaster", "Task Reviewer", "Deployment", "Doey Expert"}
		if paneIdx < len(coreRoles) {
			return coreRoles[paneIdx]
		}
		return fmt.Sprintf("Worker %d", paneIdx)
	default:
		if paneIdx == 0 {
			return "Subtaskmaster"
		}
		return fmt.Sprintf("Worker %d", paneIdx)
	}
}

// renderContextBar renders a mini progress bar for context percentage.
func renderContextBar(pct int, barWidth int, t styles.Theme) string {
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	filled := pct * barWidth / 100
	if filled > barWidth {
		filled = barWidth
	}

	// Color: green (<50%), yellow (50-75%), red (>75%)
	var barColor lipgloss.AdaptiveColor
	switch {
	case pct >= 75:
		barColor = t.Danger
	case pct >= 50:
		barColor = t.Warning
	default:
		barColor = t.Success
	}

	filledStr := lipgloss.NewStyle().Foreground(barColor).Render(strings.Repeat("▓", filled))
	emptyStr := t.RenderFaint(strings.Repeat("░", barWidth-filled))
	pctStr := t.RenderDim(fmt.Sprintf(" %d%%", pct))
	return filledStr + emptyStr + pctStr
}

func (m DashboardModel) renderHeartbeatCard(task runtime.PersistentTask, w int) string {
	t := m.theme
	accent := categoryAccentColor(task.Category, t)

	// Determine health state for visual hierarchy
	health := ""
	if hs, ok := m.heartbeats[task.ID]; ok {
		health = hs.Health
	}
	isBlocked := task.Blockers != ""
	isDone := task.Status == "done" || task.Status == "cancelled"
	isFaint := isDone || health == "stale" || (health == "idle" && !isDone)

	// --- Line 1: icon + #ID bold + Title ---
	icon := styles.TaskIcon(task.Status, t)
	idTag := lipgloss.NewStyle().Bold(true).Foreground(accent).Render(fmt.Sprintf("#%s", task.ID))
	title := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(task.Title)
	line1 := icon + " " + idTag + " " + title

	// --- Line 2: status badge + type tag + team badge + tags + Q&A badge ---
	badge := styles.StatusBadgeCard(task.Status, t)
	typeTag := ""
	if task.Type != "" {
		typeTag = " " + styles.TypeTagCard(task.Type, t)
	}
	teamBadge := ""
	if task.Team != "" {
		teamBadge = " " + lipgloss.NewStyle().
			Foreground(t.BgText).
			Background(accent).
			Padding(0, 1).
			Render(task.Team)
	}
	tagPills := ""
	for _, tag := range task.Tags {
		tagPills += " " + lipgloss.NewStyle().
			Foreground(accent).
			Faint(true).
			Render("‹"+tag+"›")
	}
	// Q&A badge: count conversation entries from logs
	qaCount := 0
	for _, log := range task.Logs {
		upper := strings.ToUpper(log.Entry)
		if strings.HasPrefix(upper, "USER:") || strings.HasPrefix(upper, "AI:") || strings.HasPrefix(upper, "CONVERSATION:") {
			qaCount++
		}
	}
	qaBadge := ""
	if qaCount > 0 {
		qaBadge = " " + lipgloss.NewStyle().Foreground(t.Info).Render(fmt.Sprintf("💬 %d", qaCount))
	}
	line2 := badge + typeTag + teamBadge + tagPills + qaBadge

	// --- Line 2b: blocked indicator ---
	blockedLine := ""
	if isBlocked {
		firstLine := task.Blockers
		if idx := strings.Index(firstLine, "\n"); idx > 0 {
			firstLine = firstLine[:idx]
		}
		if len(firstLine) > w-20 {
			firstLine = firstLine[:w-23] + "..."
		}
		blockedLine = lipgloss.NewStyle().Foreground(t.Danger).Bold(true).Render("⚠ Blocked: " + firstLine)
	}

	// --- Line 3: subtask progress bar ---
	progressLine := ""
	if len(task.Subtasks) > 0 {
		done := 0
		for _, st := range task.Subtasks {
			if st.Status == "done" {
				done++
			}
		}
		total := len(task.Subtasks)
		barWidth := w - 22
		if barWidth < 10 {
			barWidth = 10
		}
		bar := styles.ExpandedProgressBar(t, done, total, barWidth)
		label := styles.CardMetaStyle(t).Render(fmt.Sprintf("  %d/%d subtasks", done, total))
		progressLine = bar + label
	}

	// --- Line 4: compact subtask list (Claude Code style) ---
	var subtaskLines []string
	if len(task.Subtasks) > 0 {
		contentW := w - 6
		if contentW < 20 {
			contentW = 20
		}
		// Separate active/pending from done
		var activeSubtasks, doneSubtasks []runtime.PersistentSubtask
		for _, st := range task.Subtasks {
			if st.Status == "done" {
				doneSubtasks = append(doneSubtasks, st)
			} else {
				activeSubtasks = append(activeSubtasks, st)
			}
		}
		// Render active and pending subtasks in full
		for _, st := range activeSubtasks {
			cleaned := taskcard.CleanSubtaskTitle(st.Title)
			if cleaned == "" {
				continue
			}
			var icon string
			var lineStyle lipgloss.Style
			switch st.Status {
			case "in_progress":
				icon = t.RenderWarning("■")
				lineStyle = lipgloss.NewStyle().Foreground(t.Text)
			default: // pending and others
				icon = t.RenderDim("□")
				lineStyle = lipgloss.NewStyle().Foreground(t.Muted)
			}
			title := truncateStr(cleaned, contentW)
			subtaskLines = append(subtaskLines, "  "+icon+" "+lineStyle.Render(title))
		}
		// Collapse done subtasks into "+N completed" summary
		if len(doneSubtasks) > 0 {
			if len(activeSubtasks) == 0 {
				// All done — show them individually
				for _, st := range doneSubtasks {
					cleaned := taskcard.CleanSubtaskTitle(st.Title)
					if cleaned == "" {
						continue
					}
					icon := lipgloss.NewStyle().Foreground(t.Success).Faint(true).Render("✔")
					title := truncateStr(cleaned, contentW)
					styled := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Strikethrough(true).Render(title)
					subtaskLines = append(subtaskLines, "  "+icon+" "+styled)
				}
			} else {
				// Mixed — show one example done + collapsed count
				if len(doneSubtasks) == 1 {
					st := doneSubtasks[0]
					if cleaned := taskcard.CleanSubtaskTitle(st.Title); cleaned != "" {
						icon := lipgloss.NewStyle().Foreground(t.Success).Faint(true).Render("✔")
						title := truncateStr(cleaned, contentW)
						styled := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Strikethrough(true).Render(title)
						subtaskLines = append(subtaskLines, "  "+icon+" "+styled)
					}
				} else {
					summary := t.RenderFaint(
						fmt.Sprintf("  … +%d completed", len(doneSubtasks)))
					subtaskLines = append(subtaskLines, summary)
				}
			}
		}
	}

	// --- Line 5: heartbeat line ---
	heartbeatLine := ""
	if hs, ok := m.heartbeats[task.ID]; ok && hs.ActiveWorkers > 0 {
		healthDot := styles.HealthDot(hs.Health, t)

		// Spinner active indicator
		spinnerPrefix := ""
		if hs.SpinnerActive {
			spinnerPrefix = lipgloss.NewStyle().Foreground(t.Success).Bold(true).Render("● ")
		}

		workers := fmt.Sprintf("%d worker", hs.ActiveWorkers)
		if hs.ActiveWorkers != 1 {
			workers += "s"
		}
		parts := spinnerPrefix + healthDot + " " + styles.CardMetaStyle(t).Render(workers+" active")
		if hs.ActivityText != "" {
			parts += t.DotSeparator() + styles.CardMetaStyle(t).Render(hs.ActivityText)
		}
		// Activity time emphasis: color based on recency
		if !hs.LastActivity.IsZero() {
			elapsed := time.Since(hs.LastActivity)
			ageText := formatDashAge(elapsed) + " ago"
			switch {
			case elapsed < 10*time.Second:
				parts += lipgloss.NewStyle().Foreground(t.Success).Bold(true).Render("  now")
			case elapsed < 60*time.Second:
				parts += t.RenderSuccess("  " + ageText)
			case elapsed < 120*time.Second:
				parts += t.RenderWarning("  " + ageText)
			default:
				parts += lipgloss.NewStyle().Foreground(t.Danger).Faint(true).Render("  " + ageText)
			}
		}
		heartbeatLine = parts
	}

	// --- Line 6: latest update ---
	updateLine := ""
	if len(task.Updates) > 0 {
		latest := task.Updates[len(task.Updates)-1]
		ts := ""
		if latest.Timestamp > 0 {
			ts = time.Unix(latest.Timestamp, 0).Format("15:04") + " "
		}
		author := ""
		if latest.Author != "" {
			author = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render(latest.Author) + " "
		}
		text := latest.Text
		if len(text) > w-20 {
			text = text[:w-23] + "..."
		}
		updateLine = styles.CardMetaStyle(t).Render(ts) + author + t.Dim.Render(text)
	}

	// Assemble all non-empty lines
	var lines []string
	lines = append(lines, line1, line2)
	if blockedLine != "" {
		lines = append(lines, blockedLine)
	}
	if progressLine != "" {
		lines = append(lines, progressLine)
	}
	if len(subtaskLines) > 0 {
		lines = append(lines, subtaskLines...)
	}
	lines = append(lines, heartbeatLine)
	if updateLine != "" {
		lines = append(lines, updateLine)
	}

	content := strings.Join(lines, "\n")

	// Apply faint to entire content for stale/done/idle tasks
	if isFaint {
		content = lipgloss.NewStyle().Faint(true).Render(content)
	}

	// No card border — clean list style like Claude Code
	cardStyle := lipgloss.NewStyle().
		Padding(0, 1).
		Width(w)

	rendered := cardStyle.Render(content)
	return zone.Mark(fmt.Sprintf("dash-task-%s", task.ID), rendered)
}

// formatDashAge formats a duration into a compact age string.
func formatDashAge(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}

func (m DashboardModel) renderTeamPicker(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("SELECT TEAM DEFINITION")
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.pickerDefs) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(4).
			Render("No .team.md files found in teams/  (esc to close)")
		return "\n" + header + "\n" + rule + "\n" + empty + "\n"
	}

	var rows []string
	for i, def := range m.pickerDefs {
		cursor := "  "
		nameStyle := lipgloss.NewStyle().Foreground(t.Text)
		descStyle := lipgloss.NewStyle().Foreground(t.Muted).Faint(true)
		if i == m.pickerCursor {
			cursor = "▸ "
			nameStyle = nameStyle.Bold(true).Foreground(t.Primary)
		}
		name := nameStyle.Render(def.Name)
		desc := ""
		if def.Description != "" {
			desc = descStyle.Render(" — " + def.Description)
		}
		row := cursor + name + desc
		rows = append(rows, zone.Mark(fmt.Sprintf("picker-team-%d", i), row))
	}

	hint := lipgloss.NewStyle().
		Foreground(t.Muted).Faint(true).PaddingLeft(4).
		Render("j/k = navigate  enter = spawn  esc = cancel")

	body := lipgloss.NewStyle().
		PaddingLeft(3).PaddingTop(1).PaddingBottom(1).
		Render(strings.Join(rows, "\n"))

	return "\n" + header + "\n" + rule + "\n" + body + "\n" + hint + "\n"
}

func (m DashboardModel) renderSpawnCards(w int) string {
	t := m.theme

	numCards := len(quickActions)
	if numCards == 0 {
		return ""
	}

	// Compact card sizing — small and subtle
	usableW := w - 4
	gap := 1
	cardW := (usableW - gap*(numCards-1)) / numCards
	if cardW < 16 {
		cardW = 16
	}
	if cardW > 22 {
		cardW = 22
	}

	var cards []string
	for i, action := range quickActions {
		selected := m.focused && i == m.actionCursor
		cardStr := styles.TeamSpawnCard(t, action.icon, action.label, action.description, cardW, selected)
		cards = append(cards, zone.Mark(action.zoneID, cardStr))
	}

	row := lipgloss.JoinHorizontal(lipgloss.Top, cards[0])
	for i := 1; i < len(cards); i++ {
		row = lipgloss.JoinHorizontal(lipgloss.Top, row, strings.Repeat(" ", gap), cards[i])
	}

	return lipgloss.NewStyle().PaddingLeft(1).Render(row)
}

