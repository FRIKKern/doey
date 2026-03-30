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

// TeamModel is the unified team management hub: split-pane list + detail.
type TeamModel struct {
	// Data
	entries []runtime.TeamEntry
	panes   map[string]runtime.PaneStatus
	teams   map[int]runtime.TeamConfig
	theme   styles.Theme

	// Navigation
	summaryMode bool // kept for root.go isDetailView() — synced with leftFocused
	leftFocused bool
	cursor      int
	keyMap      keys.KeyMap
	rightScroll int

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

// NewTeamModel creates a team panel starting with left (list) panel focused.
func NewTeamModel(theme styles.Theme) TeamModel {
	return TeamModel{
		theme:       theme,
		panes:       make(map[string]runtime.PaneStatus),
		teams:       make(map[int]runtime.TeamConfig),
		summaryMode: true,
		leftFocused: true,
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
		return m.updateKey(msg)
	}

	return m, nil
}

// syncSummaryMode keeps summaryMode in sync with leftFocused for root.go.
func (m *TeamModel) syncSummaryMode() {
	m.summaryMode = m.leftFocused
}

// updateMouse handles all mouse interactions for the split-pane team panel.
func (m TeamModel) updateMouse(msg tea.MouseMsg) (TeamModel, tea.Cmd) {
	// Left panel: list item clicks
	if msg.Action == tea.MouseActionRelease {
		for i := range m.entries {
			if zone.Get(fmt.Sprintf("team-%d", i)).InBounds(msg) {
				m.cursor = i
				m.ensureTeamVisible()
				m.rightScroll = 0
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
					m.leftFocused = false
					m.syncSummaryMode()
					m.rightScroll = 0
					return m, nil
				}
			}
		}

		// Right panel action button clicks
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
		// Worker entry clicks in detail
		if m.cursor >= 0 && m.cursor < len(m.entries) {
			entry := m.entries[m.cursor]
			if entry.Running {
				if tc, ok := m.teams[entry.WindowIdx]; ok {
					for i := range tc.WorkerPanes {
						if zone.Get(fmt.Sprintf("team-worker-%d", i)).InBounds(msg) {
							return m, nil
						}
					}
				}
			}
		}
	}

	// Mouse wheel scrolling — route to focused panel
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp {
			if m.leftFocused {
				m.cursor--
				if m.cursor < 0 {
					m.cursor = max(0, len(m.entries)-1)
				}
				m.ensureTeamVisible()
				m.rightScroll = 0
			} else {
				if m.rightScroll > 0 {
					m.rightScroll--
				}
			}
			return m, nil
		}
		if msg.Button == tea.MouseButtonWheelDown {
			if m.leftFocused {
				m.cursor++
				if m.cursor >= len(m.entries) {
					m.cursor = 0
				}
				m.ensureTeamVisible()
				m.rightScroll = 0
			} else {
				m.rightScroll++
				m.clampRightScroll()
			}
			return m, nil
		}
	}

	return m, nil
}

func (m TeamModel) updateKey(msg tea.KeyMsg) (TeamModel, tea.Cmd) {
	total := len(m.entries)

	// Panel focus switching
	switch {
	case key.Matches(msg, m.keyMap.RightPanel) || (m.leftFocused && key.Matches(msg, m.keyMap.Select)):
		if m.leftFocused && total > 0 {
			m.leftFocused = false
			m.syncSummaryMode()
			m.rightScroll = 0
		}
		return m, nil

	case key.Matches(msg, m.keyMap.LeftPanel) || key.Matches(msg, m.keyMap.Back):
		if !m.leftFocused {
			m.leftFocused = true
			m.syncSummaryMode()
			return m, nil
		}
		return m, nil

	case key.Matches(msg, m.keyMap.Up):
		if m.leftFocused {
			if total > 0 {
				m.cursor--
				if m.cursor < 0 {
					m.cursor = total - 1
				}
				m.ensureTeamVisible()
				m.rightScroll = 0
			}
		} else {
			if m.rightScroll > 0 {
				m.rightScroll--
			}
		}
		return m, nil

	case key.Matches(msg, m.keyMap.Down):
		if m.leftFocused {
			if total > 0 {
				m.cursor++
				if m.cursor >= total {
					m.cursor = 0
				}
				m.ensureTeamVisible()
				m.rightScroll = 0
			}
		} else {
			m.rightScroll++
			m.clampRightScroll()
		}
		return m, nil
	}

	// Action keys work in both panels
	return m.handleAction(msg)
}

