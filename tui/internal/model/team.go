package model

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/charmbracelet/bubbles/table"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// TeamModel displays a table of all team windows and their panes.
type TeamModel struct {
	table        table.Model
	teams        map[int]runtime.TeamConfig
	panes        map[string]runtime.PaneStatus
	contexts     map[string]int
	theme        styles.Theme
	width        int
	height       int
	taskColWidth int
}

// NewTeamModel creates a team panel with an empty table.
func NewTeamModel() TeamModel {
	t := styles.DefaultTheme()

	columns := []table.Column{
		{Title: "Window", Width: 8},
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
		table:    tbl,
		teams:    make(map[int]runtime.TeamConfig),
		panes:    make(map[string]runtime.PaneStatus),
		contexts: make(map[string]int),
		theme:    t,
	}
}

// Init is a no-op for the team sub-model.
func (m TeamModel) Init() tea.Cmd {
	return nil
}

// Update forwards messages to the underlying table.
func (m TeamModel) Update(msg tea.Msg) (TeamModel, tea.Cmd) {
	var cmd tea.Cmd
	m.table, cmd = m.table.Update(msg)
	return m, cmd
}

// SetSnapshot rebuilds the table rows from fresh data.
func (m *TeamModel) SetSnapshot(snap runtime.Snapshot) {
	m.teams = snap.Teams
	m.panes = snap.Panes
	m.contexts = snap.ContextPct

	rows := m.buildRows()
	m.table.SetRows(rows)
}

// SetSize updates the panel dimensions and recalculates column widths.
func (m *TeamModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.table.SetHeight(h - 4) // account for header + border

	// Fixed column widths: Window=12, Pane=5, Role=9, Status=12, Ctx%=6
	// Table chrome overhead: ~20 chars for borders + cell padding (1 char each side × 6 cols + separators)
	const (
		colWindow = 12
		colPane   = 5
		colRole   = 9
		colStatus = 12
		colCtx    = 6
		overhead  = 20
	)
	fixedWidth := colWindow + colPane + colRole + colStatus + colCtx + overhead
	taskWidth := w - fixedWidth
	if taskWidth < 10 {
		taskWidth = 10
	}
	m.taskColWidth = taskWidth
	m.table.SetColumns([]table.Column{
		{Title: "Window", Width: colWindow},
		{Title: "Pane", Width: colPane},
		{Title: "Role", Width: colRole},
		{Title: "Status", Width: colStatus},
		{Title: "Ctx%", Width: colCtx},
		{Title: "Task", Width: taskWidth},
	})
}

// SetFocused toggles table focus.
func (m *TeamModel) SetFocused(focused bool) {
	m.table.SetCursor(0)
	m.table.Focus()
	if !focused {
		m.table.Blur()
	}
}

// buildRows creates table rows grouped by team window.
func (m *TeamModel) buildRows() []table.Row {
	var rows []table.Row

	// Sort team windows by index
	windows := make([]int, 0, len(m.teams))
	for w := range m.teams {
		windows = append(windows, w)
	}
	sort.Ints(windows)

	for _, w := range windows {
		tc := m.teams[w]

		// Count busy/idle for this team
		busy, idle := 0, 0
		for _, pi := range tc.WorkerPanes {
			paneID := fmt.Sprintf("%d.%d", w, pi)
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

		// Team header row
		teamLabel := fmt.Sprintf("W%d", w)
		if tc.TeamName != "" {
			teamLabel += " " + tc.TeamName
		}
		teamType := tc.TeamType
		if teamType == "" {
			teamType = "local"
		}
		summary := fmt.Sprintf("[%s] — %dW (%d busy, %d idle)", teamType, tc.WorkerCount, busy, idle)

		headerText := fmt.Sprintf("%s  %s", teamLabel, summary)
		rows = append(rows, table.Row{headerText, "", "", "", "", ""})

		// Manager pane
		if tc.ManagerPane != "" {
			rows = append(rows, m.paneRow(w, tc.ManagerPane, "Manager"))
		}

		// Worker panes
		for _, pi := range tc.WorkerPanes {
			rows = append(rows, m.paneRow(w, strconv.Itoa(pi), "Worker"))
		}

		// Watchdog pane
		if tc.WatchdogPane != "" {
			rows = append(rows, m.paneRow(w, tc.WatchdogPane, "Watchdog"))
		}
	}

	if len(rows) == 0 {
		rows = append(rows, table.Row{"", "", "", "No data yet", "", ""})
	}

	return rows
}

// paneRow creates a single row for a pane.
func (m *TeamModel) paneRow(windowIdx int, paneIdx string, role string) table.Row {
	paneID := fmt.Sprintf("%d.%s", windowIdx, paneIdx)

	status := "—"
	task := ""
	if ps, ok := m.panes[paneID]; ok {
		status = statusBadge(ps.Status, m.theme)
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
		"",
		paneIdx,
		role,
		status,
		ctxStr,
		task,
	}
}

// statusBadge returns a styled status string.
func statusBadge(status string, t styles.Theme) string {
	switch status {
	case "BUSY", "WORKING":
		return lipgloss.NewStyle().Foreground(t.Warning).Render(status)
	case "READY":
		return lipgloss.NewStyle().Foreground(t.Success).Render(status)
	case "FINISHED":
		return lipgloss.NewStyle().Foreground(t.Primary).Render(status)
	case "ERROR":
		return lipgloss.NewStyle().Foreground(t.Danger).Render(status)
	case "RESERVED":
		return lipgloss.NewStyle().Foreground(t.Accent).Render(status)
	default:
		return lipgloss.NewStyle().Foreground(t.Muted).Render(status)
	}
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

// View renders the team table panel.
func (m TeamModel) View() string {
	title := lipgloss.NewStyle().
		Foreground(m.theme.Primary).
		Bold(true).
		Padding(0, 1).
		Render(fmt.Sprintf("Teams (%d)", len(m.teams)))

	return title + "\n" + m.table.View()
}
