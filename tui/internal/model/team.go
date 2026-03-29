package model

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// --- Message types ---

// LaunchTeamMsg is emitted when the user presses Enter on a non-running team.
type LaunchTeamMsg struct{ Name string }

// StopTeamMsg is emitted when the user presses x on a running team.
type StopTeamMsg struct {
	Name      string
	WindowIdx int
}

// ToggleStarMsg is emitted when the user presses s.
type ToggleStarMsg struct{ Name string }

// ToggleStartupMsg is emitted when the user presses a.
type ToggleStartupMsg struct{ Name string }

// EditTeamMsg is emitted when the user presses e.
type EditTeamMsg struct{ Name string }

// NewTeamMsg is emitted when the user presses n.
type NewTeamMsg struct{}

// --- Model ---

// TeamModel is the unified team management hub: list + detail.
type TeamModel struct {
	// Data
	entries []runtime.TeamEntry
	panes   map[string]runtime.PaneStatus
	teams   map[int]runtime.TeamConfig
	theme   styles.Theme

	// Navigation
	summaryMode bool
	cursor      int
	keyMap      keys.KeyMap

	// Editor sub-component
	editor EditorModel

	// Dispatch mode
	dispatching    bool
	dispatchInput  string
	dispatchTarget int

	// Layout
	width   int
	height  int
	focused bool
}

// NewTeamModel creates a team panel starting in summary (list) mode.
func NewTeamModel(theme styles.Theme) TeamModel {
	return TeamModel{
		theme:       theme,
		panes:       make(map[string]runtime.PaneStatus),
		teams:       make(map[int]runtime.TeamConfig),
		summaryMode: true,
		keyMap:      keys.DefaultKeyMap(),
		editor:      NewEditorModel(theme),
	}
}

// Init is a no-op for the team sub-model.
func (m TeamModel) Init() tea.Cmd {
	return nil
}

// Update handles key navigation and actions.
func (m TeamModel) Update(msg tea.Msg) (TeamModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	// Handle dispatch text input mode
	if m.dispatching {
		if kmsg, ok := msg.(tea.KeyMsg); ok {
			switch kmsg.Type {
			case tea.KeyEnter:
				if m.dispatchInput != "" {
					m.dispatching = false
					input := m.dispatchInput
					target := m.dispatchTarget
					m.dispatchInput = ""
					return m, func() tea.Msg {
						return DispatchTeamMsg{WindowIdx: target, Task: input}
					}
				}
			case tea.KeyEsc:
				m.dispatching = false
				m.dispatchInput = ""
				return m, nil
			case tea.KeyBackspace:
				if len(m.dispatchInput) > 0 {
					m.dispatchInput = m.dispatchInput[:len(m.dispatchInput)-1]
				}
			default:
				if kmsg.Type == tea.KeyRunes {
					m.dispatchInput += string(kmsg.Runes)
				} else if kmsg.Type == tea.KeySpace {
					m.dispatchInput += " "
				}
			}
			return m, nil
		}
	}

	// Handle editor messages
	switch msg.(type) {
	case OpenEditorMsg:
		omsg := msg.(OpenEditorMsg)
		if omsg.IsNew {
			m.editor.NewTeam()
		} else {
			m.editor.SetTeamDef(omsg.Def)
		}
		m.editor.SetSize(m.width, m.height)
		return m, nil
	case CloseEditorMsg:
		m.editor.active = false
		return m, nil
	}

	// Delegate to editor when active
	if m.editor.IsActive() {
		var cmd tea.Cmd
		m.editor, cmd = m.editor.Update(msg)
		return m, cmd
	}

	if msg, ok := msg.(tea.KeyMsg); ok {
		if m.summaryMode {
			return m.updateList(msg)
		}
		return m.updateDetail(msg)
	}

	return m, nil
}

