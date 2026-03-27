package model

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/table"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// LaunchTeamMsg is emitted when the user presses Enter on a team definition.
type LaunchTeamMsg struct {
	Name string
}

// CatalogModel displays available team definitions and allows launching them.
type CatalogModel struct {
	// Data
	teamDefs []runtime.TeamDef
	theme    styles.Theme

	// Navigation
	table       table.Model
	summaryMode bool
	cursor      int
	keyMap      keys.KeyMap

	// Layout
	width   int
	height  int
	focused bool
}

// NewCatalogModel creates a catalog panel starting in summary mode.
func NewCatalogModel(theme styles.Theme) CatalogModel {
	columns := []table.Column{
		{Title: "Name", Width: 20},
		{Title: "Type", Width: 12},
		{Title: "Workers", Width: 8},
		{Title: "Model", Width: 12},
		{Title: "Description", Width: 40},
	}

	tbl := table.New(
		table.WithColumns(columns),
		table.WithRows([]table.Row{}),
		table.WithFocused(false),
		table.WithHeight(10),
	)

	s := table.DefaultStyles()
	s.Header = s.Header.
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(theme.Muted).
		BorderBottom(true).
		Bold(true).
		Foreground(theme.Primary)
	s.Selected = s.Selected.
		Foreground(theme.Text).
		Background(lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}).
		Bold(false)
	tbl.SetStyles(s)

	return CatalogModel{
		table:       tbl,
		theme:       theme,
		summaryMode: true,
		keyMap:      keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the catalog sub-model.
func (m CatalogModel) Init() tea.Cmd {
	return nil
}

// Update handles navigation in both modes.
func (m CatalogModel) Update(msg tea.Msg) (CatalogModel, tea.Cmd) {
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

func (m CatalogModel) updateSummary(msg tea.KeyMsg) (CatalogModel, tea.Cmd) {
	total := len(m.teamDefs)
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

func (m CatalogModel) updateDetail(msg tea.KeyMsg) (CatalogModel, tea.Cmd) {
	if key.Matches(msg, m.keyMap.Back) {
		m.summaryMode = true
		return m, nil
	}

	// Launch on Enter in detail mode
	if key.Matches(msg, m.keyMap.Select) {
		if m.cursor < len(m.teamDefs) {
			return m, func() tea.Msg {
				return LaunchTeamMsg{Name: m.teamDefs[m.cursor].Name}
			}
		}
	}

	return m, nil
}

// SetSnapshot updates team definitions from a fresh snapshot.
func (m *CatalogModel) SetSnapshot(snap runtime.Snapshot) {
	m.teamDefs = snap.TeamDefs

	// Clamp cursor
	if m.cursor >= len(m.teamDefs) {
		m.cursor = max(0, len(m.teamDefs)-1)
	}
}

// SetSize updates the panel dimensions.
func (m *CatalogModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.table.SetHeight(h - 6)
	m.recalcColumns()
}

// SetFocused toggles focus state.
func (m *CatalogModel) SetFocused(focused bool) {
	m.focused = focused
}

// View renders summary or detail mode.
func (m CatalogModel) View() string {
	if m.summaryMode {
		return m.viewSummary()
	}
	return m.viewDetail()
}

// selectedDef returns the team def at the current cursor position, if any.
func (m CatalogModel) selectedDef() (runtime.TeamDef, bool) {
	if m.cursor >= 0 && m.cursor < len(m.teamDefs) {
		return m.teamDefs[m.cursor], true
	}
	return runtime.TeamDef{}, false
}

// viewSummary renders the team definition list.
func (m CatalogModel) viewSummary() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	// Section header
	header := t.SectionHeader.Copy().PaddingLeft(2).Render("TEAM CATALOG")

	// Thin separator
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.teamDefs) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No team definitions found. Add .team.md files to teams/.")

		content := header + "\n" + rule + "\n" + empty
		return lipgloss.NewStyle().
			Width(w).
			Height(m.height).
			Render(content)
	}

	// Summary line
	summary := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(fmt.Sprintf("%d team definitions available", len(m.teamDefs)))

	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	var lines []string
	for i, td := range m.teamDefs {
		// Type badge
		typeBadge := ""
		if td.Type != "" {
			typeBadge = lipgloss.NewStyle().Foreground(t.Accent).Render("[" + td.Type + "]")
		}

		// Team name
		name := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(td.Name)

		// Worker count
		workers := lipgloss.NewStyle().Foreground(t.Success).
			Render(fmt.Sprintf("%dW", td.Workers))

		// Description (truncated)
		desc := ""
		if td.Description != "" {
			maxDesc := w - lipgloss.Width(name) - lipgloss.Width(workers) - 12
			if maxDesc < 10 {
				maxDesc = 10
			}
			d := td.Description
			if len(d) > maxDesc {
				d = d[:maxDesc-1] + "…"
			}
			desc = t.Dim.Render(" — " + d)
		}

		line := "  " + name + "  " + workers
		if typeBadge != "" {
			line += "  " + typeBadge
		}
		line += desc

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
	if m.focused && len(m.teamDefs) > 0 {
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Padding(1, 3).
			Render("enter to view details · ↑/↓ to navigate")
	}

	content := header + "\n" + rule + "\n" + summary + "\n\n" + body + "\n" + hint

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Render(content)
}

// viewDetail renders full info for the selected team definition.
func (m CatalogModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	td, ok := m.selectedDef()
	if !ok {
		m.summaryMode = true
		return m.viewSummary()
	}

	// Header with team name
	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(strings.ToUpper(td.Name))

	rule := t.Faint.Render(strings.Repeat("─", w))

	back := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc to go back · enter to launch")

	// Detail fields
	labelStyle := t.StatLabel.Copy().Width(14)
	valueStyle := t.Body

	var fields []string

	fields = append(fields, labelStyle.Render("Name")+"  "+valueStyle.Render(td.Name))

	if td.Description != "" {
		descWidth := w - 20
		if descWidth < 20 {
			descWidth = 20
		}
		fields = append(fields, labelStyle.Render("Description")+"  "+
			lipgloss.NewStyle().Foreground(t.Text).Width(descWidth).Render(td.Description))
	}

	if td.Type != "" {
		fields = append(fields, labelStyle.Render("Type")+"  "+valueStyle.Render(td.Type))
	}

	fields = append(fields, labelStyle.Render("Workers")+"  "+
		lipgloss.NewStyle().Foreground(t.Success).Render(fmt.Sprintf("%d", td.Workers)))

	if td.Grid != "" {
		fields = append(fields, labelStyle.Render("Grid")+"  "+valueStyle.Render(td.Grid))
	}

	if td.ManagerModel != "" {
		fields = append(fields, labelStyle.Render("Manager Model")+"  "+valueStyle.Render(td.ManagerModel))
	}

	if td.WorkerModel != "" {
		fields = append(fields, labelStyle.Render("Worker Model")+"  "+valueStyle.Render(td.WorkerModel))
	}

	// Panes section
	if len(td.Panes) > 0 {
		fields = append(fields, "")
		fields = append(fields, t.SectionHeader.Copy().Render("PANES"))
		for _, p := range td.Panes {
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

	// Workflows section
	if len(td.Workflows) > 0 {
		fields = append(fields, "")
		fields = append(fields, t.SectionHeader.Copy().Render("WORKFLOWS"))
		for _, wf := range td.Workflows {
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

	// Briefing section
	if td.Briefing != "" {
		fields = append(fields, "")
		fields = append(fields, t.SectionHeader.Copy().Render("BRIEFING"))
		briefWidth := w - 8
		if briefWidth < 20 {
			briefWidth = 20
		}
		briefing := td.Briefing
		if len(briefing) > 500 {
			briefing = briefing[:497] + "..."
		}
		fields = append(fields, "  "+lipgloss.NewStyle().Foreground(t.Text).Width(briefWidth).Render(briefing))
	}

	if td.FilePath != "" {
		fields = append(fields, "")
		fields = append(fields, labelStyle.Render("File")+"  "+t.Dim.Render(td.FilePath))
	}

	body := lipgloss.NewStyle().
		Padding(1, 3).
		Render(strings.Join(fields, "\n"))

	return header + "\n" + rule + "\n" + back + "\n" + body
}

// recalcColumns adjusts table column widths based on available width.
func (m *CatalogModel) recalcColumns() {
	w := m.width
	const (
		colType    = 12
		colWorkers = 8
		colModel   = 12
		overhead   = 12
	)
	fixedWidth := colType + colWorkers + colModel + overhead
	remaining := w - fixedWidth
	nameWidth := remaining / 3
	if nameWidth < 12 {
		nameWidth = 12
	}
	descWidth := remaining - nameWidth
	if descWidth < 10 {
		descWidth = 10
	}

	m.table.SetColumns([]table.Column{
		{Title: "Name", Width: nameWidth},
		{Title: "Type", Width: colType},
		{Title: "Workers", Width: colWorkers},
		{Title: "Model", Width: colModel},
		{Title: "Description", Width: descWidth},
	})
}
