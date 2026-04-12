package model

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// domainOrder defines the display ordering for agent domains.
var domainOrder = []string{
	"Doey Infrastructure",
	"SEO",
	"Visual QA",
	"Utility",
}

// agentGroup holds agents grouped under a domain header.
type agentGroup struct {
	domain string
	agents []runtime.AgentDef
}

// AgentsModel displays agent definitions grouped by domain in a split-panel layout.
type AgentsModel struct {
	// Data
	groups []agentGroup
	flat   []int // flat index → group index for cursor mapping
	agents []runtime.AgentDef
	theme  styles.Theme

	// Navigation
	cursor      int
	keyMap      keys.KeyMap
	leftFocused bool
	rightScroll int

	// Layout
	width            int
	height           int
	focused          bool
	scrollOffset     int
	collapsedDomains map[string]bool

	// Glamour rendering cache
	mdCache string
	mdBody  string
	mdWidth int
}

// NewAgentsModel creates an agents panel with the left list focused.
func NewAgentsModel(theme styles.Theme) AgentsModel {
	return AgentsModel{
		theme:            theme,
		leftFocused:      true,
		keyMap:           keys.DefaultKeyMap(),
		collapsedDomains: make(map[string]bool),
	}
}

// Init is a no-op for the agents sub-model.
func (m AgentsModel) Init() tea.Cmd {
	return nil
}

// Update handles navigation in the split-panel layout.
func (m AgentsModel) Update(msg tea.Msg) (AgentsModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.MouseMsg:
		return m.updateMouse(msg)
	case tea.KeyMsg:
		return m.updateKey(msg)
	}

	return m, nil
}

// updateMouse handles all mouse interactions for the agents panel.
func (m AgentsModel) updateMouse(msg tea.MouseMsg) (AgentsModel, tea.Cmd) {
	// Panel split point for position-based routing
	leftW := m.width * 33 / 100
	if leftW < 24 {
		leftW = 24
	}

	// Click release — check interactive zones
	if msg.Action == tea.MouseActionRelease {
		// Domain headers — toggle collapse
		for i, g := range m.groups {
			if zone.Get(fmt.Sprintf("agent-domain-%d", i)).InBounds(msg) {
				m.collapsedDomains[g.domain] = !m.collapsedDomains[g.domain]
				return m, nil
			}
		}

		// Agent entries — click to select
		flatIdx := 0
		for _, g := range m.groups {
			if m.collapsedDomains[g.domain] {
				flatIdx += len(g.agents)
				continue
			}
			for range g.agents {
				if zone.Get(fmt.Sprintf("agent-%d", flatIdx)).InBounds(msg) {
					m.cursor = flatIdx
					m.leftFocused = true
					m.rightScroll = 0
					return m, nil
				}
				flatIdx++
			}
		}

		// Click on right panel — focus detail pane
		if msg.X > leftW && len(m.agents) > 0 {
			m.leftFocused = false
			return m, nil
		}
	}

	// Mouse wheel — route based on mouse position, not keyboard focus
	if msg.Action == tea.MouseActionPress {
		mouseOnRight := msg.X > leftW

		if msg.Button == tea.MouseButtonWheelUp {
			if mouseOnRight {
				if m.rightScroll > 0 {
					m.rightScroll--
				}
			} else {
				if m.cursor > 0 {
					m.cursor--
					m.rightScroll = 0
				}
			}
			return m, nil
		}
		if msg.Button == tea.MouseButtonWheelDown {
			if mouseOnRight {
				if ms := m.maxRightScroll(); m.rightScroll < ms {
					m.rightScroll++
				}
			} else {
				if m.cursor < len(m.agents)-1 {
					m.cursor++
					m.rightScroll = 0
				}
			}
			return m, nil
		}
	}

	return m, nil
}