func (m TeamModel) updateList(msg tea.KeyMsg) (TeamModel, tea.Cmd) {
	total := len(m.entries)
	if total == 0 {
		// Only allow 'n' when empty
		if msg.String() == "n" {
			return m, func() tea.Msg { return NewTeamMsg{} }
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
		return m.handleAction(msg)
	}
	return m, nil
}

func (m TeamModel) handleAction(msg tea.KeyMsg) (TeamModel, tea.Cmd) {
	if m.cursor < 0 || m.cursor >= len(m.entries) {
		return m, nil
	}
	entry := m.entries[m.cursor]

	switch msg.String() {
	case "s":
		return m, func() tea.Msg { return ToggleStarMsg{Name: entry.Def.Name} }
	case "a":
		return m, func() tea.Msg { return ToggleStartupMsg{Name: entry.Def.Name} }
	case "e":
		return m, func() tea.Msg { return EditTeamMsg{Name: entry.Def.Name} }
	case "n":
		return m, func() tea.Msg { return NewTeamMsg{} }
	case "d":
		if entry.Running {
			m.dispatching = true
			m.dispatchInput = ""
			m.dispatchTarget = entry.WindowIdx
			return m, nil
		}
	case "x":
		if entry.Running {
			return m, func() tea.Msg {
				return StopTeamMsg{Name: entry.Def.Name, WindowIdx: entry.WindowIdx}
			}
		}
	}

	return m, nil
}

func (m TeamModel) updateDetail(msg tea.KeyMsg) (TeamModel, tea.Cmd) {
	if key.Matches(msg, m.keyMap.Back) {
		m.summaryMode = true
		return m, nil
	}

	if m.cursor < 0 || m.cursor >= len(m.entries) {
		return m, nil
	}
	entry := m.entries[m.cursor]

	// Enter in detail = launch or focus
	if key.Matches(msg, m.keyMap.Select) {
		if entry.Running {
			// Focus: no message needed yet, could add FocusTeamMsg later
			return m, nil
		}
		return m, func() tea.Msg { return LaunchTeamMsg{Name: entry.Def.Name} }
	}

	// Allow actions in detail mode too
	switch msg.String() {
	case "s":
		return m, func() tea.Msg { return ToggleStarMsg{Name: entry.Def.Name} }
	case "a":
		return m, func() tea.Msg { return ToggleStartupMsg{Name: entry.Def.Name} }
	case "d":
		if entry.Running {
			m.dispatching = true
			m.dispatchInput = ""
			m.dispatchTarget = entry.WindowIdx
			return m, nil
		}
	case "x":
		if entry.Running {
			return m, func() tea.Msg {
				return StopTeamMsg{Name: entry.Def.Name, WindowIdx: entry.WindowIdx}
			}
		}
	}

	return m, nil
}

// SetSnapshot rebuilds data from a fresh snapshot.
func (m *TeamModel) SetSnapshot(snap runtime.Snapshot) {
	m.entries = snap.TeamEntries
	m.panes = snap.Panes
	m.teams = snap.Teams

	m.sortEntries()

	// Clamp cursor
	if m.cursor >= len(m.entries) {
		m.cursor = max(0, len(m.entries)-1)
	}
}

// sortEntries orders: starred first, then running, then alphabetical.
func (m *TeamModel) sortEntries() {
	sort.SliceStable(m.entries, func(i, j int) bool {
		a, b := m.entries[i], m.entries[j]
		// Starred first
		if a.Starred != b.Starred {
			return a.Starred
		}
		// Running second
		if a.Running != b.Running {
			return a.Running
		}
		// Alphabetical (prefer Label for multi-instance teams)
		nameA := a.Def.Name
		if a.Label != "" {
			nameA = a.Label
		}
		nameB := b.Def.Name
		if b.Label != "" {
			nameB = b.Label
		}
		return nameA < nameB
	})
}

// SetSize updates the panel dimensions.
func (m *TeamModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.editor.SetSize(w, h)
}

// SetFocused toggles focus state.
func (m *TeamModel) SetFocused(focused bool) {
	m.focused = focused
}

// View renders list, detail, or editor mode.
func (m TeamModel) View() string {
	if m.editor.IsActive() {
		return m.editor.View()
	}
	if m.summaryMode {
		return m.viewList()
	}
	return m.viewDetail()
}

// --- List view ---

func (m TeamModel) viewList() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("TEAMS")
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.entries) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No team definitions found. Add .team.md files to teams/.")
		hint := ""
		if m.focused {
			hint = "\n" + lipgloss.NewStyle().
				Foreground(t.Muted).Faint(true).PaddingLeft(3).PaddingTop(1).
				Render("n = new team")
		}
		content := header + "\n" + rule + "\n" + empty + hint
		return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
	}

	// Summary counts
	running, starred := 0, 0
	for _, e := range m.entries {
		if e.Running {
			running++
		}
		if e.Starred {
			starred++
		}
	}
	summaryParts := []string{fmt.Sprintf("%d teams", len(m.entries))}
	if running > 0 {
		summaryParts = append(summaryParts,
			lipgloss.NewStyle().Foreground(t.Success).Render(fmt.Sprintf("%d running", running)))
	}
	if starred > 0 {
		summaryParts = append(summaryParts,
			lipgloss.NewStyle().Foreground(t.Warning).Render(fmt.Sprintf("%d starred", starred)))
	}
	summary := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(strings.Join(summaryParts, "  "))

	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	// Build rows with section headers
	var lines []string
	lastSection := ""
	for i, entry := range m.entries {
		section := m.sectionOf(entry)
		if section != lastSection {
			if lastSection != "" {
				lines = append(lines, "")
			}
			sectionHeader := t.SectionHeader.Copy().PaddingLeft(1).
				Render(section)
			lines = append(lines, sectionHeader)
			lastSection = section
		}

		line := m.renderListRow(entry, w)

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
	if m.focused {
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).Faint(true).Padding(1, 3).
			Render("enter = details  s = star  a = startup  d = dispatch  n = new  x = stop")
	}

	content := header + "\n" + rule + "\n" + summary + "\n\n" + body + "\n" + hint
	if m.dispatching {
		content += "\n" + m.renderDispatchBar()
	}
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}

