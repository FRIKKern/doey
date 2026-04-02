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

// quickActions is the ordered list of dashboard action cards.
var quickActions = []quickAction{
	{"◆", "Reserved Freelancers", "Reserve independent workers", "dash-spawn-freelancer"},
	{"⟫", "Regular Team", "Manager + workers team", "dash-create-team"},
	{"◈", "Specialized Team", "Team from definition file", "dash-create-specialized"},
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
	sections = append(sections, m.renderQuickActions(w))

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
	sections = append(sections, m.renderQuickActions(w))
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

	cardW := w - 4
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

	// Determine health state for visual hierarchy
	health := ""
	if hs, ok := m.heartbeats[task.ID]; ok {
		health = hs.Health
	}
	isBlocked := task.Blockers != ""
	isDone := task.Status == "done" || task.Status == "cancelled"
	isFaint := isDone || health == "stale" || (health == "idle" && !isDone)

	// --- Line 1: icon + #ID bold + Title ---
	icon := styles.TaskIcon(task.Status)
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
				parts += lipgloss.NewStyle().Foreground(t.Success).Render("  " + ageText)
			case elapsed < 120*time.Second:
				parts += lipgloss.NewStyle().Foreground(t.Warning).Render("  " + ageText)
			default:
				parts += lipgloss.NewStyle().Foreground(t.Danger).Faint(true).Render("  " + ageText)
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

	// --- Activity: recent messages relevant to this task ---
	var activityLines []string
	if len(m.snapshot.Messages) > 0 {
		taskID := task.ID
		taskIDHash := "#" + taskID
		teamName := task.Team

		// Filter messages matching this task
		var matched []runtime.Message
		for _, msg := range m.snapshot.Messages {
			if strings.Contains(msg.Body, taskIDHash) || strings.Contains(msg.Body, taskID) ||
				strings.Contains(msg.Subject, taskIDHash) || strings.Contains(msg.Subject, taskID) ||
				(teamName != "" && strings.Contains(msg.From, teamName)) {
				matched = append(matched, msg)
			}
		}

		// Sort descending by timestamp, take at most 3
		sort.Slice(matched, func(i, j int) bool {
			return matched[i].Timestamp > matched[j].Timestamp
		})
		if len(matched) > 3 {
			matched = matched[:3]
		}

		if len(matched) > 0 {
			activityHeader := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("Activity")
			activityLines = append(activityLines, activityHeader)
			for _, msg := range matched {
				from := lipgloss.NewStyle().Foreground(t.Primary).Render(msg.From)
				subj := lipgloss.NewStyle().Foreground(t.Muted).Render(msg.Subject)
				body := strings.ReplaceAll(msg.Body, "\n", " ")
				maxBody := w - 30
				if maxBody < 20 {
					maxBody = 20
				}
				if len(body) > maxBody {
					body = body[:maxBody-3] + "..."
				}
				bodyTxt := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render(body)
				line := "  → " + from + " · " + subj
				if body != "" {
					line += " — " + bodyTxt
				}
				activityLines = append(activityLines, line)
			}
		}
	}

	// Assemble all non-empty lines
	var lines []string
	lines = append(lines, line1, line2)
	if blockedLine != "" {
		lines = append(lines, blockedLine)
	}
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
	if len(activityLines) > 0 {
		lines = append(lines, activityLines...)
	}

	content := strings.Join(lines, "\n")

	// Apply faint to entire content for stale/done/idle tasks
	if isFaint {
		content = lipgloss.NewStyle().Faint(true).Render(content)
	}

	// Card border color based on health + blocked state
	borderColor := accent // default: category accent (prominent)
	switch {
	case isBlocked:
		borderColor = t.Danger
	case isDone:
		borderColor = t.Muted
	case health == "stale":
		borderColor = t.Muted
	case health == "degraded":
		borderColor = t.Warning
	case health == "idle":
		borderColor = t.Subtle
	}

	cardStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(borderColor).
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

func (m DashboardModel) renderQuickActions(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("SPAWN TEAMS")
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

