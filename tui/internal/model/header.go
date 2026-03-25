package model

import (
	"fmt"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
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
	spinner     spinner.Model
	theme       styles.Theme
	width       int
}

// NewHeaderModel creates a header with a spinning refresh indicator.
func NewHeaderModel() HeaderModel {
	t := styles.DefaultTheme()
	s := spinner.New()
	s.Spinner = spinner.Dot
	s.Style = lipgloss.NewStyle().Foreground(t.Primary)
	return HeaderModel{
		spinner: s,
		theme:   t,
	}
}

// Init starts the spinner.
func (m HeaderModel) Init() tea.Cmd {
	return m.spinner.Tick
}

// Update handles spinner ticks.
func (m HeaderModel) Update(msg tea.Msg) (HeaderModel, tea.Cmd) {
	var cmd tea.Cmd
	m.spinner, cmd = m.spinner.Update(msg)
	return m, cmd
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

// View renders the header bar.
func (m HeaderModel) View() string {
	t := m.theme

	project := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		Render(m.projectName)

	session := lipgloss.NewStyle().
		Foreground(t.Muted).
		Render(m.sessionName)

	uptime := lipgloss.NewStyle().
		Foreground(t.Muted).
		Render("⏱ " + formatDuration(m.uptime))

	teams := lipgloss.NewStyle().
		Foreground(t.Accent).
		Render(fmt.Sprintf("%d teams", m.teamCount))

	workers := lipgloss.NewStyle().
		Foreground(t.Success).
		Render(fmt.Sprintf("%dW (%d busy)", m.workerCount, m.busyCount))

	sep := lipgloss.NewStyle().Foreground(t.Muted).Render(" · ")

	line := m.spinner.View() + " " + project + sep + session + sep + uptime + sep + teams + sep + workers

	style := lipgloss.NewStyle().
		Width(m.width).
		Padding(0, 1).
		BorderStyle(lipgloss.NormalBorder()).
		BorderBottom(true).
		BorderForeground(t.Muted)

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