// updateKey handles keyboard navigation for both panels.
func (m AgentsModel) updateKey(msg tea.KeyMsg) (AgentsModel, tea.Cmd) {
	total := len(m.agents)

	switch {
	// Focus right panel
	case key.Matches(msg, m.keyMap.RightPanel) || (m.leftFocused && key.Matches(msg, m.keyMap.Select)):
		if m.leftFocused && total > 0 {
			m.leftFocused = false
			m.rightScroll = 0
		}
		return m, nil

	// Focus left panel
	case key.Matches(msg, m.keyMap.LeftPanel) || key.Matches(msg, m.keyMap.Back):
		if !m.leftFocused {
			m.leftFocused = true
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
				m.rightScroll = 0
			}
		} else {
			if ms := m.maxRightScroll(); m.rightScroll < ms {
				m.rightScroll++
			}
		}
		return m, nil
	}

	return m, nil
}

// SetSnapshot updates agent list from fresh snapshot. Preserves the
// user's selection across refreshes by matching on agent Name — only
// resets the cursor when the previously selected agent is gone (or on
// first load).
func (m *AgentsModel) SetSnapshot(snap runtime.Snapshot) {
	var selectedName string
	if prev, ok := m.selectedAgent(); ok {
		selectedName = prev.Name
	}

	m.agents = snap.AgentDefs
	m.rebuildGroups()

	if selectedName == "" {
		m.cursor = 0
		m.scrollOffset = 0
		m.rightScroll = 0
		return
	}

	// Re-seek cursor to the previously selected agent in the new flat order.
	found := false
	idx := 0
	for _, g := range m.groups {
		for _, a := range g.agents {
			if a.Name == selectedName {
				m.cursor = idx
				found = true
				break
			}
			idx++
		}
		if found {
			break
		}
	}
	if !found {
		m.cursor = 0
		m.scrollOffset = 0
		m.rightScroll = 0
	}
}

// rebuildGroups organizes agents into domain groups.
func (m *AgentsModel) rebuildGroups() {
	// Index agents by domain
	byDomain := make(map[string][]runtime.AgentDef)
	for _, a := range m.agents {
		d := a.Domain
		if d == "" {
			d = "Utility"
		}
		byDomain[d] = append(byDomain[d], a)
	}

	m.groups = nil
	m.flat = nil

	for _, domain := range domainOrder {
		agents, ok := byDomain[domain]
		if !ok || len(agents) == 0 {
			continue
		}
		groupIdx := len(m.groups)
		m.groups = append(m.groups, agentGroup{domain: domain, agents: agents})
		for range agents {
			m.flat = append(m.flat, groupIdx)
		}
	}

	// Catch any domains not in domainOrder
	for domain, agents := range byDomain {
		found := false
		for _, d := range domainOrder {
			if d == domain {
				found = true
				break
			}
		}
		if found {
			continue
		}
		groupIdx := len(m.groups)
		m.groups = append(m.groups, agentGroup{domain: domain, agents: agents})
		for range agents {
			m.flat = append(m.flat, groupIdx)
		}
	}
}

