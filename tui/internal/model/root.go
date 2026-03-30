package model

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

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

// ReservedFreelancerResultMsg is returned after spawning reserved freelancers.
type ReservedFreelancerResultMsg struct {
	Err error
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
	dashboard  DashboardModel
	tasks      TasksModel
	team       TeamModel
	agents     AgentsModel
	logsGroup  LogsGroupModel
	connections ConnectionsModel
	tabBar      TabBarModel
	footer     FooterModel
	heartbeats map[string]runtime.HeartbeatState
	focusIndex int // 0=dashboard, 1=teams, 2=tasks, 3=agents, 4=logs(group), 5=connections
	width      int
	height     int
	ready      bool
}

// New creates a root model that reads from the given runtime directory.
func New(runtimeDir string) Model {
	theme := styles.DefaultTheme()
	tabs := []TabItem{
		{Name: "Dashboard", Icon: "◆"},
		{Name: "Teams", Icon: "⟫"},
		{Name: "Tasks", Icon: "›"},
		{Name: "Agents", Icon: "•"},
		{Name: "Logs", Icon: "─"},
		{Name: "Connections", Icon: "→"},
	}
	return Model{
		runtime:   runtime.NewReader(runtimeDir),
		header:    NewHeaderModel(),
		dashboard: NewDashboardModel(runtimeDir, "", 0, 0, theme),
		tasks:       NewTasksModel(),
		team:        NewTeamModel(theme),
		agents:      NewAgentsModel(theme),
		logsGroup:   NewLogsGroupModel(theme),
		connections: NewConnectionsModel(theme),
		tabBar:      NewTabBarModel(tabs),
		footer:    NewFooterModel(),
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
		m.dashboard.SetHeartbeats(m.heartbeats)
		cmds = append(cmds, heartbeatTickCmd())

	case SwitchToTaskMsg:
		m.focusIndex = 2
		m.updateFocus()
		return m, nil

	case ViewTasksMsg:
		m.focusIndex = 2
		m.updateFocus()
		return m, nil

	case CreateTeamMsg:
		m.focusIndex = 1
		m.updateFocus()
		return m, CreateTeamCmd()

	case CreateTeamResultMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case SnapshotMsg:
		m.snapshot = runtime.Snapshot(msg)
		m.heartbeats = runtime.AggregateHeartbeats(m.snapshot)
		m.dashboard.SetHeartbeats(m.heartbeats)
		m.header.SetSnapshot(m.snapshot)
		m.dashboard, _ = m.dashboard.Update(msg)
		m.tasks.SetSnapshot(m.snapshot)
		m.team.SetSnapshot(m.snapshot)
		m.agents.SetSnapshot(m.snapshot)
		m.logsGroup.SetSnapshot(m.snapshot)
		m.connections.SetSnapshot(m.snapshot)

	case SnapshotRefreshMsg:
		cmds = append(cmds, m.readSnapshotCmd())

	case ReservedFreelancerMsg:
		return m, SpawnReservedFreelancerCmd()

	case ReservedFreelancerResultMsg:
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

	case tea.MouseMsg:
		// Tab bar clicks — check on release to avoid double-fire
		if msg.Action == tea.MouseActionRelease {
			// Back button click — send Escape to active panel
			if zone.Get("back-btn").InBounds(msg) {
				escMsg := tea.KeyMsg{Type: tea.KeyEscape}
				var cmd tea.Cmd
				switch m.focusIndex {
				case 0:
					m.dashboard, cmd = m.dashboard.Update(escMsg)
				case 1:
					m.team, cmd = m.team.Update(escMsg)
				case 2:
					m.tasks, cmd = m.tasks.Update(escMsg)
				case 3:
					m.agents, cmd = m.agents.Update(escMsg)
				case 4:
					m.logsGroup, cmd = m.logsGroup.Update(escMsg)
				case 5:
					m.connections, cmd = m.connections.Update(escMsg)
				}
				cmds = append(cmds, cmd)
				return m, tea.Batch(cmds...)
			}

			for i := range m.tabBar.tabs {
				if zone.Get(fmt.Sprintf("tab-%d", i)).InBounds(msg) {
					m.focusIndex = i
					m.updateFocus()
					return m, nil
				}
			}
		}

		// Pass mouse events to focused sub-model
		var cmd tea.Cmd
		switch m.focusIndex {
		case 0:
			m.dashboard, cmd = m.dashboard.Update(msg)
		case 1:
			m.team, cmd = m.team.Update(msg)
		case 2:
			m.tasks, cmd = m.tasks.Update(msg)
		case 3:
			m.agents, cmd = m.agents.Update(msg)
		case 4:
			m.logsGroup, cmd = m.logsGroup.Update(msg)
		case 5:
			m.connections, cmd = m.connections.Update(msg)
		}
		cmds = append(cmds, cmd)

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
			m.focusIndex = (m.focusIndex + 1) % 6
			m.updateFocus()
			return m, nil
		}
		if key.Matches(msg, m.footer.keyMap.PrevPanel) {
			m.focusIndex = (m.focusIndex + 5) % 6 // +5 mod 6 == -1 with wrap
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
			m.dashboard, cmd = m.dashboard.Update(msg)
		case 1:
			m.team, cmd = m.team.Update(msg)
		case 2:
			m.tasks, cmd = m.tasks.Update(msg)
		case 3:
			m.agents, cmd = m.agents.Update(msg)
		case 4:
			m.logsGroup, cmd = m.logsGroup.Update(msg)
		case 5:
			m.connections, cmd = m.connections.Update(msg)
		}
		cmds = append(cmds, cmd)
	}

	return m, tea.Batch(cmds...)
}

