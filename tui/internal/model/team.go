package model

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/table"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// teamSummaryLine returns a styled count like "3 teams (5 busy, 2 idle)".
func teamSummaryLine(teams map[int]runtime.TeamConfig, panes map[string]runtime.PaneStatus, t styles.Theme) string {
	totalWorkers := 0
	busy, idle, reserved := 0, 0, 0
	for w, tc := range teams {
		totalWorkers += tc.WorkerCount
		for _, pi := range tc.WorkerPanes {
			paneID := fmt.Sprintf("%d.%d", w, pi)
			if ps, ok := panes[paneID]; ok {
				switch ps.Status {
				case "BUSY", "WORKING":
					busy++
				case "RESERVED":
					reserved++
				default:
					idle++
				}
			} else {
				idle++
			}
		}
	}

	total := lipgloss.NewStyle().Bold(true).Foreground(t.Text).
		Render(fmt.Sprintf("%d teams, %d workers", len(teams), totalWorkers))

	var parts []string
	if busy > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Warning).
			Render(fmt.Sprintf("%d busy", busy)))
	}
	if idle > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Success).
			Render(fmt.Sprintf("%d idle", idle)))
	}
	if reserved > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Accent).
			Render(fmt.Sprintf("%d reserved", reserved)))
	}

	if len(parts) == 0 {
		return "  " + total
	}
	sep := lipgloss.NewStyle().Foreground(t.Muted).Render(", ")
	return "  " + total + " (" + strings.Join(parts, sep) + ")"
}

// TeamModel displays team status in summary or detail mode.
type TeamModel struct {
	// Detail-mode table
	table table.Model

	// Data
	teams    map[int]runtime.TeamConfig
	panes    map[string]runtime.PaneStatus
	contexts map[string]int
	theme    styles.Theme

	// Summary-mode state
	summaryMode  bool // true = one-line-per-team, false = per-pane table
	cursor       int  // selected row in summary mode
	selectedTeam int  // window index of team shown in detail mode
	sortedTeams  []int

	// Layout
	width        int
	height       int
	taskColWidth int
	focused      bool
	keyMap       keys.KeyMap
}