// sectionOf returns the section header label for sorting display.
func (m TeamModel) sectionOf(e runtime.TeamEntry) string {
	if e.Starred {
		return "STARRED"
	}
	if e.Running {
		return "RUNNING"
	}
	return "AVAILABLE"
}

// renderListRow renders a single team entry as a list line.
func (m TeamModel) renderListRow(e runtime.TeamEntry, maxW int) string {
	t := m.theme
	d := e.Def

	// Star indicator
	star := "  "
	if e.Starred {
		star = lipgloss.NewStyle().Foreground(t.Warning).Render("★ ")
	}

	// Status indicator
	var statusDot string
	if e.Running {
		statusDot = lipgloss.NewStyle().Foreground(t.Success).Render("● ")
	} else {
		statusDot = lipgloss.NewStyle().Foreground(t.Muted).Render("○ ")
	}

	// Name (prefer Label for multi-instance teams)
	displayName := d.Name
	if e.Label != "" {
		displayName = e.Label
	}
	name := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(displayName)

	// Status label
	statusLabel := ""
	if e.Running {
		statusLabel = lipgloss.NewStyle().Foreground(t.Success).Render(" Running")
		// Count workers
		if tc, ok := m.teams[e.WindowIdx]; ok {
			busy, idle := m.countWorkerStatuses(e.WindowIdx, tc)
			var parts []string
			if busy > 0 {
				parts = append(parts, lipgloss.NewStyle().Foreground(t.Warning).Render(fmt.Sprintf("%d busy", busy)))
			}
			if idle > 0 {
				parts = append(parts, lipgloss.NewStyle().Foreground(t.Success).Render(fmt.Sprintf("%d idle", idle)))
			}
			if len(parts) > 0 {
				statusLabel += " (" + strings.Join(parts, ", ") + ")"
			}
		}
	}

	// Workers count
	workers := lipgloss.NewStyle().Foreground(t.Accent).Render(fmt.Sprintf(" %dW", d.Workers))

	// Type badge
	typeBadge := ""
	if d.Type != "" {
		typeBadge = " " + t.Dim.Render("["+d.Type+"]")
	}

	// Startup indicator
	startupBadge := ""
	if e.Startup {
		startupBadge = " " + lipgloss.NewStyle().Foreground(t.Primary).Render("[auto]")
	}

	// Description (fill remaining space)
	prefix := star + statusDot + name + workers + statusLabel + typeBadge + startupBadge
	prefixW := lipgloss.Width(prefix)
	desc := ""
	if d.Description != "" {
		maxDesc := maxW - prefixW - 8
		if maxDesc > 10 {
			dd := d.Description
			if len(dd) > maxDesc {
				dd = dd[:maxDesc-1] + "…"
			}
			desc = t.Dim.Render(" — " + dd)
		}
	}

	return star + statusDot + name + workers + statusLabel + typeBadge + startupBadge + desc
}