// SetSize updates the panel dimensions.
func (m *AgentsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetFocused toggles focus state.
func (m *AgentsModel) SetFocused(focused bool) {
	m.focused = focused
}

// View renders the split-panel layout.
func (m AgentsModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}
	h := m.height
	if h < 10 {
		h = 10
	}

	// Panel widths: ~33% left, ~67% right, minus separator
	leftW := w * 33 / 100
	if leftW < 24 {
		leftW = 24
	}
	rightW := w - leftW - 1 // 1 for separator
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

// selectedAgent returns the agent at the current cursor position, if any.
func (m AgentsModel) selectedAgent() (runtime.AgentDef, bool) {
	idx := 0
	for _, g := range m.groups {
		for _, a := range g.agents {
			if idx == m.cursor {
				return a, true
			}
			idx++
		}
	}
	return runtime.AgentDef{}, false
}

// renderLeftPanel renders the domain-grouped agent list.
func (m AgentsModel) renderLeftPanel(w, h int) string {
	t := m.theme

	// Header
	headerStyle := t.SectionHeader.Copy().Width(w).PaddingLeft(1)
	header := headerStyle.Render("AGENTS")

	borderColor := t.Separator
	if m.focused && m.leftFocused {
		borderColor = t.Primary
	}
	_ = borderColor // used conceptually for focus indication

	if len(m.agents) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(1).
			Render("No agents found.")
		content := header + "\n" + empty
		return lipgloss.NewStyle().Width(w).Height(h).Render(content)
	}

	// Count
	countText := lipgloss.NewStyle().Foreground(t.Muted).PaddingLeft(1).
		Render(fmt.Sprintf("%d agents, %d domains", len(m.agents), len(m.groups)))

	// List items
	listH := h - 4 // header + count + padding
	if listH < 1 {
		listH = 1
	}

	// Build flat list of renderable items (domain headers + agent rows)
	type listItem struct {
		rendered string
		isAgent  bool
		flatIdx  int
	}
	var allItems []listItem

	flatIdx := 0
	for gi, g := range m.groups {
		// Domain header
		collapsed := m.collapsedDomains[g.domain]
		arrow := "↳"
		if collapsed {
			arrow = "›"
		}
		domainLabel := fmt.Sprintf("%s %s (%d)", arrow, g.domain, len(g.agents))
		domainHeader := lipgloss.NewStyle().
			Foreground(t.Text).
			Bold(true).
			PaddingLeft(1).
			Width(w - 2).
			Render(domainLabel)
		allItems = append(allItems, listItem{
			rendered: zone.Mark(fmt.Sprintf("agent-domain-%d", gi), domainHeader),
		})

		if collapsed {
			flatIdx += len(g.agents)
			continue
		}

		for _, a := range g.agents {
			selected := m.focused && m.leftFocused && flatIdx == m.cursor

			// Agent row: colored dot + name
			var dotColor lipgloss.TerminalColor = lipgloss.Color(a.Color)
			if a.Color == "" {
				dotColor = t.Muted
			}
			dot := lipgloss.NewStyle().Foreground(dotColor).Render("◆")
			nameStyle := lipgloss.NewStyle().Foreground(t.Text)
			if selected {
				nameStyle = nameStyle.Bold(true)
			}

			name := a.Name
			maxNameW := w - 8
			if maxNameW < 4 {
				maxNameW = 4
			}
			if len(name) > maxNameW {
				name = name[:maxNameW-1] + "…"
			}

			line := fmt.Sprintf(" %s %s", dot, nameStyle.Render(name))

			rowStyle := lipgloss.NewStyle().Width(w - 2).PaddingLeft(1)
			if selected {
				rowStyle = rowStyle.
					Background(lipgloss.AdaptiveColor{Light: "#EEF2FF", Dark: "#1E293B"}).
					Foreground(t.Text)
			}

			rendered := rowStyle.Render(line)
			allItems = append(allItems, listItem{
				rendered: zone.Mark(fmt.Sprintf("agent-%d", flatIdx), rendered),
				isAgent:  true,
				flatIdx:  flatIdx,
			})
			flatIdx++
		}
	}

	// Calculate scroll window to keep cursor visible
	cursorItemIdx := 0
	for i, item := range allItems {
		if item.isAgent && item.flatIdx == m.cursor {
			cursorItemIdx = i
			break
		}
	}

	scrollTop := m.scrollOffset
	if cursorItemIdx < scrollTop {
		scrollTop = cursorItemIdx
	}
	if cursorItemIdx >= scrollTop+listH {
		scrollTop = cursorItemIdx - listH + 1
	}
	if scrollTop < 0 {
		scrollTop = 0
	}

	var items []string
	for i, item := range allItems {
		if i < scrollTop {
			continue
		}
		if len(items) >= listH {
			break
		}
		items = append(items, item.rendered)
	}

	body := strings.Join(items, "\n")

	// Scroll indicators
	scrollHint := ""
	if scrollTop > 0 {
		scrollHint = lipgloss.NewStyle().Foreground(t.Muted).Faint(true).PaddingLeft(1).Render("› above")
	}
	if scrollTop+listH < len(allItems) {
		if scrollHint != "" {
			scrollHint += "  "
		}
		scrollHint += lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("› below")
	}

	content := header + "\n" + countText + "\n" + body
	if scrollHint != "" {
		content += "\n" + scrollHint
	}

	return lipgloss.NewStyle().
		Width(w).
		Height(h).
		Render(content)
}

