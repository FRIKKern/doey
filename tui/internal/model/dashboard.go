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

// ReservedFreelancerMsg requests launching a reserved freelancer pool.
type ReservedFreelancerMsg struct{}

// GetStatusMsg requests a status refresh.
type GetStatusMsg struct{}

// CreateTeamMsg requests team creation.
type CreateTeamMsg struct{}

// ViewTasksMsg requests switching to the Tasks tab.
type ViewTasksMsg struct{}

// dashTickMsg is the internal tick for reloading task data.
type dashTickMsg time.Time

// quickAction defines a quick action card.
type quickAction struct {
	icon        string
	label       string
	description string
	zoneID      string
}

// quickActions is the ordered list of dashboard action cards.
var quickActions = []quickAction{
	{"◆", "Spawn Freelancers", "Reserve 6 workers (3×2 grid)", "dash-spawn-freelancer"},
	{"→", "Get Status", "Ask Boss for team status", "dash-get-status"},
	{"⟫", "Create Team", "Add a new specialist team", "dash-create-team"},
	{"›", "View Tasks", "Browse and manage project tasks", "dash-view-tasks"},
	{"⊘", "Compact SM", "Compact Session Manager context", "dash-compact-sm"},
}

// DashboardModel is the primary landing tab (command center).
type DashboardModel struct {
	runtimeDir   string
	projectDir   string
	width        int
	height       int
	theme        styles.Theme
	focused      bool
	tasks        []runtime.PersistentTask
	heartbeats   map[string]runtime.HeartbeatState
	keyMap       keys.KeyMap
	scrollOffset int
	actionCursor int              // selected quick action card (0..4)
	snapshot     runtime.Snapshot // live snapshot for pane/result/message data
	feedbackMsg  string
	feedbackTime time.Time
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
		feedbackStyle := lipgloss.NewStyle().
			Foreground(m.theme.Success).
			Bold(true).
			PaddingLeft(2)
		sections = append(sections, feedbackStyle.Render("✓ "+m.feedbackMsg))
	}
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

// SetHeartbeats updates the heartbeat state map for all tasks.
func (m *DashboardModel) SetHeartbeats(hb map[string]runtime.HeartbeatState) {
	m.heartbeats = hb
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
	case "dash-get-status":
		return func() tea.Msg { return GetStatusMsg{} }
	case "dash-create-team":
		return func() tea.Msg { return CreateTeamMsg{} }
	case "dash-view-tasks":
		return func() tea.Msg { return ViewTasksMsg{} }
	case "dash-compact-sm":
		return func() tea.Msg { return CompactSMMsg{} }
	}
	return nil
}

// --- Mouse handling ---

func (m DashboardModel) updateMouse(msg tea.MouseMsg) (DashboardModel, tea.Cmd) {
	// Click release — check zones
	if msg.Action == tea.MouseActionRelease {
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
		if zone.Get("dash-view-tasks").InBounds(msg) {
			return m, func() tea.Msg { return ViewTasksMsg{} }
		}
		if zone.Get("dash-compact-sm").InBounds(msg) {
			return m, func() tea.Msg { return CompactSMMsg{} }
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

	cardW := w - 4
	if cardW < 40 {
		cardW = 40
	}

	var cards []string
	for _, task := range m.tasks {
		card := m.renderHeartbeatCard(task, cardW)
		cards = append(cards, card)
	}

	body := lipgloss.NewStyle().
		Padding(1, 1).
		Render(strings.Join(cards, "\n\n"))

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

func (m DashboardModel) renderHeartbeatCard(task runtime.PersistentTask, w int) string {
	t := m.theme
	accent := categoryAccentColor(task.Category, t)

	// --- Line 1: icon + #ID bold + Title ---
	icon := styles.TaskIcon(task.Status)
	idTag := lipgloss.NewStyle().Bold(true).Foreground(accent).Render(fmt.Sprintf("#%s", task.ID))
	title := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(task.Title)
	line1 := icon + " " + idTag + " " + title

	// --- Line 2: status badge + type tag + team badge + tags ---
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
	line2 := badge + typeTag + teamBadge + tagPills

	// --- Line 3: description excerpt (first 2-3 lines, dimmed) ---
	descLine := ""
	if task.Description != "" {
		desc := task.Description
		descLines := strings.SplitN(desc, "\n", 4)
		if len(descLines) > 3 {
			descLines = descLines[:3]
		}
		descText := strings.Join(descLines, "\n")
		contentW := w - 4
		if contentW > 0 && len(descText) > contentW*3 {
			descText = descText[:contentW*3-3] + "..."
		}
		descLine = t.Dim.Render(descText)
	}

	// --- Line 4: subtask progress bar ---
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

	// --- Line 5: heartbeat line ---
	heartbeatLine := ""
	if hs, ok := m.heartbeats[task.ID]; ok && hs.ActiveWorkers > 0 {
		var healthDot string
		switch hs.Health {
		case "green", "healthy":
			healthDot = lipgloss.NewStyle().Foreground(t.Success).Render("●")
		case "amber", "degraded":
			healthDot = lipgloss.NewStyle().Foreground(t.Warning).Render("●")
		case "idle":
			healthDot = lipgloss.NewStyle().Foreground(t.Muted).Render("●")
		default:
			healthDot = lipgloss.NewStyle().Foreground(t.Danger).Render("●")
		}
		workers := fmt.Sprintf("%d worker", hs.ActiveWorkers)
		if hs.ActiveWorkers != 1 {
			workers += "s"
		}
		parts := healthDot + " " + styles.CardMetaStyle(t).Render(workers+" active")
		if hs.ActivityText != "" {
			parts += t.DotSeparator() + styles.CardMetaStyle(t).Render(hs.ActivityText)
		}
		if !hs.LastActivity.IsZero() {
			elapsed := time.Since(hs.LastActivity)
			if elapsed < 5*time.Second {
				parts += lipgloss.NewStyle().Foreground(t.Success).Render("  now")
			} else {
				parts += styles.CardMetaStyle(t).Render("  " + formatDashAge(elapsed) + " ago")
			}
		}
		heartbeatLine = parts
	} else {
		heartbeatLine = lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("● waiting for activity...")
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

	// --- Line 7: files changed ---
	filesLine := ""
	if len(task.FilesChanged) > 0 {
		shown := task.FilesChanged
		suffix := ""
		if len(shown) > 3 {
			shown = shown[:3]
			suffix = fmt.Sprintf(" +%d more", len(task.FilesChanged)-3)
		}
		filesLine = styles.CardMetaStyle(t).Render("files: " + strings.Join(shown, ", ") + suffix)
	}

	// Assemble all non-empty lines
	var lines []string
	lines = append(lines, line1, line2)
	if descLine != "" {
		lines = append(lines, descLine)
	}
	if progressLine != "" {
		lines = append(lines, progressLine)
	}
	lines = append(lines, heartbeatLine)
	if updateLine != "" {
		lines = append(lines, updateLine)
	}
	if filesLine != "" {
		lines = append(lines, filesLine)
	}

	content := strings.Join(lines, "\n")

	// Card with rounded border, accent-colored
	cardStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(accent).
		Padding(0, 1).
		Width(w - 2)

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
			icon := "•"
			var fg lipgloss.TerminalColor = t.Muted
			switch ps.Status {
			case "READY":
				icon = "◆"
				fg = t.Success
			case "BUSY", "WORKING":
				icon = "◆"
				fg = t.Primary
			case "FINISHED":
				icon = "✓"
				fg = t.Success
			case "ERROR":
				icon = "✗"
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