// countWorkerStatuses counts busy and idle workers for a team.
func (m TeamModel) countWorkerStatuses(windowIdx int, tc runtime.TeamConfig) (busy, idle int) {
	for _, pi := range tc.WorkerPanes {
		paneID := fmt.Sprintf("%d.%d", windowIdx, pi)
		if ps, ok := m.panes[paneID]; ok {
			switch ps.Status {
			case "BUSY", "WORKING":
				busy++
			default:
				idle++
			}
		} else {
			idle++
		}
	}
	return
}

// --- Detail view ---

func (m TeamModel) viewDetail() string {
	w := m.width
	if w < 30 {
		w = 30
	}

	if m.cursor < 0 || m.cursor >= len(m.entries) {
		m.summaryMode = true
		return m.viewList()
	}

	entry := m.entries[m.cursor]
	d := entry.Def

	// Layout: side-by-side if wide enough, stacked otherwise
	var content string
	if w >= 100 {
		content = m.viewDetailSideBySide(entry, d, w)
	} else {
		content = m.viewDetailStacked(entry, d, w)
	}
	if m.dispatching {
		content += "\n" + m.renderDispatchBar()
	}
	return content
}

func (m TeamModel) viewDetailSideBySide(entry runtime.TeamEntry, d runtime.TeamDef, totalW int) string {
	t := m.theme

	displayName := d.Name
	if entry.Label != "" {
		displayName = entry.Label
	}
	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(strings.ToUpper(displayName))
	rule := t.Faint.Render(strings.Repeat("─", totalW))

	leftW := totalW * 60 / 100
	rightW := totalW - leftW - 3 // 3 for separator

	leftContent := m.renderDetailFields(entry, d, leftW)
	rightContent := m.renderWorkerPanel(entry, rightW)

	left := lipgloss.NewStyle().Width(leftW).Render(leftContent)
	sep := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).
		Render(strings.Repeat("│\n", m.height/2))
	right := lipgloss.NewStyle().Width(rightW).Render(rightContent)

	panels := lipgloss.JoinHorizontal(lipgloss.Top, left, "  "+sep, right)

	actionHint := m.renderActionHint(entry)

	return header + "\n" + rule + "\n" + m.renderBackHint(entry) + "\n" + panels + "\n" + actionHint
}

func (m TeamModel) viewDetailStacked(entry runtime.TeamEntry, d runtime.TeamDef, w int) string {
	t := m.theme

	displayName := d.Name
	if entry.Label != "" {
		displayName = entry.Label
	}
	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(strings.ToUpper(displayName))
	rule := t.Faint.Render(strings.Repeat("─", w))

	fields := m.renderDetailFields(entry, d, w)
	workers := m.renderWorkerPanel(entry, w)

	actionHint := m.renderActionHint(entry)

	return header + "\n" + rule + "\n" + m.renderBackHint(entry) + "\n" + fields + "\n" + workers + "\n" + actionHint
}

func (m TeamModel) renderBackHint(entry runtime.TeamEntry) string {
	t := m.theme
	action := "enter = launch"
	if entry.Running {
		action = "enter = focus  d = dispatch"
	}
	return lipgloss.NewStyle().
		Foreground(t.Muted).Faint(true).PaddingLeft(3).
		Render("esc = back  " + action)
}

