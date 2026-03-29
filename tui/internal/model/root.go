package model

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// TickMsg triggers a full runtime snapshot re-read (every 5s).
type TickMsg time.Time

// HeartbeatTickMsg triggers a lightweight heartbeat recompute (every 2s).
// No file I/O — recomputes health/staleness from the existing snapshot.
type HeartbeatTickMsg time.Time

// SnapshotMsg carries a fresh runtime snapshot.
type SnapshotMsg runtime.Snapshot

// saveTeamDoneMsg is returned after writing a .team.md file.
type saveTeamDoneMsg struct {
	name string
	err  error
}

const (
	snapshotInterval  = 5 * time.Second
	heartbeatInterval = 2 * time.Second
)

// Model is the root dashboard model composing all sub-models.
type Model struct {
	runtime    *runtime.Reader
	snapshot   runtime.Snapshot
	header     HeaderModel
	welcome    WelcomeModel
	tasks      TasksModel
	team       TeamModel
	agents     AgentsModel
	debug      DebugModel
	messages   MessagesModel
	logView    LogViewModel
	tabBar     TabBarModel
	footer     FooterModel
	heartbeats map[string]runtime.HeartbeatState
	focusIndex int // 0=welcome, 1=teams, 2=tasks, 3=agents, 4=debug, 5=messages, 6=logs
	width      int
	height     int
	ready      bool
}

// New creates a root model that reads from the given runtime directory.
func New(runtimeDir string) Model {
	theme := styles.DefaultTheme()
	tabs := []TabItem{
		{Name: "Dashboard", Icon: "◆"},
		{Name: "Teams", Icon: "◈"},
		{Name: "Tasks", Icon: "▣"},
		{Name: "Agents", Icon: "◉"},
		{Name: "Debug", Icon: "⚙"},
		{Name: "Messages", Icon: "✉"},
		{Name: "Logs", Icon: "▤"},
	}
	return Model{
		runtime:  runtime.NewReader(runtimeDir),
		header:   NewHeaderModel(),
		welcome:  NewWelcomeModel(),
		tasks:    NewTasksModel(),
		team:     NewTeamModel(theme),
		agents:   NewAgentsModel(theme),
		debug:    NewDebugModel(theme),
		messages: NewMessagesModel(theme),
		logView:  NewLogViewModel(theme),
		tabBar:   NewTabBarModel(tabs),
		footer:   NewFooterModel(),
	}
}

// Init starts the snapshot and heartbeat timers.
func (m Model) Init() tea.Cmd {
	return tea.Batch(snapshotTickCmd(), heartbeatTickCmd())
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
		cmds = append(cmds, snapshotTickCmd())
		cmds = append(cmds, m.readSnapshotCmd())

	case HeartbeatTickMsg:
		// Lightweight: recompute health/staleness from existing snapshot (no I/O)
		m.heartbeats = runtime.AggregateHeartbeats(m.snapshot)
		cmds = append(cmds, heartbeatTickCmd())

	case SnapshotMsg:
		m.snapshot = runtime.Snapshot(msg)
		m.heartbeats = runtime.AggregateHeartbeats(m.snapshot)
		m.header.SetSnapshot(m.snapshot)
		m.welcome.SetSnapshot(m.snapshot)
		m.tasks.SetSnapshot(m.snapshot)
		m.team.SetSnapshot(m.snapshot)
		m.agents.SetSnapshot(m.snapshot)
		m.debug.SetSnapshot(m.snapshot)
		m.messages.SetSnapshot(m.snapshot)
		m.logView.SetSnapshot(m.snapshot)

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

	case DispatchTeamMsg:
		runtimeDir := m.runtime.RuntimeDir()
		sessionName := m.snapshot.Session.SessionName
		return m, DispatchTeamCmd(runtimeDir, sessionName, msg.WindowIdx, msg.Task)

	case DispatchTeamResultMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case CreateTaskMsg:
		return m, CreateTaskCmd(msg.Title)

	case CreateTaskResultMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case MoveTaskMsg:
		return m, MoveTaskCmd(msg.ID, msg.Status)

	case MoveTaskResultMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case CancelTaskMsg:
		return m, CancelTaskCmd(msg.ID)

	case CancelTaskResultMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case DispatchTaskMsg:
		runtimeDir := m.runtime.RuntimeDir()
		sessionName := m.snapshot.Session.SessionName
		return m, DispatchTaskCmd(runtimeDir, sessionName, msg.ID, msg.Title)

	case DispatchTaskResultMsg:
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
			m.focusIndex = (m.focusIndex + 1) % 7
			m.updateFocus()
			return m, nil
		}
		if key.Matches(msg, m.footer.keyMap.PrevPanel, m.footer.keyMap.LeftPanel) {
			m.focusIndex = (m.focusIndex + 6) % 7 // +6 mod 7 == -1 with wrap
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
		if key.Matches(msg, m.footer.keyMap.PanelFive) {
			m.focusIndex = 4
			m.updateFocus()
			return m, nil
		}
		if key.Matches(msg, m.footer.keyMap.PanelSix) {
			m.focusIndex = 5
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
		case 4:
			m.debug, cmd = m.debug.Update(msg)
		case 5:
			m.messages, cmd = m.messages.Update(msg)
		case 6:
			m.logView, cmd = m.logView.Update(msg)
		}
		cmds = append(cmds, cmd)
	}

	return m, tea.Batch(cmds...)
}