// renderDetailContent returns the detail body for the selected agent.
func (m AgentsModel) renderDetailContent(w int) string {
	t := m.theme

	agent, ok := m.selectedAgent()
	if !ok {
		return ""
	}

	labelStyle := t.StatLabel.Copy().Width(14)
	valueStyle := t.Body
	ruleStyle := lipgloss.NewStyle().Foreground(t.Muted).Faint(true)

	ruleW := w - 4
	if ruleW < 10 {
		ruleW = 10
	}
	rule := ruleStyle.Render(strings.Repeat("─", ruleW))

	var sections []string

	// Group 1: Identity — model + domain
	sections = append(sections, labelStyle.Render("Model")+"  "+valueStyle.Render(agent.Model))
	sections = append(sections, labelStyle.Render("Domain")+"  "+valueStyle.Render(agent.Domain))

	// Group 2: Appearance — color + memory
	var group2 []string
	if agent.Color != "" {
		colorDot := lipgloss.NewStyle().Foreground(lipgloss.Color(agent.Color)).Render("◆")
		group2 = append(group2, labelStyle.Render("Color")+"  "+colorDot+" "+t.Dim.Render(agent.Color))
	}
	if agent.Memory != "" {
		group2 = append(group2, labelStyle.Render("Memory")+"  "+valueStyle.Render(agent.Memory))
	}
	if len(group2) > 0 {
		sections = append(sections, "")
		sections = append(sections, strings.Join(group2, "\n"))
	}

	// Group 3: Description (with breathing room)
	if agent.Description != "" {
		descWidth := w - 24
		if descWidth < 20 {
			descWidth = 20
		}
		sections = append(sections, "")
		sections = append(sections, labelStyle.Render("Description"))
		sections = append(sections, lipgloss.NewStyle().Foreground(t.Text).Width(descWidth).PaddingLeft(2).Render(agent.Description))
		sections = append(sections, "")
	}

	// Group 4: References — teams + file path (dimmed)
	var group4 []string
	if len(agent.UsedByTeams) > 0 {
		teams := strings.Join(agent.UsedByTeams, ", ")
		group4 = append(group4, labelStyle.Render("Used by")+"  "+valueStyle.Render(teams))
	}
	if agent.FilePath != "" {
		group4 = append(group4, labelStyle.Render("File")+"  "+ruleStyle.Render(agent.FilePath))
	}
	if len(group4) > 0 {
		sections = append(sections, rule)
		sections = append(sections, strings.Join(group4, "\n"))
	}

	return strings.Join(sections, "\n")
}

// maxRightScroll returns the maximum valid rightScroll value for the current state.
func (m AgentsModel) maxRightScroll() int {
	h := m.height
	if h < 10 {
		h = 10
	}
	w := m.width
	if w < 40 {
		w = 40
	}
	leftW := w * 33 / 100
	if leftW < 24 {
		leftW = 24
	}
	rightW := w - leftW - 1
	if rightW < 20 {
		rightW = 20
	}

	agent, ok := m.selectedAgent()
	if !ok {
		return 0
	}

	// Replicate the section-building logic from renderRightPanel
	ruleStyle := lipgloss.NewStyle().Foreground(m.theme.Muted).Faint(true)
	ruleW := rightW - 6
	if ruleW < 10 {
		ruleW = 10
	}

	var sections []string
	var dotColor lipgloss.TerminalColor = lipgloss.Color(agent.Color)
	if agent.Color == "" {
		dotColor = m.theme.Muted
	}
	dot := lipgloss.NewStyle().Foreground(dotColor).Render("◆")
	title := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Text).Render(agent.Name)
	sections = append(sections, dot+" "+title)
	if agent.Model != "" {
		sections = append(sections, lipgloss.NewStyle().
			Foreground(m.theme.BgText).Background(m.theme.Accent).Padding(0, 1).
			Render(agent.Model))
	}
	sections = append(sections, ruleStyle.Render(strings.Repeat("─", ruleW)))
	sections = append(sections, "")
	detailContent := m.renderDetailContent(rightW)
	if detailContent != "" {
		sections = append(sections, detailContent)
	}
	if agent.Body != "" {
		sections = append(sections, "")
		sections = append(sections, ruleStyle.Render(strings.Repeat("─", ruleW)))
		sections = append(sections, lipgloss.NewStyle().Bold(true).Foreground(m.theme.Text).Render("Agent Instructions"))
		// Render markdown for accurate scroll bounds
		renderer, err := glamour.NewTermRenderer(
			glamour.WithAutoStyle(),
			glamour.WithWordWrap(rightW-4),
		)
		if err == nil {
			if rendered, rerr := renderer.Render(agent.Body); rerr == nil {
				sections = append(sections, rendered)
			} else {
				sections = append(sections, "\n"+agent.Body)
			}
		} else {
			sections = append(sections, "\n"+agent.Body)
		}
	}
	// Nav hint
	sections = append(sections, "")
	if m.focused {
		hint := "↳ back to list"
		if m.leftFocused {
			hint = "→ or enter for details"
		}
		sections = append(sections, ruleStyle.Render(hint))
	}

	lines := strings.Split(strings.Join(sections, "\n"), "\n")
	viewport := h - 2
	if viewport < 1 {
		viewport = 1
	}
	maxScroll := len(lines) - viewport
	if maxScroll < 0 {
		maxScroll = 0
	}
	return maxScroll
}