// isDetailView returns true if the active panel is showing a detail/expanded view.
func (m Model) isDetailView() bool {
	switch m.focusIndex {
	case 1:
		return !m.team.summaryMode
	case 2:
		return !m.tasks.leftFocused
	case 3:
		return !m.agents.leftFocused
	case 4:
		return !m.logsGroup.leftFocused
	}
	return false
}

// renderBackButton returns a clickable back button if in a detail view.
func (m Model) renderBackButton() string {
	if !m.isDetailView() {
		return ""
	}
	theme := styles.DefaultTheme()
	return "  " + styles.RenderButton("← Back", "back-btn", false, theme) + "\n"
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
	backBtn := m.renderBackButton()
	footer := m.footer.View()

	// Calculate body height
	bannerH := lipgloss.Height(banner)
	menuH := lipgloss.Height(tabBar)
	backH := lipgloss.Height(backBtn)
	footerH := lipgloss.Height(footer)
	bodyH := m.height - bannerH - menuH - backH - footerH
	if bodyH < 1 {
		bodyH = 1
	}

	// Show active panel at full width
	var body string
	switch m.focusIndex {
	case 0:
		m.dashboard = m.dashboard.SetSize(m.width, bodyH)
		body = m.dashboard.View()
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
		m.logsGroup.SetSize(m.width, bodyH)
		body = m.logsGroup.View()
	case 5:
		m.connections.SetSize(m.width, bodyH)
		body = m.connections.View()
	}

	return zone.Scan(lipgloss.JoinVertical(lipgloss.Left, banner, tabBar, backBtn, body, footer))
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
	m.dashboard = m.dashboard.SetSize(m.width, bodyH)
	m.tasks.SetSize(m.width, bodyH)
	m.team.SetSize(m.width, bodyH)
	m.agents.SetSize(m.width, bodyH)
	m.logsGroup.SetSize(m.width, bodyH)
	m.connections.SetSize(m.width, bodyH)
	m.updateFocus()
}

// updateFocus syncs focus state to sub-models and tab bar.
func (m *Model) updateFocus() {
	m.tabBar.SetActive(m.focusIndex)
	m.dashboard = m.dashboard.SetFocused(m.focusIndex == 0)
	m.team.SetFocused(m.focusIndex == 1)
	m.tasks.SetFocused(m.focusIndex == 2)
	m.agents.SetFocused(m.focusIndex == 3)
	m.logsGroup.SetFocused(m.focusIndex == 4)
	m.connections.SetFocused(m.focusIndex == 5)
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

// SpawnReservedFreelancerCmd runs "doey add-window --type freelancer --reserved --grid 3x2".
func SpawnReservedFreelancerCmd() tea.Cmd {
	return func() tea.Msg {
		path, err := exec.LookPath("doey")
		if err != nil {
			return ReservedFreelancerResultMsg{Err: fmt.Errorf("doey not found in PATH: %w", err)}
		}
		cmd := exec.Command(path, "add-window", "--type", "freelancer", "--reserved", "--grid", "3x2")
		out, err := cmd.CombinedOutput()
		if err != nil {
			return ReservedFreelancerResultMsg{Err: fmt.Errorf("%w: %s", err, out)}
		}
		return ReservedFreelancerResultMsg{}
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
