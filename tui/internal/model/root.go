package model

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// TickMsg triggers a periodic runtime re-read.
type TickMsg time.Time

// SnapshotMsg carries a fresh runtime snapshot.
type SnapshotMsg runtime.Snapshot

// saveTeamDoneMsg is returned after writing a .team.md file.
type saveTeamDoneMsg struct {
	name string
	err  error
}

const tickInterval = 5 * time.Second

// Model is the root dashboard model composing all sub-models.
type Model struct {
	runtime    *runtime.Reader
	snapshot   runtime.Snapshot
	header     HeaderModel
	welcome    WelcomeModel
	tasks      TasksModel
	team       TeamModel
	agents     AgentsModel
	footer     FooterModel
	focusIndex int // 0=welcome, 1=teams, 2=tasks, 3=agents
	width      int
	height     int
	ready      bool
}

// New creates a root model that reads from the given runtime directory.
func New(runtimeDir string) Model {
	theme := styles.DefaultTheme()
	return Model{
		runtime: runtime.NewReader(runtimeDir),
		header:  NewHeaderModel(),
		welcome: NewWelcomeModel(),
		tasks:   NewTasksModel(),
		team:   NewTeamModel(theme),
		agents: NewAgentsModel(theme),
		footer: NewFooterModel(),
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
		m.agents.SetSnapshot(m.snapshot)

	case SnapshotRefreshMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case LaunchTeamMsg:
		return m, LaunchTeamCmd(msg.Name)

	case LaunchTeamResultMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case StopTeamMsg:
		return m, StopTeamCmd(msg.Name, msg.WindowIdx)

	case StopTeamResultMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case ToggleStarMsg:
		return m, ToggleStarCmd(msg.Name)

	case ToggleStarResultMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case ToggleStartupMsg:
		return m, ToggleStartupCmd(msg.Name)

	case ToggleStartupResultMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case EditTeamMsg:
		// Find the team def and open editor
		for _, td := range m.snapshot.TeamDefs {
			if td.Name == msg.Name {
				m.team.Update(OpenEditorMsg{Def: td, IsNew: false})
				break
			}
		}

	case NewTeamMsg:
		m.team.Update(OpenEditorMsg{IsNew: true})

	case SaveTeamMsg:
		return m, m.saveTeamCmd(msg)

	case saveTeamDoneMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case CloseEditorMsg:
		m.team.Update(msg)

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
		if key.Matches(msg, m.footer.keyMap.NextPanel, m.footer.keyMap.RightPanel) {
			m.focusIndex = (m.focusIndex + 1) % 4
			m.updateFocus()
			return m, nil
		}
		if key.Matches(msg, m.footer.keyMap.PrevPanel, m.footer.keyMap.LeftPanel) {
			m.focusIndex = (m.focusIndex + 3) % 4 // +3 mod 4 == -1 with wrap
			m.updateFocus()
			return m, nil
		}
		if key.Matches(msg, m.footer.keyMap.PanelOne) {
			m.focusIndex = 0
			m.updateFocus()
			return m, nil
		}
		if key.Matches(msg, m.footer.keyMap.PanelTwo) {
			m.focusIndex = 1
			m.updateFocus()
			return m, nil
		}
		if key.Matches(msg, m.footer.keyMap.PanelThree) {
			m.focusIndex = 2
			m.updateFocus()
			return m, nil
		}
		if key.Matches(msg, m.footer.keyMap.PanelFour) {
			m.focusIndex = 3
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
		case 3:
			m.agents, cmd = m.agents.Update(msg)
		}
		cmds = append(cmds, cmd)
	}

	return m, tea.Batch(cmds...)
}

// renderMenuBar renders a navigable menu bar showing the active panel.
func (m Model) renderMenuBar(width int) string {
	t := styles.DefaultTheme()
	items := []string{"Dashboard", "Teams", "Tasks", "Agents"}

	activeStyle := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		Padding(0, 1)
	inactiveStyle := lipgloss.NewStyle().
		Foreground(t.Muted).
		Padding(0, 1)
	sepStyle := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true)

	var parts []string
	for i, item := range items {
		if i == m.focusIndex {
			parts = append(parts, activeStyle.Render("[ "+item+" ]"))
		} else {
			parts = append(parts, inactiveStyle.Render("  "+item+"  "))
		}
	}
	menu := "  " + strings.Join(parts, sepStyle.Render("·"))

	sep := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Width(width).
		Render(strings.Repeat("─", width))

	return menu + "\n" + sep
}

// View composes the full dashboard layout.
func (m Model) View() string {
	if !m.ready {
		return "\n  Loading…"
	}

	banner := RenderBanner(m.snapshot.Session.ProjectName, m.width)
	menuBar := m.renderMenuBar(m.width)
	footer := m.footer.View()

	// Calculate body height
	bannerH := lipgloss.Height(banner)
	menuH := lipgloss.Height(menuBar)
	footerH := lipgloss.Height(footer)
	bodyH := m.height - bannerH - menuH - footerH
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
	case 3:
		m.agents.SetSize(m.width, bodyH)
		body = m.agents.View()
	}

	return lipgloss.JoinVertical(lipgloss.Left, banner, menuBar, body, footer)
}

// propagateSizes distributes width/height to sub-models.
func (m *Model) propagateSizes() {
	m.footer.SetWidth(m.width)

	bannerH := lipgloss.Height(RenderBanner(m.snapshot.Session.ProjectName, m.width))
	menuH := lipgloss.Height(m.renderMenuBar(m.width))
	footerH := lipgloss.Height(m.footer.View())
	bodyH := m.height - bannerH - menuH - footerH
	if bodyH < 1 {
		bodyH = 1
	}

	// All panels get full width — only one shown at a time
	m.welcome.SetSize(m.width, bodyH)
	m.tasks.SetSize(m.width, bodyH)
	m.team.SetSize(m.width, bodyH)
	m.agents.SetSize(m.width, bodyH)
	m.updateFocus()
}

// updateFocus syncs focus state to sub-models.
func (m *Model) updateFocus() {
	m.team.SetFocused(m.focusIndex == 1)
	m.agents.SetFocused(m.focusIndex == 3)
}

// tickCmd returns a command that sends a TickMsg after the interval.
func tickCmd() tea.Cmd {
	return tea.Tick(tickInterval, func(t time.Time) tea.Msg {
		return TickMsg(t)
	})
}

// saveTeamCmd writes a team definition to a .team.md file.
func (m Model) saveTeamCmd(msg SaveTeamMsg) tea.Cmd {
	projectDir := m.snapshot.Session.ProjectDir
	def := msg.Def
	return func() tea.Msg {
		teamsDir := filepath.Join(projectDir, "teams")
		if err := os.MkdirAll(teamsDir, 0o755); err != nil {
			return saveTeamDoneMsg{name: def.Name, err: fmt.Errorf("create teams dir: %w", err)}
		}
		path := filepath.Join(teamsDir, def.Name+".team.md")
		content := SerializeTeamDef(def)
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return saveTeamDoneMsg{name: def.Name, err: err}
		}
		return saveTeamDoneMsg{name: def.Name}
	}
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