// renderTabBar returns the tab bar view, synced to focusIndex.
func (m Model) renderTabBar() string {
	return m.tabBar.View()
}

// View composes the full dashboard layout.
func (m Model) View() string {
	if !m.ready {
		return "\n  Loading…"
	}

	banner := RenderBanner(m.snapshot.Session.ProjectName, m.width)
	tabBar := m.renderTabBar()
	footer := m.footer.View()

	// Calculate body height
	bannerH := lipgloss.Height(banner)
	menuH := lipgloss.Height(tabBar)
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
	case 4:
		m.debug.SetSize(m.width, bodyH)
		body = m.debug.View()
	case 5:
		m.messages.SetSize(m.width, bodyH)
		body = m.messages.View()
	case 6:
		m.logView.SetSize(m.width, bodyH)
		body = m.logView.View()
	}

	return lipgloss.JoinVertical(lipgloss.Left, banner, tabBar, body, footer)
}

// propagateSizes distributes width/height to sub-models.
func (m *Model) propagateSizes() {
	m.footer.SetWidth(m.width)

	m.tabBar.SetWidth(m.width)
	bannerH := lipgloss.Height(RenderBanner(m.snapshot.Session.ProjectName, m.width))
	menuH := lipgloss.Height(m.renderTabBar())
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
	m.debug.SetSize(m.width, bodyH)
	m.messages.SetSize(m.width, bodyH)
	m.logView.SetSize(m.width, bodyH)
	m.updateFocus()
}

// updateFocus syncs focus state to sub-models and tab bar.
func (m *Model) updateFocus() {
	m.tabBar.SetActive(m.focusIndex)
	m.team.SetFocused(m.focusIndex == 1)
	m.tasks.SetFocused(m.focusIndex == 2)
	m.agents.SetFocused(m.focusIndex == 3)
	m.debug.SetFocused(m.focusIndex == 4)
	m.messages.SetFocused(m.focusIndex == 5)
	m.logView.SetFocused(m.focusIndex == 6)
}

// snapshotTickCmd triggers a full snapshot re-read every 5s.
func snapshotTickCmd() tea.Cmd {
	return tea.Tick(snapshotInterval, func(t time.Time) tea.Msg {
		return TickMsg(t)
	})
}

// heartbeatTickCmd triggers a lightweight heartbeat recompute every 2s.
func heartbeatTickCmd() tea.Cmd {
	return tea.Tick(heartbeatInterval, func(t time.Time) tea.Msg {
		return HeartbeatTickMsg(t)
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