func (m TeamModel) renderActionHint(entry runtime.TeamEntry) string {
	t := m.theme
	parts := []string{"s = star", "a = startup"}
	if entry.Running {
		parts = append(parts, "d = dispatch", "x = stop")
	}
	return lipgloss.NewStyle().
		Foreground(t.Muted).Faint(true).Padding(1, 3).
		Render(strings.Join(parts, "  "))
}

// renderDetailFields renders the team detail card fields.
func (m TeamModel) renderDetailFields(entry runtime.TeamEntry, d runtime.TeamDef, w int) string {
	t := m.theme
	labelStyle := t.StatLabel.Copy().Width(14)
	valueStyle := t.Body

	var fields []string

	// Name + status
	statusStr := lipgloss.NewStyle().Foreground(t.Muted).Render("Available")
	if entry.Running {
		statusStr = lipgloss.NewStyle().Foreground(t.Success).Bold(true).Render("Running")
	}
	fields = append(fields, labelStyle.Render("Name")+"  "+valueStyle.Render(d.Name))
	fields = append(fields, labelStyle.Render("Status")+"  "+statusStr)

	// Star + Startup flags
	flagParts := []string{}
	if entry.Starred {
		flagParts = append(flagParts, lipgloss.NewStyle().Foreground(t.Warning).Render("★ Starred"))
	}
	if entry.Startup {
		flagParts = append(flagParts, lipgloss.NewStyle().Foreground(t.Primary).Render("Auto-launch"))
	}
	if len(flagParts) > 0 {
		fields = append(fields, labelStyle.Render("Flags")+"  "+strings.Join(flagParts, "  "))
	}

	if d.Description != "" {
		descWidth := w - 20
		if descWidth < 20 {
			descWidth = 20
		}
		fields = append(fields, labelStyle.Render("Description")+"  "+
			lipgloss.NewStyle().Foreground(t.Text).Width(descWidth).Render(d.Description))
	}

	if d.Type != "" {
		fields = append(fields, labelStyle.Render("Type")+"  "+valueStyle.Render(d.Type))
	}

	fields = append(fields, labelStyle.Render("Workers")+"  "+
		lipgloss.NewStyle().Foreground(t.Success).Render(fmt.Sprintf("%d", d.Workers)))

	if d.Grid != "" {
		fields = append(fields, labelStyle.Render("Grid")+"  "+valueStyle.Render(d.Grid))
	}
	if d.ManagerModel != "" {
		fields = append(fields, labelStyle.Render("Manager Model")+"  "+valueStyle.Render(d.ManagerModel))
	}
	if d.WorkerModel != "" {
		fields = append(fields, labelStyle.Render("Worker Model")+"  "+valueStyle.Render(d.WorkerModel))
	}

	// Panes roster
	if len(d.Panes) > 0 {
		fields = append(fields, "")
		fields = append(fields, t.SectionHeader.Copy().Render("PANE ROSTER"))
		for _, p := range d.Panes {
			role := lipgloss.NewStyle().Foreground(t.Primary).Render(p.Role)
			name := ""
			if p.Name != "" {
				name = " " + t.Dim.Render("("+p.Name+")")
			}
			agent := ""
			if p.Agent != "" {
				agent = " " + lipgloss.NewStyle().Foreground(t.Accent).Render("→ "+p.Agent)
			}
			model := ""
			if p.Model != "" {
				model = " " + t.Dim.Render("["+p.Model+"]")
			}
			fields = append(fields, fmt.Sprintf("  %d. %s%s%s%s", p.Index, role, name, agent, model))
		}
	}

	// Workflows
	if len(d.Workflows) > 0 {
		fields = append(fields, "")
		fields = append(fields, t.SectionHeader.Copy().Render("WORKFLOWS"))
		for _, wf := range d.Workflows {
			trigger := lipgloss.NewStyle().Foreground(t.Warning).Render(wf.Trigger)
			from := valueStyle.Render(wf.From)
			to := lipgloss.NewStyle().Foreground(t.Success).Render(wf.To)
			subject := ""
			if wf.Subject != "" {
				subject = " " + t.Dim.Render("re: "+wf.Subject)
			}
			fields = append(fields, fmt.Sprintf("  %s: %s → %s%s", trigger, from, to, subject))
		}
	}

	// Briefing excerpt
	if d.Briefing != "" {
		fields = append(fields, "")
		fields = append(fields, t.SectionHeader.Copy().Render("BRIEFING"))
		briefWidth := w - 8
		if briefWidth < 20 {
			briefWidth = 20
		}
		briefing := d.Briefing
		if len(briefing) > 500 {
			briefing = briefing[:497] + "..."
		}
		fields = append(fields, "  "+lipgloss.NewStyle().Foreground(t.Text).Width(briefWidth).Render(briefing))
	}

	if d.FilePath != "" {
		fields = append(fields, "")
		fields = append(fields, labelStyle.Render("File")+"  "+t.Dim.Render(d.FilePath))
	}

	return lipgloss.NewStyle().Padding(1, 3).Render(strings.Join(fields, "\n"))
}

