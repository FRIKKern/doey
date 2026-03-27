package model

import (
	"fmt"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// HeaderModel displays project name, session info, uptime, and team stats.
type HeaderModel struct {
	projectName string
	sessionName string
	uptime      time.Duration
	teamCount   int
	workerCount int
	busyCount   int
	theme       styles.Theme
	width       int
}

// NewHeaderModel creates a header with labeled stats.
func NewHeaderModel() HeaderModel {
	return HeaderModel{
		theme: styles.DefaultTheme(),
	}
}

// Init is a no-op — no spinner to start.
func (m HeaderModel) Init() tea.Cmd {
	return nil
}

// Update is a no-op — no spinner to tick.
func (m HeaderModel) Update(msg tea.Msg) (HeaderModel, tea.Cmd) {
	return m, nil
}

// SetSnapshot updates header data from a runtime snapshot.
func (m *HeaderModel) SetSnapshot(snap runtime.Snapshot) {
	m.projectName = snap.Session.ProjectName
	m.sessionName = snap.Session.SessionName
	m.uptime = snap.Uptime
	m.teamCount = len(snap.Teams)

	workers := 0
	busy := 0
	for _, tc := range snap.Teams {
		workers += tc.WorkerCount
	}
	for _, ps := range snap.Panes {
		if ps.Status == "BUSY" || ps.Status == "WORKING" {
			busy++
		}
	}
	m.workerCount = workers
	m.busyCount = busy
}

// SetWidth sets the available width for rendering.
func (m *HeaderModel) SetWidth(w int) {
	m.width = w
}

// View renders the header bar with labeled stats and dot separators.
func (m HeaderModel) View() string {
	t := m.theme
	sep := t.DotSeparator()

	projectLabel := t.StatLabel.Render("PROJECT")
	projectVal := lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render(m.projectName)

	sessionLabel := t.StatLabel.Render("SESSION")
	sessionVal := lipgloss.NewStyle().Foreground(t.Text).Render(m.sessionName)

	uptimeLabel := t.StatLabel.Render("UPTIME")
	uptimeVal := lipgloss.NewStyle().Foreground(t.Text).Render(formatDuration(m.uptime))

	teamsLabel := t.StatLabel.Render("TEAMS")
	teamsVal := lipgloss.NewStyle().Foreground(t.Accent).Render(fmt.Sprintf("%d", m.teamCount))

	workersLabel := t.StatLabel.Render("WORKERS")
	workersVal := lipgloss.NewStyle().Foreground(t.Success).Render(fmt.Sprintf("%d", m.workerCount))
	busyVal := ""
	if m.busyCount > 0 {
		busyVal = lipgloss.NewStyle().Foreground(t.Warning).Render(fmt.Sprintf(" (%d busy)", m.busyCount))
	}

	line := "  " +
		projectLabel + " " + projectVal + sep +
		sessionLabel + " " + sessionVal + sep +
		uptimeLabel + " " + uptimeVal + sep +
		teamsLabel + " " + teamsVal + sep +
		workersLabel + " " + workersVal + busyVal

	style := lipgloss.NewStyle().
		Width(m.width).
		Padding(0, 0)

	return style.Render(line)
}

// formatDuration formats a duration as "Xh Ym" or "Xm Ys".
func formatDuration(d time.Duration) string {
	d = d.Round(time.Second)
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	s := int(d.Seconds()) % 60

	if h > 0 {
		return fmt.Sprintf("%dh %dm", h, m)
	}
	if m > 0 {
		return fmt.Sprintf("%dm %ds", m, s)
	}
	return fmt.Sprintf("%ds", s)
}