// renderMarkdown renders a markdown body with glamour, caching the result.
func (m *AgentsModel) renderMarkdown(body string, width int) string {
	if width < 20 {
		width = 20
	}

	if body == m.mdBody && width == m.mdWidth && m.mdCache != "" {
		return m.mdCache
	}

	renderer, err := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(width),
	)
	if err != nil {
		m.mdCache = "\n" + body
		m.mdBody = body
		m.mdWidth = width
		return m.mdCache
	}

	rendered, err := renderer.Render(body)
	if err != nil {
		m.mdCache = "\n" + body
		m.mdBody = body
		m.mdWidth = width
		return m.mdCache
	}

	m.mdCache = rendered
	m.mdBody = body
	m.mdWidth = width
	return rendered
}

// renderRightPanel renders the detail pane for the selected agent.
func (m AgentsModel) renderRightPanel(w, h int) string {
	t := m.theme

	borderColor := t.Separator
	if m.focused && !m.leftFocused {
		borderColor = t.Primary
	}

	if len(m.agents) == 0 || m.cursor < 0 || m.cursor >= len(m.agents) {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			Padding(2, 3).
			Width(w).
			Height(h).
			Render("No agent selected")
		return empty
	}

	agent, ok := m.selectedAgent()
	if !ok {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			Padding(2, 3).
			Width(w).
			Height(h).
			Render("No agent selected")
		return empty
	}

	// Build detail content
	var sections []string

	ruleStyle := lipgloss.NewStyle().Foreground(t.Muted).Faint(true)
	ruleW := w - 6
	if ruleW < 10 {
		ruleW = 10
	}

	// Title
	var dotColor lipgloss.TerminalColor = lipgloss.Color(agent.Color)
	if agent.Color == "" {
		dotColor = t.Muted
	}
	dot := lipgloss.NewStyle().Foreground(dotColor).Render("◆")
	title := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(agent.Name)
	sections = append(sections, dot+" "+title)

	// Model badge
	if agent.Model != "" {
		modelBadge := lipgloss.NewStyle().
			Foreground(t.BgText).
			Background(t.Accent).
			Padding(0, 1).
			Render(agent.Model)
		sections = append(sections, modelBadge)
	}

	// Separator between title and detail fields
	sections = append(sections, ruleStyle.Render(strings.Repeat("─", ruleW)))
	sections = append(sections, "")

	// Detail fields
	detailContent := m.renderDetailContent(w)
	if detailContent != "" {
		sections = append(sections, detailContent)
	}

	// Markdown body (agent instructions)
	if agent.Body != "" {
		sections = append(sections, "")
		sections = append(sections, ruleStyle.Render(strings.Repeat("─", ruleW)))
		sections = append(sections, lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render("Agent Instructions"))
		sections = append(sections, m.renderMarkdown(agent.Body, w-4))
	}

	// Nav hint
	sections = append(sections, "")
	if m.focused {
		hint := "↳ back to list"
		if m.leftFocused {
			hint = "→ or enter for details"
		}
		sections = append(sections, ruleStyle.Render(hint))
	}

	fullContent := strings.Join(sections, "\n")

	// Apply scroll
	lines := strings.Split(fullContent, "\n")
	viewport := h - 2 // padding
	if viewport < 1 {
		viewport = 1
	}

	// Clamp right scroll
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
