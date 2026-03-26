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

// CatalogModel displays premade team definitions in summary or detail mode.
type CatalogModel struct {
	// Data
	teamDefs []runtime.TeamDef
	theme    styles.Theme

	// Navigation
	summaryMode bool // true = list view, false = detail view
	cursor      int  // selected row in summary mode
	selectedIdx int  // index into teamDefs for detail mode

	// Layout
	width   int
	height  int
	focused bool
	keyMap  keys.KeyMap
}

// NewCatalogModel creates a catalog panel starting in summary mode.
func NewCatalogModel(theme styles.Theme) CatalogModel {
	return CatalogModel{
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
	switch {
	case key.Matches(msg, m.keyMap.Up):
		if len(m.teamDefs) > 0 {
			m.cursor--
			if m.cursor < 0 {
				m.cursor = len(m.teamDefs) - 1
			}
		}
	case key.Matches(msg, m.keyMap.Down):
		if len(m.teamDefs) > 0 {
			m.cursor++
			if m.cursor >= len(m.teamDefs) {
				m.cursor = 0
			}
		}
	case key.Matches(msg, m.keyMap.Select):
		if len(m.teamDefs) > 0 && m.cursor < len(m.teamDefs) {
			m.selectedIdx = m.cursor
			m.summaryMode = false
		}
	}
	return m, nil
}

func (m CatalogModel) updateDetail(msg tea.KeyMsg) (CatalogModel, tea.Cmd) {
	if key.Matches(msg, m.keyMap.Back) {
		m.summaryMode = true
		return m, nil
	}
	return m, nil
}

// SetSnapshot updates team defs from the snapshot.
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

// viewSummary renders one entry per team definition.
func (m CatalogModel) viewSummary() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	// Section header
	header := t.SectionHeader.Copy().PaddingLeft(2).Render("PREMADE TEAMS")

	// Thin separator
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.teamDefs) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No premade teams found.")
		return header + "\n" + rule + "\n" + empty
	}

	// Summary count
	summary := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(fmt.Sprintf("%d premade teams available", len(m.teamDefs)))

	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	var lines []string
	for i, td := range m.teamDefs {
		line := m.renderTeamDefLine(td)

		if m.focused && i == m.cursor {
			line = lipgloss.NewStyle().
				Background(selectedBg).
				Width(w - 4).
				Render(line)
		}

		lines = append(lines, line)

		// Thin separator between teams (not after the last one)
		if i < len(m.teamDefs)-1 {
			lines = append(lines, styles.ThinSeparator(t, w-6))
		}
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
			Render("enter to view details")
	}

	return header + "\n" + rule + "\n" + summary + "\n\n" + body + "\n" + hint
}

// renderTeamDefLine renders a single team definition summary.
func (m CatalogModel) renderTeamDefLine(td runtime.TeamDef) string {
	t := m.theme

	// Team name (bold)
	name := t.Subtitle.Render(td.Name)

	// Type badge
	badge := typeBadge(td.Type, t)

	// Description
	desc := ""
	if td.Description != "" {
		desc = "\n  " + t.Body.Render(td.Description)
	}

	// Pane count summary
	paneCount := len(td.Panes)
	paneSummary := ""
	if paneCount > 0 {
		roles := countRoles(td.Panes)
		paneSummary = "\n  " + t.Dim.Render(fmt.Sprintf("%d panes: %s", paneCount, roles))
	} else if td.Workers > 0 {
		paneSummary = "\n  " + t.Dim.Render(fmt.Sprintf("manager + %d workers", td.Workers))
	}

	return name + "  " + badge + desc + paneSummary
}

// typeBadge returns a styled type badge.
func typeBadge(teamType string, t styles.Theme) string {
	label := "[" + teamType + "]"
	return t.Dim.Render(label)
}

