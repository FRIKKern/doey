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
)

// SwitchToTaskMsg requests the root model switch to the Tasks tab and select a task.
type SwitchToTaskMsg struct{ TaskID int }

// SpawnFreelancerMsg requests launching a freelancer.
type SpawnFreelancerMsg struct{}

// GetStatusMsg requests a status refresh.
type GetStatusMsg struct{}

// CreateTeamMsg requests team creation.
type CreateTeamMsg struct{}

// ViewTasksMsg requests switching to the Tasks tab.
type ViewTasksMsg struct{}

// dashTickMsg is the internal tick for reloading task data.
type dashTickMsg time.Time

// taskEntry is an internal summary of an active task for display.
type taskEntry struct {
	ID     int
	Title  string
	Status string
	Type   string
}

// quickAction defines a quick action card.
type quickAction struct {
	icon        string
	label       string
	description string
	zoneID      string
}

// quickActions is the ordered list of dashboard action cards.
var quickActions = []quickAction{
	{"◈", "Spawn Freelancers", "Launch reserved freelancer pool", "dash-spawn-freelancer"},
	{"◉", "Get Status", "View team and worker status", "dash-get-status"},
	{"⊞", "Create Team", "Add a new specialist team", "dash-create-team"},
	{"☰", "View Tasks", "Browse and manage project tasks", "dash-view-tasks"},
}