// NewTeamModel creates a team panel starting in summary mode.
func NewTeamModel() TeamModel {
	t := styles.DefaultTheme()

	columns := []table.Column{
		{Title: "Pane", Width: 6},
		{Title: "Role", Width: 10},
		{Title: "Status", Width: 10},
		{Title: "Ctx%", Width: 6},
		{Title: "Task", Width: 30},
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
		BorderForeground(t.Muted).
		BorderBottom(true).
		Bold(true).
		Foreground(t.Primary)
	s.Selected = s.Selected.
		Foreground(t.Text).
		Background(lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}).
		Bold(false)
	tbl.SetStyles(s)

	return TeamModel{
		table:       tbl,
		teams:       make(map[int]runtime.TeamConfig),
		panes:       make(map[string]runtime.PaneStatus),
		contexts:    make(map[string]int),
		theme:       t,
		summaryMode: true,
		keyMap:      keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the team sub-model.
func (m TeamModel) Init() tea.Cmd {
	return nil
}

// Update handles navigation in both modes.
func (m TeamModel) Update(msg tea.Msg) (TeamModel, tea.Cmd) {
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

func (m TeamModel) updateSummary(msg tea.KeyMsg) (TeamModel, tea.Cmd) {
	switch {
	case key.Matches(msg, m.keyMap.Up):
		if len(m.sortedTeams) > 0 {
			m.cursor--
			if m.cursor < 0 {
				m.cursor = len(m.sortedTeams) - 1
			}
		}
	case key.Matches(msg, m.keyMap.Down):
		if len(m.sortedTeams) > 0 {
			m.cursor++
			if m.cursor >= len(m.sortedTeams) {
				m.cursor = 0
			}
		}
	case key.Matches(msg, m.keyMap.Select):
		if len(m.sortedTeams) > 0 && m.cursor < len(m.sortedTeams) {
			m.selectedTeam = m.sortedTeams[m.cursor]
			m.summaryMode = false
			m.rebuildDetailTable()
			m.table.Focus()
		}
	}
	return m, nil
}

func (m TeamModel) updateDetail(msg tea.KeyMsg) (TeamModel, tea.Cmd) {
	if key.Matches(msg, m.keyMap.Back) {
		m.summaryMode = true
		m.table.Blur()
		return m, nil
	}
	var cmd tea.Cmd
	m.table, cmd = m.table.Update(msg)
	return m, cmd
}

// SetSnapshot rebuilds data from fresh snapshot.
func (m *TeamModel) SetSnapshot(snap runtime.Snapshot) {
	m.teams = snap.Teams
	m.panes = snap.Panes
	m.contexts = snap.ContextPct

	// Rebuild sorted team list
	m.sortedTeams = make([]int, 0, len(m.teams))
	for w := range m.teams {
		m.sortedTeams = append(m.sortedTeams, w)
	}
	sort.Ints(m.sortedTeams)

	// Clamp cursor
	if m.cursor >= len(m.sortedTeams) {
		m.cursor = max(0, len(m.sortedTeams)-1)
	}

	// Rebuild detail table if in detail mode
	if !m.summaryMode {
		m.rebuildDetailTable()
	}
}

// SetSize updates the panel dimensions.
func (m *TeamModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.table.SetHeight(h - 6) // title + back hint + border

	// 5-column detail table: Pane=6, Role=10, Status=12, Ctx%=6
	const (
		colPane   = 6
		colRole   = 10
		colStatus = 12
		colCtx    = 6
		overhead  = 16
	)
	fixedWidth := colPane + colRole + colStatus + colCtx + overhead
	taskWidth := w - fixedWidth
	if taskWidth < 10 {
		taskWidth = 10
	}
	m.taskColWidth = taskWidth
	m.table.SetColumns([]table.Column{
		{Title: "Pane", Width: colPane},
		{Title: "Role", Width: colRole},
		{Title: "Status", Width: colStatus},
		{Title: "Ctx%", Width: colCtx},
		{Title: "Task", Width: taskWidth},
	})
}

// SetFocused toggles focus state.
func (m *TeamModel) SetFocused(focused bool) {
	m.focused = focused
	if !m.summaryMode {
		if focused {
			m.table.Focus()
		} else {
			m.table.Blur()
		}
	}
}

// View renders summary or detail mode.
func (m TeamModel) View() string {
	if m.summaryMode {
		return m.viewSummary()
	}
	return m.viewDetail()
}

// viewSummary renders one line per team with status counts.
func (m TeamModel) viewSummary() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	// Section header — matches welcome.go pattern
	header := t.SectionHeader.Copy().PaddingLeft(2).Render("TEAMS")

	// Thin separator
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.sortedTeams) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No teams yet. Teams will appear when you launch workers.")
		return header + "\n" + rule + "\n" + empty
	}

	// Summary line
	summary := teamSummaryLine(m.teams, m.panes, t)

	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	var lines []string
	for i, wi := range m.sortedTeams {
		tc := m.teams[wi]
		line := m.renderTeamSummaryLine(wi, tc)

		if m.focused && i == m.cursor {
			line = lipgloss.NewStyle().
				Background(selectedBg).
				Width(w - 2).
				Render(line)
		}

		lines = append(lines, line)
	}

	body := lipgloss.NewStyle().
		Padding(0, 2).
		Render(strings.Join(lines, "\n"))

	hint := ""
	if m.focused && len(m.sortedTeams) > 0 {
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Padding(1, 3).
			Render("enter to view details")
	}

	return header + "\n" + rule + "\n" + summary + "\n\n" + body + "\n" + hint
}