// countRoles returns a summary like "manager + 3 workers + watchdog".
func countRoles(panes []runtime.TeamPaneDef) string {
	roleCounts := make(map[string]int)
	for _, p := range panes {
		role := strings.ToLower(p.Role)
		if role == "" {
			role = "worker"
		}
		roleCounts[role]++
	}

	var parts []string
	// Show manager first if present
	if n, ok := roleCounts["manager"]; ok && n > 0 {
		parts = append(parts, "manager")
		delete(roleCounts, "manager")
	}

	// Workers
	if n, ok := roleCounts["worker"]; ok && n > 0 {
		parts = append(parts, fmt.Sprintf("%d workers", n))
		delete(roleCounts, "worker")
	}

	// Watchdog
	if n, ok := roleCounts["watchdog"]; ok && n > 0 {
		parts = append(parts, "watchdog")
		delete(roleCounts, "watchdog")
	}

	// Remaining roles
	for role, n := range roleCounts {
		if n == 1 {
			parts = append(parts, role)
		} else {
			parts = append(parts, fmt.Sprintf("%d %ss", n, role))
		}
	}

	return strings.Join(parts, " + ")
}

// viewDetail renders the full info for the selected team definition.
func (m CatalogModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	if m.selectedIdx >= len(m.teamDefs) {
		return t.Dim.Render("No team selected")
	}

	td := m.teamDefs[m.selectedIdx]

	// Section header with team name
	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(td.Name)

	rule := t.Faint.Render(strings.Repeat("─", w))

	back := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc to go back")

	// Info fields
	var info []string
	if td.Description != "" {
		info = append(info, t.Body.Render(td.Description))
		info = append(info, "")
	}

	info = append(info, t.StatLabel.Render("Type: ")+t.Body.Render(td.Type))
	if td.Grid != "" {
		info = append(info, t.StatLabel.Render("Grid: ")+t.Body.Render(td.Grid))
	}
	if td.ManagerModel != "" {
		info = append(info, t.StatLabel.Render("Manager Model: ")+t.Body.Render(td.ManagerModel))
	}
	if td.WorkerModel != "" {
		info = append(info, t.StatLabel.Render("Worker Model: ")+t.Body.Render(td.WorkerModel))
	}
	if td.Workers > 0 {
		info = append(info, t.StatLabel.Render("Workers: ")+t.Body.Render(fmt.Sprintf("%d", td.Workers)))
	}

	infoBlock := lipgloss.NewStyle().PaddingLeft(3).
		Render(strings.Join(info, "\n"))

	// Pane layout table
	paneTable := ""
	if len(td.Panes) > 0 {
		paneTable = "\n\n" + m.renderPaneTable(td.Panes)
	}

	return header + "\n" + rule + "\n" + back + "\n\n" + infoBlock + paneTable
}

// renderPaneTable renders pane definitions as an aligned text table.
func (m CatalogModel) renderPaneTable(panes []runtime.TeamPaneDef) string {
	t := m.theme

	// Column widths
	const (
		colIdx   = 6
		colRole  = 12
		colAgent = 20
		colName  = 16
		colModel = 14
	)

	// Header
	hdr := t.SectionHeader.Copy().PaddingLeft(3).Render(
		pad("Idx", colIdx) +
			pad("Role", colRole) +
			pad("Agent", colAgent) +
			pad("Name", colName) +
			pad("Model", colModel),
	)

	hdrRule := lipgloss.NewStyle().PaddingLeft(3).Render(
		t.Faint.Render(strings.Repeat("─", colIdx+colRole+colAgent+colName+colModel)),
	)

	var rows []string
	for _, p := range panes {
		row := lipgloss.NewStyle().PaddingLeft(3).Render(
			t.Body.Render(
				pad(fmt.Sprintf("%d", p.Index), colIdx)+
					pad(p.Role, colRole)+
					pad(p.Agent, colAgent)+
					pad(p.Name, colName)+
					pad(p.Model, colModel),
			),
		)
		rows = append(rows, row)
	}

	return hdr + "\n" + hdrRule + "\n" + strings.Join(rows, "\n")
}

// pad right-pads a string to the given width.
func pad(s string, width int) string {
	if len(s) >= width {
		return s[:width-1] + " "
	}
	return s + strings.Repeat(" ", width-len(s))
}