// DashboardModel is the primary landing tab (command center).
type DashboardModel struct {
	runtimeDir   string
	projectDir   string
	width        int
	height       int
	theme        styles.Theme
	focused      bool
	tasks        []taskEntry
	keyMap       keys.KeyMap
	scrollOffset int
	actionCursor int              // selected quick action card (0..3)
	snapshot     runtime.Snapshot // live snapshot for pane/result/message data
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
		return m, m.tickCmd()

	case SnapshotMsg:
		m.snapshot = runtime.Snapshot(msg)
		return m, nil

	case tea.KeyMsg:
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
	sections = append(sections, m.renderActiveTasks(w))
	sections = append(sections, m.renderTeamStatus(w))
	sections = append(sections, m.renderQuickActions(w))
	sections = append(sections, m.renderRecentActivity(w))

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
	sections = append(sections, m.renderTeamStatus(w))
	sections = append(sections, m.renderQuickActions(w))
	sections = append(sections, m.renderRecentActivity(w))
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

	var active []taskEntry
	for _, t := range store.Tasks {
		if t.Status == "active" || t.Status == "in_progress" {
			id, _ := strconv.Atoi(t.ID)
			active = append(active, taskEntry{
				ID:     id,
				Title:  t.Title,
				Status: t.Status,
				Type:   t.Type,
			})
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
		return func() tea.Msg { return SpawnFreelancerMsg{} }
	case "dash-get-status":
		return func() tea.Msg { return GetStatusMsg{} }
	case "dash-create-team":
		return func() tea.Msg { return CreateTeamMsg{} }
	case "dash-view-tasks":
		return func() tea.Msg { return ViewTasksMsg{} }
	}
	return nil
}

// --- Mouse handling ---

func (m DashboardModel) updateMouse(msg tea.MouseMsg) (DashboardModel, tea.Cmd) {
	// Click release — check zones
	if msg.Action == tea.MouseActionRelease {
		// Task card clicks
		for _, t := range m.tasks {
			if zone.Get(fmt.Sprintf("dash-task-%d", t.ID)).InBounds(msg) {
				id := t.ID
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
			return m, func() tea.Msg { return SpawnFreelancerMsg{} }
		}
		if zone.Get("dash-get-status").InBounds(msg) {
			return m, func() tea.Msg { return GetStatusMsg{} }
		}
		if zone.Get("dash-create-team").InBounds(msg) {
			return m, func() tea.Msg { return CreateTeamMsg{} }
		}
		if zone.Get("dash-view-tasks").InBounds(msg) {
			return m, func() tea.Msg { return ViewTasksMsg{} }
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
			PaddingLeft(3).
			PaddingTop(1).
			Render("No active tasks")
		return "\n" + header + "\n" + rule + "\n" + empty + "\n"
	}

	cardW := w - 8
	if cardW > styles.MaxCardWidth {
		cardW = styles.MaxCardWidth
	}
	if cardW < 30 {
		cardW = 30
	}

	var cards []string
	for _, task := range m.tasks {
		card := m.renderTaskCard(task, cardW)
		cards = append(cards, card)
	}

	body := lipgloss.NewStyle().
		Padding(1, 3).
		Render(strings.Join(cards, "\n"))

	return "\n" + header + "\n" + rule + "\n" + body
}

func (m DashboardModel) renderTaskCard(task taskEntry, w int) string {
	t := m.theme

	// Status badge
	badge := styles.StatusBadgeCard(task.Status, t)

	// Type tag
	typeTag := ""
	if task.Type != "" {
		typeTag = " " + styles.TypeTagCard(task.Type, t)
	}

	// Title
	title := lipgloss.NewStyle().
		Bold(true).
		Foreground(t.Text).
		Render(fmt.Sprintf("#%d %s", task.ID, task.Title))

	// ID line
	idStr := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Render(fmt.Sprintf("Task %d", task.ID))

	content := title + "\n" + badge + typeTag + "  " + idStr

	// Show assigned workers from pane statuses
	taskIDStr := strconv.Itoa(task.ID)
	var assignedPanes []runtime.PaneStatus
	for _, ps := range m.snapshot.Panes {
		if ps.Task != "" && strings.Contains(ps.Task, taskIDStr) {
			assignedPanes = append(assignedPanes, ps)
		}
	}
	if len(assignedPanes) > 0 {
		var workerBadges []string
		finished := 0
		for _, ps := range assignedPanes {
			label := fmt.Sprintf("W%d.%d", ps.WindowIdx, ps.PaneIdx)
			var statusStyle lipgloss.Style
			switch ps.Status {
			case "BUSY", "WORKING":
				statusStyle = lipgloss.NewStyle().Foreground(t.Primary)
			case "FINISHED":
				statusStyle = lipgloss.NewStyle().Foreground(t.Success)
				finished++
			case "ERROR":
				statusStyle = lipgloss.NewStyle().Foreground(t.Danger)
			default:
				statusStyle = lipgloss.NewStyle().Foreground(t.Muted)
			}
			workerBadges = append(workerBadges, statusStyle.Render(label+": "+ps.Status))
		}
		workerLine := lipgloss.NewStyle().Foreground(t.Muted).Render("Workers: ") +
			strings.Join(workerBadges, lipgloss.NewStyle().Foreground(t.Muted).Render(" | "))
		progress := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).
			Render(fmt.Sprintf("  (%d/%d done)", finished, len(assignedPanes)))
		content += "\n" + workerLine + progress
	}

	cardStyle := styles.CardStyle(t, task.Status, false, w)
	rendered := cardStyle.Render(content)

	return zone.Mark(fmt.Sprintf("dash-task-%d", task.ID), rendered)
}

func (m DashboardModel) renderQuickActions(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("QUICK ACTIONS")
	rule := t.Faint.Render(strings.Repeat("─", w))

	numCards := len(quickActions)
	if numCards == 0 {
		return "\n" + header + "\n" + rule + "\n"
	}

	// Card sizing — responsive to terminal width
	usableW := w - 8 // outer padding
	gap := 2
	cardW := (usableW - gap*(numCards-1)) / numCards
	if cardW < 16 {
		cardW = 16
	}
	if cardW > 30 {
		cardW = 30
	}

	// Render each card using the QuickActionCard style function
	var cards []string
	for i, action := range quickActions {
		selected := m.focused && i == m.actionCursor
		cardStr := styles.QuickActionCard(t, action.icon, action.label, action.description, cardW, selected)
		cards = append(cards, zone.Mark(action.zoneID, cardStr))
	}

	row := lipgloss.JoinHorizontal(lipgloss.Top, cards[0])
	for i := 1; i < len(cards); i++ {
		row = lipgloss.JoinHorizontal(lipgloss.Top, row, strings.Repeat(" ", gap), cards[i])
	}

	hint := ""
	if m.focused {
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).Faint(true).PaddingLeft(3).
			Render("h/l = navigate  enter = activate")
	}

	body := lipgloss.NewStyle().
		Padding(1, 3).
		Render(row)

	return "\n" + header + "\n" + rule + "\n" + body + "\n" + hint + "\n"
}

// renderTeamStatus shows a compact grid of pane statuses grouped by window.
func (m DashboardModel) renderTeamStatus(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("TEAM STATUS")
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.snapshot.Panes) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No workers running")
		return "\n" + header + "\n" + rule + "\n" + empty + "\n"
	}

	// Group panes by window index
	byWindow := make(map[int][]runtime.PaneStatus)
	for _, ps := range m.snapshot.Panes {
		byWindow[ps.WindowIdx] = append(byWindow[ps.WindowIdx], ps)
	}

	// Sort window indices
	windowIdxs := make([]int, 0, len(byWindow))
	for wi := range byWindow {
		windowIdxs = append(windowIdxs, wi)
	}
	sort.Ints(windowIdxs)

	var windowRows []string
	for _, wi := range windowIdxs {
		panes := byWindow[wi]
		// Sort by pane index
		sort.Slice(panes, func(i, j int) bool {
			return panes[i].PaneIdx < panes[j].PaneIdx
		})

		// Window label
		teamName := fmt.Sprintf("Window %d", wi)
		if tc, ok := m.snapshot.Teams[wi]; ok && tc.TeamName != "" {
			teamName = tc.TeamName
		}
		windowLabel := lipgloss.NewStyle().
			Bold(true).
			Foreground(t.Text).
			Render(teamName)

		// Pane badges
		var paneBadges []string
		for _, ps := range panes {
			icon := "○"
			var fg lipgloss.TerminalColor = t.Muted
			switch ps.Status {
			case "READY":
				icon = "●"
				fg = t.Success
			case "BUSY", "WORKING":
				icon = "●"
				fg = t.Primary
			case "FINISHED":
				icon = "✓"
				fg = t.Success
			case "ERROR":
				icon = "✕"
				fg = t.Danger
			case "RESERVED":
				icon = "◆"
				fg = t.Accent
			}

			label := fmt.Sprintf("%s %d.%d %s", icon, ps.WindowIdx, ps.PaneIdx, ps.Status)
			badge := lipgloss.NewStyle().
				Foreground(fg).
				Render(label)
			paneBadges = append(paneBadges, zone.Mark(
				fmt.Sprintf("dash-pane-%d-%d", ps.WindowIdx, ps.PaneIdx),
				badge,
			))
		}

		windowRows = append(windowRows, windowLabel+"\n  "+strings.Join(paneBadges, "  "))
	}

	body := lipgloss.NewStyle().
		Padding(1, 3).
		Render(strings.Join(windowRows, "\n\n"))

	return "\n" + header + "\n" + rule + "\n" + body
}