// renderTeamSummaryLine renders a single team summary line.
func (m TeamModel) renderTeamSummaryLine(windowIdx int, tc runtime.TeamConfig) string {
	t := m.theme

	// Team label
	label := fmt.Sprintf("Team %d", windowIdx)
	if tc.TeamName != "" {
		label = tc.TeamName
	}
	labelStr := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(label)

	// Count statuses
	busy, idle, reserved := 0, 0, 0
	for _, pi := range tc.WorkerPanes {
		paneID := fmt.Sprintf("%d.%d", windowIdx, pi)
		if ps, ok := m.panes[paneID]; ok {
			switch ps.Status {
			case "BUSY", "WORKING":
				busy++
			case "RESERVED":
				reserved++
			default:
				idle++
			}
		} else {
			idle++
		}
	}

	// Worker count
	countStr := lipgloss.NewStyle().Foreground(t.Text).Render(fmt.Sprintf("%dW", tc.WorkerCount))

	// Status parts
	var parts []string
	if busy > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Warning).Render(fmt.Sprintf("%d busy", busy)))
	}
	if idle > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Success).Render(fmt.Sprintf("%d idle", idle)))
	}
	if reserved > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Accent).Render(fmt.Sprintf("%d reserved", reserved)))
	}

	statusStr := ""
	if len(parts) > 0 {
		sep := lipgloss.NewStyle().Foreground(t.Muted).Render(", ")
		statusStr = " (" + strings.Join(parts, sep) + ")"
	}

	// Type badge
	badge := ""
	if tc.TeamType == "freelancer" {
		badge = "  " + lipgloss.NewStyle().Foreground(t.Warning).Bold(true).Render("[F]")
	} else if tc.WorktreeBranch != "" {
		branchName := tc.WorktreeBranch
		if len(branchName) > 20 {
			branchName = branchName[:19] + "…"
		}
		badge = "  " + lipgloss.NewStyle().Foreground(t.Primary).Render("[wt: "+branchName+"]")
	}

	return labelStr + "  " + countStr + statusStr + badge
}

// viewDetail renders the per-pane table for the selected team.
func (m TeamModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	tc, ok := m.teams[m.selectedTeam]
	teamLabel := fmt.Sprintf("Team %d", m.selectedTeam)
	if ok && tc.TeamName != "" {
		teamLabel = tc.TeamName
	}
	workerCount := 0
	if ok {
		workerCount = tc.WorkerCount
	}

	// Section header with team name and worker count
	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(fmt.Sprintf("%s — %d WORKERS", teamLabel, workerCount))

	rule := t.Faint.Render(strings.Repeat("─", w))

	back := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc to go back")

	return header + "\n" + rule + "\n" + back + "\n\n" + m.table.View()
}

// rebuildDetailTable populates the table with panes from the selected team.
func (m *TeamModel) rebuildDetailTable() {
	tc, ok := m.teams[m.selectedTeam]
	if !ok {
		m.table.SetRows([]table.Row{})
		return
	}

	var rows []table.Row

	// Manager pane
	if tc.ManagerPane != "" {
		rows = append(rows, m.paneRow(m.selectedTeam, tc.ManagerPane, "Manager"))
	}

	// Worker panes
	for _, pi := range tc.WorkerPanes {
		rows = append(rows, m.paneRow(m.selectedTeam, strconv.Itoa(pi), "Worker"))
	}

	// Watchdog pane
	if tc.WatchdogPane != "" {
		rows = append(rows, m.paneRow(m.selectedTeam, tc.WatchdogPane, "Watchdog"))
	}

	if len(rows) == 0 {
		rows = append(rows, table.Row{"", "", "No panes", "", ""})
	}

	m.table.SetRows(rows)
}

// paneRow creates a single row for a pane.
func (m *TeamModel) paneRow(windowIdx int, paneIdx string, role string) table.Row {
	paneID := fmt.Sprintf("%d.%s", windowIdx, paneIdx)

	status := "—"
	task := ""
	if ps, ok := m.panes[paneID]; ok {
		status = statusText(ps.Status, m.theme)
		taskMax := m.taskColWidth - 2
		if taskMax < 5 {
			taskMax = 5
		}
		task = truncate(ps.Task, taskMax)
	}

	ctxStr := "—"
	if pct, ok := m.contexts[paneID]; ok {
		ctxStr = fmt.Sprintf("%d%%", pct)
	}

	return table.Row{
		paneIdx,
		role,
		status,
		ctxStr,
		task,
	}
}

// statusText returns a foreground-colored status string.
func statusText(status string, t styles.Theme) string {
	color := styles.StatusColor(status)
	label := status
	if label == "WORKING" {
		label = "BUSY"
	}
	return lipgloss.NewStyle().Foreground(color).Render(label)
}

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
