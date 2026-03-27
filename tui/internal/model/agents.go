package model

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
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

// AgentsModel displays agent definitions grouped by domain.
type AgentsModel struct {
	// Data
	groups []agentGroup
	flat   []int // flat index → group index for cursor mapping
	agents []runtime.AgentDef
	theme  styles.Theme

	// Navigation
	summaryMode bool
	cursor      int
	keyMap      keys.KeyMap

	// Layout
	width   int
	height  int
	focused bool
}

// NewAgentsModel creates an agents panel starting in summary mode.
func NewAgentsModel(theme styles.Theme) AgentsModel {
	return AgentsModel{
		theme:       theme,
		summaryMode: true,
		keyMap:      keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the agents sub-model.
func (m AgentsModel) Init() tea.Cmd {
	return nil
}

// Update handles navigation in both modes.
func (m AgentsModel) Update(msg tea.Msg) (AgentsModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	if msg, ok := msg.(tea.KeyMsg); ok {
		if m.summaryMode {
			return m.updateSummary(msg)
		}
		return m.updateDetail(msg)
	}

	return m, nil
}

func (m AgentsModel) updateSummary(msg tea.KeyMsg) (AgentsModel, tea.Cmd) {
	total := len(m.agents)
	if total == 0 {
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
	}
	return m, nil
}

func (m AgentsModel) updateDetail(msg tea.KeyMsg) (AgentsModel, tea.Cmd) {
	if key.Matches(msg, m.keyMap.Back) {
		m.summaryMode = true
		return m, nil
	}
	return m, nil
}

// SetSnapshot updates agent list from fresh snapshot.
func (m *AgentsModel) SetSnapshot(snap runtime.Snapshot) {
	m.agents = snap.AgentDefs
	m.rebuildGroups()

	// Clamp cursor
	if m.cursor >= len(m.agents) {
		m.cursor = max(0, len(m.agents)-1)
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

// View renders summary or detail mode.
func (m AgentsModel) View() string {
	if m.summaryMode {
		return m.viewSummary()
	}
	return m.viewDetail()
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

// viewSummary renders agents grouped by domain.
func (m AgentsModel) viewSummary() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	// Section header
	header := t.SectionHeader.Copy().PaddingLeft(2).Render("AGENTS")

	// Thin separator
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.agents) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No agents found. Agent definitions will appear when loaded.")
		return header + "\n" + rule + "\n" + empty
	}

	// Summary line
	summary := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(fmt.Sprintf("%d agents across %d domains", len(m.agents), len(m.groups)))

	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	var lines []string
	flatIdx := 0
	for _, g := range m.groups {
		// Domain header
		domainHeader := t.SectionHeader.Copy().PaddingLeft(1).
			Render(fmt.Sprintf("%s (%d)", strings.ToUpper(g.domain), len(g.agents)))
		lines = append(lines, "", domainHeader)

		for _, a := range g.agents {
			// Colored dot
			dot := lipgloss.NewStyle().Foreground(lipgloss.Color(a.Color)).Render("●")

			// Agent name
			name := t.Body.Render(a.Name)

			// Description (truncated)
			desc := ""
			if a.Description != "" {
				maxDesc := w - lipgloss.Width(dot) - lipgloss.Width(name) - 8
				if maxDesc < 10 {
					maxDesc = 10
				}
				d := a.Description
				if len(d) > maxDesc {
					d = d[:maxDesc-1] + "…"
				}
				desc = t.Dim.Render(" — " + d)
			}

			line := "  " + dot + " " + name + desc

			if m.focused && flatIdx == m.cursor {
				line = lipgloss.NewStyle().
					Background(selectedBg).
					Width(w - 4).
					Render(line)
			}

			lines = append(lines, line)
			flatIdx++
		}
	}

	body := lipgloss.NewStyle().
		Padding(0, 2).
		Render(strings.Join(lines, "\n"))

	hint := ""
	if m.focused && len(m.agents) > 0 {
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Padding(1, 3).
			Render("enter to view details")
	}

	return header + "\n" + rule + "\n" + summary + "\n" + body + "\n" + hint
}

// viewDetail renders full info for the selected agent.
func (m AgentsModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	agent, ok := m.selectedAgent()
	if !ok {
		m.summaryMode = true
		return m.viewSummary()
	}

	// Header with agent name
	dot := lipgloss.NewStyle().Foreground(lipgloss.Color(agent.Color)).Render("●")
	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(dot + " " + strings.ToUpper(agent.Name))

	rule := t.Faint.Render(strings.Repeat("─", w))

	back := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc to go back")

	// Detail fields
	labelStyle := t.StatLabel.Copy().Width(14)
	valueStyle := t.Body

	var fields []string

	fields = append(fields, labelStyle.Render("Name")+"  "+valueStyle.Render(agent.Name))
	fields = append(fields, labelStyle.Render("Model")+"  "+valueStyle.Render(agent.Model))
	fields = append(fields, labelStyle.Render("Domain")+"  "+valueStyle.Render(agent.Domain))

	if agent.Color != "" {
		colorDot := lipgloss.NewStyle().Foreground(lipgloss.Color(agent.Color)).Render("●")
		fields = append(fields, labelStyle.Render("Color")+"  "+colorDot+" "+t.Dim.Render(agent.Color))
	}

	if agent.Memory != "" {
		fields = append(fields, labelStyle.Render("Memory")+"  "+valueStyle.Render(agent.Memory))
	}

	if agent.Description != "" {
		// Wrap description to available width
		descWidth := w - 20
		if descWidth < 20 {
			descWidth = 20
		}
		desc := agent.Description
		fields = append(fields, labelStyle.Render("Description")+"  "+
			lipgloss.NewStyle().Foreground(t.Text).Width(descWidth).Render(desc))
	}

	if len(agent.UsedByTeams) > 0 {
		teams := strings.Join(agent.UsedByTeams, ", ")
		fields = append(fields, labelStyle.Render("Used by")+"  "+valueStyle.Render(teams))
	}

	if agent.FilePath != "" {
		fields = append(fields, labelStyle.Render("File")+"  "+t.Dim.Render(agent.FilePath))
	}

	body := lipgloss.NewStyle().
		Padding(1, 3).
		Render(strings.Join(fields, "\n"))

	return header + "\n" + rule + "\n" + back + "\n" + body
}