// renderWorkerPanel renders running worker statuses for a team.
func (m TeamModel) renderWorkerPanel(entry runtime.TeamEntry, w int) string {
	t := m.theme

	if !entry.Running {
		return lipgloss.NewStyle().Padding(1, 2).Foreground(t.Muted).
			Render("Not running — press Enter to launch")
	}

	tc, ok := m.teams[entry.WindowIdx]
	if !ok {
		return lipgloss.NewStyle().Padding(1, 2).Foreground(t.Muted).
			Render("No runtime data available")
	}

	var lines []string
	lines = append(lines, t.SectionHeader.Copy().Render("WORKER STATUS"))
	lines = append(lines, "")

	// Manager
	if tc.ManagerPane != "" {
		lines = append(lines, m.renderPaneStatus(entry.WindowIdx, tc.ManagerPane, "Manager", w))
	}

	// Workers
	for _, pi := range tc.WorkerPanes {
		lines = append(lines, m.renderPaneStatus(entry.WindowIdx, fmt.Sprintf("%d", pi), "Worker", w))
	}

	return lipgloss.NewStyle().Padding(1, 2).Render(strings.Join(lines, "\n"))
}

// renderPaneStatus renders a single pane with status dot and task.
func (m TeamModel) renderPaneStatus(windowIdx int, paneIdx string, role string, maxW int) string {
	paneID := fmt.Sprintf("%d.%s", windowIdx, paneIdx)

	status := "—"
	task := ""
	if ps, ok := m.panes[paneID]; ok {
		status = ps.Status
		task = ps.Task
	}

	// Color-coded dot
	statusColor := styles.StatusColor(status)
	dot := lipgloss.NewStyle().Foreground(statusColor).Render("●")

	// Role label
	roleStr := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Text).Width(10).Render(role)

	// Status text
	statusStr := lipgloss.NewStyle().Foreground(statusColor).Width(10).Render(status)

	// Task (truncated)
	taskStr := ""
	if task != "" {
		maxTask := maxW - 30
		if maxTask < 10 {
			maxTask = 10
		}
		if len(task) > maxTask {
			task = task[:maxTask-1] + "…"
		}
		taskStr = m.theme.Dim.Render(task)
	}

	return fmt.Sprintf("  %s %s %s %s", dot, roleStr, statusStr, taskStr)
}

// renderDispatchBar renders the inline text input for dispatching a task.
func (m TeamModel) renderDispatchBar() string {
	t := m.theme
	prompt := lipgloss.NewStyle().Bold(true).Foreground(t.Primary).
		Render("Dispatch to W" + strconv.Itoa(m.dispatchTarget) + ": ")
	input := lipgloss.NewStyle().Foreground(t.Text).
		Render(m.dispatchInput + "█")
	return lipgloss.NewStyle().Padding(1, 3).Render(prompt + input)
}

// --- Helpers ---

// truncate shortens a string to maxLen, adding "…" if truncated.
func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	if maxLen <= 1 {
		return "…"
	}
	return strings.TrimSpace(s[:maxLen-1]) + "…"
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