func (m TeamModel) handleAction(msg tea.KeyMsg) (TeamModel, tea.Cmd) {
	if m.cursor < 0 || m.cursor >= len(m.entries) {
		// Only allow 'n' when empty
		if msg.String() == "n" {
			return m, func() tea.Msg { return NewTeamMsg{} }
		}
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

	// Enter in right panel = launch
	if !m.leftFocused && key.Matches(msg, m.keyMap.Select) {
		if !entry.Running {
			return m, func() tea.Msg { return LaunchTeamMsg{Name: entry.Def.Name} }
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
		if a.Starred != b.Starred {
			return a.Starred
		}
		if a.Running != b.Running {
			return a.Running
		}
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
func (m *TeamModel) ensureTeamVisible() {
	if len(m.entries) == 0 {
		m.scrollOffset = 0
		return
	}

	const linesPerItem = 3
	const headerOverhead = 3

	cursorLine := headerOverhead
	lastSection := ""
	for i := 0; i < m.cursor && i < len(m.entries); i++ {
		section := m.sectionOf(m.entries[i])
		if section != lastSection {
			if lastSection != "" {
				cursorLine += 1
			}
			cursorLine += 1
			lastSection = section
		}
		cursorLine += linesPerItem
	}
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

	if cursorLine < m.scrollOffset {
		m.scrollOffset = cursorLine
	}
	if cursorLine+linesPerItem > m.scrollOffset+viewport {
		m.scrollOffset = cursorLine + linesPerItem - viewport
	}
	if m.scrollOffset < 0 {
		m.scrollOffset = 0
	}
}

// clampRightScroll prevents rightScroll from growing beyond useful range.
// The render path clamps visually, but without this the field drifts unbounded.
func (m *TeamModel) clampRightScroll() {
	// Use a generous upper bound — real content rarely exceeds 200 lines.
	// The render path will further clamp to actual content length.
	upper := 500
	if m.height > 0 {
		upper = m.height * 3
	}
	if m.rightScroll > upper {
		m.rightScroll = upper
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

// View renders the split-pane layout, or the editor overlay.
func (m TeamModel) View() string {
	if m.editor.IsActive() {
		return m.editor.View()
	}

	t := m.theme
	w := m.width
	if w < 44 {
		w = 44
	}
	h := m.height
	if h < 10 {
		h = 10
	}

	// Panel widths: ~33% left, ~67% right, minus 1 for separator
	leftW := w * 33 / 100
	if leftW < 24 {
		leftW = 24
	}
	rightW := w - leftW - 1
	if rightW < 20 {
		rightW = 20
	}

	leftPanel := m.renderLeftPanel(leftW, h)
	rightPanel := m.renderRightPanel(rightW, h)

	// Separator
	sepColor := t.Separator
	sep := lipgloss.NewStyle().
		Foreground(sepColor).
		Render(strings.Repeat("│\n", h-1) + "│")

	return lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, sep, rightPanel)
}

// --- Left panel (team list) ---

func (m TeamModel) renderLeftPanel(w, h int) string {
	t := m.theme

	// Header
	headerStyle := t.SectionHeader.Copy().Width(w).PaddingLeft(1)
	header := headerStyle.Render("TEAMS")

	borderColor := t.Separator
	if m.focused && m.leftFocused {
		borderColor = t.Primary
	}

	if len(m.entries) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).PaddingLeft(1).PaddingTop(1).
			Render("No teams found.")
		hint := ""
		if m.focused {
			hint = "\n" + lipgloss.NewStyle().
				Foreground(t.Muted).Faint(true).PaddingLeft(1).
				Render("n = new team")
		}
		content := header + "\n" + empty + hint
		return lipgloss.NewStyle().
			Width(w).Height(h).
			BorderForeground(borderColor).
			Render(content)
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
	countParts := []string{fmt.Sprintf("%d total", len(m.entries))}
	if running > 0 {
		countParts = append(countParts,
			lipgloss.NewStyle().Foreground(t.Success).Render(fmt.Sprintf("%d running", running)))
	}
	if starred > 0 {
		countParts = append(countParts,
			lipgloss.NewStyle().Foreground(t.Warning).Render(fmt.Sprintf("★%d", starred)))
	}
	countText := lipgloss.NewStyle().Foreground(t.Muted).PaddingLeft(1).
		Render(strings.Join(countParts, ", "))

	// List items with section headers
	listH := h - 4 // header + count + padding
	if listH < 1 {
		listH = 1
	}

	// Build all visible lines
	type listLine struct {
		content string
		idx     int // entry index, -1 for section headers/blanks
	}
	var allLines []listLine
	lastSection := ""
	for i, entry := range m.entries {
		section := m.sectionOf(entry)
		if section != lastSection {
			if lastSection != "" {
				allLines = append(allLines, listLine{content: "", idx: -1})
			}
			sectionLabel := lipgloss.NewStyle().
				Bold(true).Foreground(t.Muted).Faint(true).PaddingLeft(1).
				Render(section)
			allLines = append(allLines, listLine{content: sectionLabel, idx: -1})
			lastSection = section
		}

		selected := m.focused && m.leftFocused && i == m.cursor
		line := m.renderLeftItem(entry, i, w, selected)
		allLines = append(allLines, listLine{content: line, idx: i})
	}

	// Calculate scroll window
	scrollTop := m.scrollOffset
	if scrollTop > len(allLines)-1 {
		scrollTop = len(allLines) - 1
	}
	if scrollTop < 0 {
		scrollTop = 0
	}

	var items []string
	for li := scrollTop; li < len(allLines) && len(items) < listH; li++ {
		items = append(items, allLines[li].content)
	}

	body := strings.Join(items, "\n")

	// Scroll indicators
	scrollHint := ""
	if scrollTop > 0 {
		scrollHint = lipgloss.NewStyle().Foreground(t.Muted).Faint(true).PaddingLeft(1).Render("↑ more")
	}
	if scrollTop+listH < len(allLines) {
		if scrollHint != "" {
			scrollHint += "  "
		}
		scrollHint += lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("↓ more")
	}

	content := header + "\n" + countText + "\n" + body
	if scrollHint != "" {
		content += "\n" + scrollHint
	}

	return lipgloss.NewStyle().
		Width(w).Height(h).
		BorderForeground(borderColor).
		Render(content)
}

// renderLeftItem renders a single team entry as a compact list row.
func (m TeamModel) renderLeftItem(e runtime.TeamEntry, idx int, w int, selected bool) string {
	t := m.theme
	d := e.Def
	itemW := w - 4
	if itemW < 16 {
		itemW = 16
	}

	// Star indicator
	star := ""
	if e.Starred {
		star = lipgloss.NewStyle().Foreground(t.Warning).Render("★") + " "
	}

	// Status dot
	var dot string
	if e.Running {
		dot = lipgloss.NewStyle().Foreground(t.Success).Render("●")
	} else {
		dot = lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("○")
	}

	// Name
	displayName := d.Name
	if e.Label != "" {
		displayName = e.Label
	}
	maxNameW := itemW - 8 // dot + star + spacing
	if maxNameW < 4 {
		maxNameW = 4
	}
	if len(displayName) > maxNameW {
		displayName = displayName[:maxNameW-1] + "…"
	}
	nameStyle := lipgloss.NewStyle().Foreground(t.Text)
	if selected {
		nameStyle = nameStyle.Bold(true)
	}

	// Worker count
	workerInfo := lipgloss.NewStyle().Foreground(t.Muted).Render(fmt.Sprintf("%dw", d.Workers))

	line := fmt.Sprintf(" %s %s%s %s", dot, star, nameStyle.Render(displayName), workerInfo)

	rowStyle := lipgloss.NewStyle().Width(w - 2).PaddingLeft(1)
	if selected {
		rowStyle = rowStyle.
			Background(lipgloss.AdaptiveColor{Light: "#EEF2FF", Dark: "#1E293B"}).
			Foreground(t.Text)
	}

	rendered := rowStyle.Render(line)
	return zone.Mark(fmt.Sprintf("team-%d", idx), rendered)
}

// --- Right panel (detail) ---

func (m TeamModel) renderRightPanel(w, h int) string {
	t := m.theme

	borderColor := t.Separator
	if m.focused && !m.leftFocused {
		borderColor = t.Primary
	}

	if len(m.entries) == 0 || m.cursor < 0 || m.cursor >= len(m.entries) {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			Padding(2, 3).
			Width(w).
			Height(h).
			Render("No team selected")
		return empty
	}

	entry := m.entries[m.cursor]
	d := entry.Def

	// Build detail content sections
	var sections []string

	// Title with status
	displayName := d.Name
	if entry.Label != "" {
		displayName = entry.Label
	}
	var statusDotStr string
	if entry.Running {
		statusDotStr = lipgloss.NewStyle().Foreground(t.Success).Render("●")
	} else {
		statusDotStr = lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("○")
	}
	title := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(displayName)
	sections = append(sections, statusDotStr+" "+title)
	sections = append(sections, "")

	// Detail fields
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Width(14)
	valueStyle := lipgloss.NewStyle().Foreground(t.Text)

	// Status
	statusStr := lipgloss.NewStyle().Foreground(t.Muted).Render("Available")
	if entry.Running {
		statusStr = lipgloss.NewStyle().Foreground(t.Success).Render("Running")
	}
	sections = append(sections, labelStyle.Render("Status")+"  "+statusStr)

	// Type
	if d.Type != "" {
		sections = append(sections, labelStyle.Render("Type")+"  "+valueStyle.Render(d.Type))
	}

	// Workers
	sections = append(sections, labelStyle.Render("Workers")+"  "+
		lipgloss.NewStyle().Foreground(t.Success).Render(fmt.Sprintf("%d", d.Workers)))

	// Flags
	flagParts := []string{}
	if entry.Starred {
		flagParts = append(flagParts, lipgloss.NewStyle().Foreground(t.Warning).Render("★ Starred"))
	}
	if entry.Startup {
		flagParts = append(flagParts, lipgloss.NewStyle().Foreground(t.Primary).Render("Auto-launch"))
	}
	if len(flagParts) > 0 {
		sections = append(sections, labelStyle.Render("Flags")+"  "+strings.Join(flagParts, "  "))
	}

	// Description
	if d.Description != "" {
		descWidth := w - 22
		if descWidth < 20 {
			descWidth = 20
		}
		desc := d.Description
		if len(desc) > descWidth {
			desc = desc[:descWidth-1] + "…"
		}
		sections = append(sections, labelStyle.Render("Description")+"  "+
			lipgloss.NewStyle().Foreground(t.Muted).Render(desc))
	}

	// Grid / Models
	if d.Grid != "" {
		sections = append(sections, labelStyle.Render("Grid")+"  "+valueStyle.Render(d.Grid))
	}
	if d.ManagerModel != "" {
		sections = append(sections, labelStyle.Render("Manager Model")+"  "+valueStyle.Render(d.ManagerModel))
	}
	if d.WorkerModel != "" {
		sections = append(sections, labelStyle.Render("Worker Model")+"  "+valueStyle.Render(d.WorkerModel))
	}

	// Panes roster
	if len(d.Panes) > 0 {
		sections = append(sections, "")
		sections = append(sections, t.SectionHeader.Copy().Render("PANE ROSTER"))
		for _, p := range d.Panes {
			role := lipgloss.NewStyle().Foreground(t.Primary).Render(p.Role)
			name := ""
			if p.Name != "" {
				name = " " + lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("("+p.Name+")")
			}
			agent := ""
			if p.Agent != "" {
				agent = " " + lipgloss.NewStyle().Foreground(t.Accent).Render("→ "+p.Agent)
			}
			model := ""
			if p.Model != "" {
				model = " " + lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("["+p.Model+"]")
			}
			sections = append(sections, fmt.Sprintf("  %d. %s%s%s%s", p.Index, role, name, agent, model))
		}
	}

	// Workflows
	if len(d.Workflows) > 0 {
		sections = append(sections, "")
		sections = append(sections, t.SectionHeader.Copy().Render("WORKFLOWS"))
		for _, wf := range d.Workflows {
			trigger := lipgloss.NewStyle().Foreground(t.Warning).Render(wf.Trigger)
			from := valueStyle.Render(wf.From)
			to := lipgloss.NewStyle().Foreground(t.Success).Render(wf.To)
			subject := ""
			if wf.Subject != "" {
				subject = " " + lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("re: "+wf.Subject)
			}
			sections = append(sections, fmt.Sprintf("  %s: %s → %s%s", trigger, from, to, subject))
		}
	}

	// Worker status (when running)
	if entry.Running {
		sections = append(sections, "")
		workerPanel := m.renderWorkerPanel(entry, w-8)
		sections = append(sections, workerPanel)
	}

	// Briefing excerpt
	if d.Briefing != "" {
		sections = append(sections, "")
		sections = append(sections, t.SectionHeader.Copy().Render("BRIEFING"))
		briefWidth := w - 10
		if briefWidth < 20 {
			briefWidth = 20
		}
		briefing := d.Briefing
		if len(briefing) > 500 {
			briefing = briefing[:497] + "..."
		}
		sections = append(sections, "  "+lipgloss.NewStyle().Foreground(t.Text).Width(briefWidth).Render(briefing))
	}

	// File path
	if d.FilePath != "" {
		sections = append(sections, "")
		sections = append(sections, labelStyle.Render("File")+"  "+
			lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render(d.FilePath))
	}

	// Action buttons
	sections = append(sections, "")
	sections = append(sections, m.renderRightActions(entry))

	// Nav hint
	sections = append(sections, "")
	if m.focused {
		hint := "← back to list"
		if m.leftFocused {
			hint = "→ or enter for details"
		}
		sections = append(sections, lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render(hint))
	}

	// Dispatch bar
	if m.dispatching {
		sections = append(sections, "")
		sections = append(sections, m.renderDispatchBar())
	}

	fullContent := strings.Join(sections, "\n")

	// Apply scroll
	lines := strings.Split(fullContent, "\n")
	viewport := h - 2 // padding
	if viewport < 1 {
		viewport = 1
	}

	maxScroll := len(lines) - viewport
	if maxScroll < 0 {
		maxScroll = 0
	}
	scrollOff := m.rightScroll
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

// renderRightActions renders action hints/buttons for the right panel.
func (m TeamModel) renderRightActions(entry runtime.TeamEntry) string {
	t := m.theme
	var parts []string

	starLabel := "s = star"
	if entry.Starred {
		starLabel = "s = unstar"
	}
	parts = append(parts, zone.Mark("team-star", lipgloss.NewStyle().Foreground(t.Warning).Render(starLabel)))
	parts = append(parts, lipgloss.NewStyle().Foreground(t.Muted).Render("a = startup"))
	parts = append(parts, lipgloss.NewStyle().Foreground(t.Muted).Render("e = edit"))

	if entry.Running {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Primary).Render("d = dispatch"))
		parts = append(parts, zone.Mark("team-stop", lipgloss.NewStyle().Foreground(t.Danger).Render("x = stop")))
	} else {
		parts = append(parts, zone.Mark("team-launch", lipgloss.NewStyle().Foreground(t.Success).Render("enter = launch")))
	}

	return strings.Join(parts, "  ")
}

// --- Shared rendering helpers ---

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

// renderWorkerPanel renders running worker statuses for a team.
func (m TeamModel) renderWorkerPanel(entry runtime.TeamEntry, w int) string {
	t := m.theme

	if !entry.Running {
		return lipgloss.NewStyle().Foreground(t.Muted).
			Render("Not running — press Enter to launch")
	}

	tc, ok := m.teams[entry.WindowIdx]
	if !ok {
		return lipgloss.NewStyle().Foreground(t.Muted).
			Render("No runtime data available")
	}

	var lines []string
	lines = append(lines, t.SectionHeader.Copy().Render("WORKER STATUS"))

	// Manager
	if tc.ManagerPane != "" {
		lines = append(lines, m.renderPaneStatus(entry.WindowIdx, tc.ManagerPane, "Manager", w))
	}

	// Workers
	for i, pi := range tc.WorkerPanes {
		workerLine := m.renderPaneStatus(entry.WindowIdx, fmt.Sprintf("%d", pi), "Worker", w)
		lines = append(lines, zone.Mark(fmt.Sprintf("team-worker-%d", i), workerLine))
	}

	return strings.Join(lines, "\n")
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

	statusColor := styles.StatusColor(status)
	dot := lipgloss.NewStyle().Foreground(statusColor).Render("●")
	roleStr := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Text).Width(10).Render(role)
	statusStr := lipgloss.NewStyle().Foreground(statusColor).Width(10).Render(status)

	taskStr := ""
	if task != "" {
		maxTask := maxW - 30
		if maxTask < 10 {
			maxTask = 10
		}
		if len(task) > maxTask {
			task = task[:maxTask-1] + "…"
		}
		taskStr = lipgloss.NewStyle().Foreground(m.theme.Muted).Faint(true).Render(task)
	}

	return fmt.Sprintf("  %s %s %s %s", dot, roleStr, statusStr, taskStr)
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

// renderDispatchBar renders the inline text input for dispatching a task.
func (m TeamModel) renderDispatchBar() string {
	t := m.theme
	prompt := lipgloss.NewStyle().Bold(true).Foreground(t.Primary).
		Render("Dispatch to W" + strconv.Itoa(m.dispatchTarget) + ": ")
	input := lipgloss.NewStyle().Foreground(t.Text).
		Render(m.dispatchInput + "█")
	return prompt + input
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