// renderRecentActivity shows the last few IPC messages.
func (m DashboardModel) renderRecentActivity(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("RECENT ACTIVITY")
	rule := t.Faint.Render(strings.Repeat("─", w))

	msgs := m.snapshot.Messages
	if len(msgs) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No recent activity")
		return "\n" + header + "\n" + rule + "\n" + empty + "\n"
	}

	// Sort by timestamp descending and take last 5
	sorted := make([]runtime.Message, len(msgs))
	copy(sorted, msgs)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Timestamp > sorted[j].Timestamp
	})
	if len(sorted) > 5 {
		sorted = sorted[:5]
	}

	fromStyle := lipgloss.NewStyle().Foreground(t.Primary).Bold(true)
	subjStyle := lipgloss.NewStyle().Foreground(t.Warning)
	bodyStyle := lipgloss.NewStyle().Foreground(t.Muted).Faint(true)

	var lines []string
	for _, msg := range sorted {
		from := fromStyle.Render(msg.From)
		subj := subjStyle.Render(msg.Subject)

		body := msg.Body
		body = strings.ReplaceAll(body, "\n", " ")
		if len(body) > 80 {
			body = body[:77] + "..."
		}
		bodyTxt := bodyStyle.Render(body)

		line := fmt.Sprintf("  %s  %s", from, subj)
		if body != "" {
			line += "\n    " + bodyTxt
		}
		lines = append(lines, line)
	}

	content := lipgloss.NewStyle().
		Padding(1, 1).
		Render(strings.Join(lines, "\n"))

	return "\n" + header + "\n" + rule + "\n" + content + "\n"
}
