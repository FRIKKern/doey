package model

import (
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/runtime"
)

// TickMsg triggers a periodic runtime re-read.
type TickMsg time.Time

// SnapshotMsg carries a fresh runtime snapshot.
type SnapshotMsg runtime.Snapshot

const tickInterval = 5 * time.Second

// Model is the root dashboard model composing all sub-models.
type Model struct {
	runtime    *runtime.Reader
	snapshot   runtime.Snapshot
	header     HeaderModel
	welcome    WelcomeModel
	tasks      TasksModel
	team       TeamModel
	footer     FooterModel
	focusIndex int // 0=welcome, 1=teams, 2=tasks
	width      int
	height     int
	ready      bool
}

// New creates a root model that reads from the given runtime directory.
func New(runtimeDir string) Model {
	return Model{
		runtime: runtime.NewReader(runtimeDir),
		header:  NewHeaderModel(),
		welcome: NewWelcomeModel(),
		tasks:   NewTasksModel(),
		team:    NewTeamModel(),
		footer:  NewFooterModel(),
	}
}

// Init starts the tick timer.
func (m Model) Init() tea.Cmd {
	return tickCmd()
}

// Update handles all messages and routes to sub-models.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.ready = true
		m.propagateSizes()

	case TickMsg:
		cmds = append(cmds, tickCmd())
		cmds = append(cmds, m.readSnapshotCmd())

	case SnapshotMsg:
		m.snapshot = runtime.Snapshot(msg)
		m.header.SetSnapshot(m.snapshot)
		m.welcome.SetSnapshot(m.snapshot)
		m.tasks.SetSnapshot(m.snapshot)
		m.team.SetSnapshot(m.snapshot)

	case tea.KeyMsg:
		// Global keys
		if key.Matches(msg, m.footer.keyMap.Quit, m.footer.keyMap.ForceQuit) {
			return m, tea.Quit
		}
		if key.Matches(msg, m.footer.keyMap.Help) {
			m.footer, _ = m.footer.Update(msg)
			m.propagateSizes() // help overlay changes available height
			return m, nil
		}
		if key.Matches(msg, m.footer.keyMap.NextPanel) {
			m.focusIndex = (m.focusIndex + 1) % 3
			m.updateFocus()
			return m, nil
		}

		// Route to focused sub-model
		var cmd tea.Cmd
		switch m.focusIndex {
		case 0:
			m.welcome, cmd = m.welcome.Update(msg)
		case 1:
			m.team, cmd = m.team.Update(msg)
		case 2:
			m.tasks, cmd = m.tasks.Update(msg)
		}
		cmds = append(cmds, cmd)
	}

	return m, tea.Batch(cmds...)
}

// View composes the full dashboard layout.
func (m Model) View() string {
	if !m.ready {
		return "\n  Loading…"
	}

	header := m.header.View()
	footer := m.footer.View()

	// Calculate body height
	headerH := lipgloss.Height(header)
	footerH := lipgloss.Height(footer)
	bodyH := m.height - headerH - footerH
	if bodyH < 1 {
		bodyH = 1
	}

	// Show active panel at full width
	var body string
	switch m.focusIndex {
	case 0:
		m.welcome.SetSize(m.width, bodyH)
		body = m.welcome.View()
	case 1:
		m.team.SetSize(m.width, bodyH)
		body = m.team.View()
	case 2:
		m.tasks.SetSize(m.width, bodyH)
		body = m.tasks.View()
	}

	return lipgloss.JoinVertical(lipgloss.Left, header, body, footer)
}

// propagateSizes distributes width/height to sub-models.
func (m *Model) propagateSizes() {
	m.header.SetWidth(m.width)
	m.footer.SetWidth(m.width)

	headerH := lipgloss.Height(m.header.View())
	footerH := lipgloss.Height(m.footer.View())
	bodyH := m.height - headerH - footerH
	if bodyH < 1 {
		bodyH = 1
	}

	// All panels get full width — only one shown at a time
	m.welcome.SetSize(m.width, bodyH)
	m.tasks.SetSize(m.width, bodyH)
	m.team.SetSize(m.width, bodyH)
	m.updateFocus()
}

// updateFocus syncs focus state to sub-models.
func (m *Model) updateFocus() {
	m.team.SetFocused(m.focusIndex == 1)
}

// tickCmd returns a command that sends a TickMsg after the interval.
func tickCmd() tea.Cmd {
	return tea.Tick(tickInterval, func(t time.Time) tea.Msg {
		return TickMsg(t)
	})
}

// readSnapshotCmd reads the runtime snapshot in a goroutine.
func (m Model) readSnapshotCmd() tea.Cmd {
	reader := m.runtime
	return func() tea.Msg {
		snap, err := reader.ReadSnapshot()
		if err != nil {
			// Return empty snapshot on error — graceful degradation
			return SnapshotMsg(runtime.Snapshot{
				Teams:      make(map[int]runtime.TeamConfig),
				Panes:      make(map[string]runtime.PaneStatus),
				Results:    make(map[string]runtime.PaneResult),
				ContextPct: make(map[string]int),
			})
		}
		return SnapshotMsg(snap)
	}
}
