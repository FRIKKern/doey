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
	zone "github.com/lrstanley/bubblezone"
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
	width        int
	height       int
	focused      bool
	scrollOffset int
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

	switch msg := msg.(type) {
	case tea.MouseMsg:
		return m.updateMouse(msg)
	case tea.KeyMsg:
		if m.summaryMode {
			return m.updateList(msg)
		}
		return m.updateDetail(msg)
	}

	return m, nil
}

// updateMouse handles all mouse interactions for the team panel.
func (m TeamModel) updateMouse(msg tea.MouseMsg) (TeamModel, tea.Cmd) {
	// List mode clicks
	if m.summaryMode && msg.Action == tea.MouseActionRelease {
		for i := range m.entries {
			if zone.Get(fmt.Sprintf("team-%d", i)).InBounds(msg) {
				m.cursor = i
				m.ensureTeamVisible()
				m.summaryMode = false
				return m, nil
			}
		}
		// Health grid cell clicks
		for ri, e := range m.entries {
			if !e.Running {
				continue
			}
			tc, ok := m.teams[e.WindowIdx]
			if !ok {
				continue
			}
			for ci := range tc.WorkerPanes {
				if zone.Get(fmt.Sprintf("health-%d-%d", ri, ci)).InBounds(msg) {
					m.cursor = ri
					m.ensureTeamVisible()
					m.summaryMode = false
					return m, nil
				}
			}
		}
	}

	// Detail mode clicks
	if !m.summaryMode && msg.Action == tea.MouseActionRelease {
		if zone.Get("team-launch").InBounds(msg) {
			if m.cursor >= 0 && m.cursor < len(m.entries) {
				entry := m.entries[m.cursor]
				if !entry.Running {
					return m, func() tea.Msg { return LaunchTeamMsg{Name: entry.Def.Name} }
				}
			}
		}
		if zone.Get("team-stop").InBounds(msg) {
			if m.cursor >= 0 && m.cursor < len(m.entries) {
				entry := m.entries[m.cursor]
				if entry.Running {
					return m, func() tea.Msg {
						return StopTeamMsg{Name: entry.Def.Name, WindowIdx: entry.WindowIdx}
					}
				}
			}
		}
		if zone.Get("team-star").InBounds(msg) {
			if m.cursor >= 0 && m.cursor < len(m.entries) {
				entry := m.entries[m.cursor]
				return m, func() tea.Msg { return ToggleStarMsg{Name: entry.Def.Name} }
			}
		}
		// Worker entry clicks in detail view
		if m.cursor >= 0 && m.cursor < len(m.entries) {
			entry := m.entries[m.cursor]
			if entry.Running {
				if tc, ok := m.teams[entry.WindowIdx]; ok {
					for i := range tc.WorkerPanes {
						if zone.Get(fmt.Sprintf("team-worker-%d", i)).InBounds(msg) {
							// Worker selected — could trigger focus in future
							return m, nil
						}
					}
				}
			}
		}
	}

	// Mouse wheel scrolling
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp {
			if m.summaryMode {
				m.cursor--
				if m.cursor < 0 {
					m.cursor = max(0, len(m.entries)-1)
				}
				m.ensureTeamVisible()
			}
			return m, nil
		}
		if msg.Button == tea.MouseButtonWheelDown {
			if m.summaryMode {
				m.cursor++
				if m.cursor >= len(m.entries) {
					m.cursor = 0
				}
				m.ensureTeamVisible()
			}
			return m, nil
		}
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
		m.ensureTeamVisible()
	case key.Matches(msg, m.keyMap.Down):
		m.cursor++
		if m.cursor >= total {
			m.cursor = 0
		}
		m.ensureTeamVisible()
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

// ensureTeamVisible adjusts scrollOffset so the cursor card is in view.
// Each card is ~6 rendered lines (border + padding + 2-3 content lines + gap),
// plus section headers take ~2 lines. We estimate conservatively.
func (m *TeamModel) ensureTeamVisible() {
	if len(m.entries) == 0 {
		m.scrollOffset = 0
		return
	}

	// Estimate lines per card (rounded border + 1 padding top/bottom + 2-3 content + gap)
	const linesPerCard = 7
	const headerOverhead = 6 // TEAMS header + rule + summary + health grid estimate

	// Approximate line position of the cursor card
	cursorLine := headerOverhead
	lastSection := ""
	for i := 0; i < m.cursor && i < len(m.entries); i++ {
		section := m.sectionOf(m.entries[i])
		if section != lastSection {
			if lastSection != "" {
				cursorLine += 1 // blank line between sections
			}
			cursorLine += 1 // section header
			lastSection = section
		}
		cursorLine += linesPerCard
	}
	// Account for section header of cursor's own section
	if m.cursor < len(m.entries) {
		section := m.sectionOf(m.entries[m.cursor])
		if section != lastSection {
			if lastSection != "" {
				cursorLine += 1
			}
			cursorLine += 1
		}
	}

	viewport := m.height - 2
	if viewport < 1 {
		viewport = 1
	}

	// If cursor is above the visible area, scroll up
	if cursorLine < m.scrollOffset {
		m.scrollOffset = cursorLine
	}
	// If cursor is below the visible area, scroll down
	if cursorLine+linesPerCard > m.scrollOffset+viewport {
		m.scrollOffset = cursorLine + linesPerCard - viewport
	}
	if m.scrollOffset < 0 {
		m.scrollOffset = 0
	}
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

	// Card dimensions
	cardW := w - 10
	if cardW > styles.MaxCardWidth {
		cardW = styles.MaxCardWidth
	}
	if cardW < 20 {
		cardW = 20
	}

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

		cardContent := m.renderListRow(entry, w)
		selected := m.focused && i == m.cursor

		// Determine border color based on state
		borderColor := t.Separator
		if selected {
			borderColor = t.Primary
		}
		bgColor := lipgloss.AdaptiveColor{Light: "#FFFFFF", Dark: "#0F172A"}
		if selected {
			bgColor = lipgloss.AdaptiveColor{Light: "#F8FAFC", Dark: "#1E293B"}
		}

		card := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(borderColor).
			Background(bgColor).
			Width(cardW).
			Padding(1, 2).
			Render(cardContent)

		card = zone.Mark(fmt.Sprintf("team-%d", i), card)
		lines = append(lines, card)
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

	healthGrid := m.renderHealthGrid(w)
	var content string
	if healthGrid != "" {
		content = header + "\n" + rule + "\n" + summary + "\n\n" + healthGrid + "\n" + body + "\n" + hint
	} else {
		content = header + "\n" + rule + "\n" + summary + "\n\n" + body + "\n" + hint
	}
	if m.dispatching {
		content += "\n" + m.renderDispatchBar()
	}

	// Apply scroll offset — viewport follows cursor
	scrollLines := strings.Split(content, "\n")
	if m.scrollOffset > len(scrollLines)-1 {
		m.scrollOffset = len(scrollLines) - 1
	}
	if m.scrollOffset < 0 {
		m.scrollOffset = 0
	}
	if m.scrollOffset > 0 && m.scrollOffset < len(scrollLines) {
		scrollLines = scrollLines[m.scrollOffset:]
	}
	content = strings.Join(scrollLines, "\n")

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

// renderListRow renders a single team entry as a card.
func (m TeamModel) renderListRow(e runtime.TeamEntry, maxW int) string {
	t := m.theme
	d := e.Def

	// Card content width (minus border + padding)
	cardW := maxW - 10
	if cardW > styles.MaxCardWidth {
		cardW = styles.MaxCardWidth
	}
	if cardW < 20 {
		cardW = 20
	}

	// Star indicator
	star := ""
	if e.Starred {
		star = lipgloss.NewStyle().Foreground(t.Warning).Render("★") + " "
	}

	// Name (prefer Label for multi-instance teams)
	displayName := d.Name
	if e.Label != "" {
		displayName = e.Label
	}
	name := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(star + displayName)

	// Status badge
	var statusBadge string
	if e.Running {
		statusBadge = lipgloss.NewStyle().
			Foreground(t.BgText).
			Background(t.Success).
			Padding(0, 1).
			Render("Running")
	} else {
		statusBadge = lipgloss.NewStyle().
			Foreground(t.BgText).
			Background(t.Muted).
			Padding(0, 1).
			Render("Stopped")
	}

	// Title line: name + status badge right-aligned
	nameW := lipgloss.Width(name)
	badgeW := lipgloss.Width(statusBadge)
	gap := cardW - nameW - badgeW
	if gap < 1 {
		gap = 1
	}
	titleLine := name + strings.Repeat(" ", gap) + statusBadge

	// Meta line: workers, type, startup, worker status
	var metaParts []string
	metaParts = append(metaParts, lipgloss.NewStyle().Foreground(t.Accent).Render(fmt.Sprintf("%d workers", d.Workers)))
	if d.Type != "" {
		metaParts = append(metaParts, lipgloss.NewStyle().Foreground(t.Muted).Render("["+d.Type+"]"))
	}
	if e.Startup {
		metaParts = append(metaParts, lipgloss.NewStyle().Foreground(t.Primary).Render("[auto]"))
	}
	if e.Running {
		if tc, ok := m.teams[e.WindowIdx]; ok {
			busy, idle := m.countWorkerStatuses(e.WindowIdx, tc)
			if busy > 0 {
				metaParts = append(metaParts, lipgloss.NewStyle().Foreground(t.Warning).Render(fmt.Sprintf("%d busy", busy)))
			}
			if idle > 0 {
				metaParts = append(metaParts, lipgloss.NewStyle().Foreground(t.Success).Render(fmt.Sprintf("%d idle", idle)))
			}
		}
	}
	metaLine := strings.Join(metaParts, "  ")

	// Description (truncated)
	descLine := ""
	if d.Description != "" {
		dd := d.Description
		if len(dd) > cardW-2 {
			dd = dd[:cardW-3] + "…"
		}
		descLine = lipgloss.NewStyle().Foreground(t.Muted).Render(dd)
	}

	// Assemble card content
	var content string
	if descLine != "" {
		content = titleLine + "\n" + metaLine + "\n" + descLine
	} else {
		content = titleLine + "\n" + metaLine
	}

	return content
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

// --- Health grid ---

// renderHealthGrid renders a compact overview of all running teams with pane
// status dots and utilization percentage.
func (m TeamModel) renderHealthGrid(w int) string {
	t := m.theme

	// Aggregate across all running teams
	totalTeams, activeTeams := 0, 0
	totalWorkers, busyWorkers := 0, 0
	for _, e := range m.entries {
		totalTeams++
		if !e.Running {
			continue
		}
		activeTeams++
		tc, ok := m.teams[e.WindowIdx]
		if !ok {
			continue
		}
		for _, pi := range tc.WorkerPanes {
			totalWorkers++
			paneID := fmt.Sprintf("%d.%d", e.WindowIdx, pi)
			if ps, ok := m.panes[paneID]; ok {
				if ps.Status == "BUSY" || ps.Status == "WORKING" {
					busyWorkers++
				}
			}
		}
	}

	if activeTeams == 0 {
		return ""
	}

	// Summary line
	summaryStyle := lipgloss.NewStyle().Foreground(t.Text).PaddingLeft(2)
	teamsPart := lipgloss.NewStyle().Foreground(t.Success).Bold(true).
		Render(fmt.Sprintf("%d/%d", activeTeams, totalTeams))
	workersPart := lipgloss.NewStyle().Foreground(t.Warning).Bold(true).
		Render(fmt.Sprintf("%d/%d", busyWorkers, totalWorkers))
	summaryLine := summaryStyle.Render(
		teamsPart + " teams active" + t.DotSeparator() + workersPart + " workers busy")

	// Per-team rows: name + dots + utilization
	nameW := 20
	var rows []string
	for ri, e := range m.entries {
		if !e.Running {
			continue
		}
		tc, ok := m.teams[e.WindowIdx]
		if !ok {
			continue
		}

		// Team name (truncated)
		name := e.Def.Name
		if e.Label != "" {
			name = e.Label
		}
		if len(name) > nameW-2 {
			name = name[:nameW-3] + "…"
		}
		nameStr := lipgloss.NewStyle().Bold(true).Foreground(t.Text).
			Width(nameW).Render("  " + name)

		// Pane dots
		var dots []string
		teamBusy, teamTotal := 0, 0
		reserved := 0

		// Manager dot
		if tc.ManagerPane != "" {
			mgrID := fmt.Sprintf("%d.%s", e.WindowIdx, tc.ManagerPane)
			dots = append(dots, m.paneDot(mgrID))
		}

		// Worker dots
		for ci, pi := range tc.WorkerPanes {
			paneID := fmt.Sprintf("%d.%d", e.WindowIdx, pi)
			dot := zone.Mark(fmt.Sprintf("health-%d-%d", ri, ci), m.paneDot(paneID))
			dots = append(dots, dot)
			if ps, ok := m.panes[paneID]; ok {
				if ps.Status == "RESERVED" {
					reserved++
				} else {
					teamTotal++
					if ps.Status == "BUSY" || ps.Status == "WORKING" {
						teamBusy++
					}
				}
			} else {
				teamTotal++
			}
		}

		dotStr := strings.Join(dots, "")

		// Utilization
		util := 0
		if teamTotal > 0 {
			util = teamBusy * 100 / teamTotal
		}
		utilColor := t.Muted
		if util >= 80 {
			utilColor = t.Success
		} else if util > 0 {
			utilColor = t.Warning
		}
		utilStr := lipgloss.NewStyle().Foreground(utilColor).Width(12).
			Render(fmt.Sprintf("%d%% util", util))
		_ = reserved // reserved counted for exclusion but not displayed separately

		rows = append(rows, nameStr+" "+dotStr+"  "+utilStr)
	}

	gridRule := t.Faint.Render(strings.Repeat("─", w))
	gridHeader := t.SectionHeader.Copy().PaddingLeft(2).Render("HEALTH")

	return gridHeader + "\n" + summaryLine + "\n" +
		strings.Join(rows, "\n") + "\n" + gridRule
}

// paneDot returns a colored dot for a pane based on its status.
func (m TeamModel) paneDot(paneID string) string {
	ps, ok := m.panes[paneID]
	if !ok {
		return lipgloss.NewStyle().Foreground(m.theme.Muted).Faint(true).Render("○")
	}

	color := styles.StatusColor(ps.Status)
	switch ps.Status {
	case "RESERVED":
		return lipgloss.NewStyle().Foreground(color).Faint(true).Render("⊘")
	case "ERROR":
		return lipgloss.NewStyle().Foreground(color).Bold(true).Render("●")
	default:
		return lipgloss.NewStyle().Foreground(color).Render("●")
	}
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

	leftContent := m.renderDetailFields(entry, d, leftW-6)
	rightContent := m.renderWorkerPanel(entry, rightW-6)

	left := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Separator).
		Width(leftW).
		Padding(1, 2).
		Render(leftContent)
	right := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Separator).
		Width(rightW).
		Padding(1, 2).
		Render(rightContent)

	panels := lipgloss.JoinHorizontal(lipgloss.Top, left, " ", right)

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

	detailCardW := w - 8
	if detailCardW > styles.MaxCardWidth+10 {
		detailCardW = styles.MaxCardWidth + 10
	}

	fields := m.renderDetailFields(entry, d, detailCardW-6)
	fieldsCard := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Separator).
		Width(detailCardW).
		Padding(1, 2).
		MarginLeft(2).
		Render(fields)

	workers := m.renderWorkerPanel(entry, detailCardW-6)
	workersCard := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Separator).
		Width(detailCardW).
		Padding(1, 2).
		MarginLeft(2).
		Render(workers)

	actionHint := m.renderActionHint(entry)

	return header + "\n" + rule + "\n" + m.renderBackHint(entry) + "\n" + fieldsCard + "\n" + workersCard + "\n" + actionHint
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
	starBtn := zone.Mark("team-star", "s = star")
	parts := []string{starBtn, "a = startup"}
	if entry.Running {
		stopBtn := zone.Mark("team-stop", "x = stop")
		parts = append(parts, "d = dispatch", stopBtn)
	} else {
		launchBtn := zone.Mark("team-launch", "enter = launch")
		parts = append(parts, launchBtn)
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
	for i, pi := range tc.WorkerPanes {
		workerLine := m.renderPaneStatus(entry.WindowIdx, fmt.Sprintf("%d", pi), "Worker", w)
		lines = append(lines, zone.Mark(fmt.Sprintf("team-worker-%d", i), workerLine))
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
