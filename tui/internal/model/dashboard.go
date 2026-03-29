package model

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// SwitchToTaskMsg requests the root model switch to the Tasks tab and select a task.
type SwitchToTaskMsg struct{ TaskID int }

// SpawnFreelancerMsg requests launching a freelancer.
type SpawnFreelancerMsg struct{}

// GetStatusMsg requests a status refresh.
type GetStatusMsg struct{}

// CreateTeamMsg requests team creation.
type CreateTeamMsg struct{}

// ViewTasksMsg requests switching to the Tasks tab.
type ViewTasksMsg struct{}

// dashTickMsg is the internal tick for reloading task data.
type dashTickMsg time.Time

// taskEntry is an internal summary of an active task for display.
type taskEntry struct {
	ID     int
	Title  string
	Status string
	Type   string
}

// DashboardModel is the primary landing tab (command center).
type DashboardModel struct {
	runtimeDir   string
	projectDir   string
	width        int
	height       int
	theme        styles.Theme
	focused      bool
	tasks        []taskEntry
	scrollOffset int
}

// NewDashboardModel creates the dashboard command center panel.
func NewDashboardModel(runtimeDir, projectDir string, width, height int, theme styles.Theme) DashboardModel {
	m := DashboardModel{
		runtimeDir: runtimeDir,
		projectDir: projectDir,
		width:      width,
		height:     height,
		theme:      theme,
	}
	m.loadTasks()
	return m
}

// Update handles messages for the dashboard panel.
func (m DashboardModel) Update(msg tea.Msg) (DashboardModel, tea.Cmd) {
	switch msg := msg.(type) {
	case dashTickMsg:
		m.loadTasks()
		return m, m.tickCmd()

	case tea.MouseMsg:
		return m.updateMouse(msg)
	}

	return m, nil
}

// View renders the dashboard command center.
func (m DashboardModel) View() string {
	w := m.width
	if w < 40 {
		w = 40
	}

	var sections []string
	sections = append(sections, m.renderActiveTasks(w))
	sections = append(sections, m.renderQuickActions(w))

	content := strings.Join(sections, "\n")

	// Apply scroll offset
	lines := strings.Split(content, "\n")
	if m.scrollOffset > len(lines)-1 {
		m.scrollOffset = len(lines) - 1
	}
	if m.scrollOffset < 0 {
		m.scrollOffset = 0
	}
	if m.scrollOffset > 0 && m.scrollOffset < len(lines) {
		lines = lines[m.scrollOffset:]
	}
	content = strings.Join(lines, "\n")

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Render(content)
}

// SetSize updates panel dimensions (value receiver to match required signature).
func (m DashboardModel) SetSize(w, h int) DashboardModel {
	m.width = w
	m.height = h
	return m
}

// SetFocused toggles focus state (value receiver to match required signature).
func (m DashboardModel) SetFocused(f bool) DashboardModel {
	m.focused = f
	return m
}

// Init returns the initial tick command.
func (m DashboardModel) Init() tea.Cmd {
	return m.tickCmd()
}

// tickCmd returns a tick command that fires every 3 seconds.
func (m DashboardModel) tickCmd() tea.Cmd {
	return tea.Tick(3*time.Second, func(t time.Time) tea.Msg {
		return dashTickMsg(t)
	})
}

// loadTasks reads .doey/tasks/ and filters for active/in_progress tasks.
func (m *DashboardModel) loadTasks() {
	if m.projectDir != "" {
		runtime.SetProjectDir(m.projectDir)
	}
	store, err := runtime.ReadTaskStore()
	if err != nil {
		m.tasks = nil
		return
	}

	var active []taskEntry
	for _, t := range store.Tasks {
		if t.Status == "active" || t.Status == "in_progress" {
			id, _ := strconv.Atoi(t.ID)
			active = append(active, taskEntry{
				ID:     id,
				Title:  t.Title,
				Status: t.Status,
				Type:   t.Type,
			})
		}
	}
	m.tasks = active
}

// --- Mouse handling ---

func (m DashboardModel) updateMouse(msg tea.MouseMsg) (DashboardModel, tea.Cmd) {
	// Click release — check zones
	if msg.Action == tea.MouseActionRelease {
		// Task card clicks
		for _, t := range m.tasks {
			if zone.Get(fmt.Sprintf("dash-task-%d", t.ID)).InBounds(msg) {
				id := t.ID
				return m, func() tea.Msg { return SwitchToTaskMsg{TaskID: id} }
			}
		}

		// Quick action clicks
		if zone.Get("dash-spawn-freelancer").InBounds(msg) {
			return m, func() tea.Msg { return SpawnFreelancerMsg{} }
		}
		if zone.Get("dash-get-status").InBounds(msg) {
			return m, func() tea.Msg { return GetStatusMsg{} }
		}
		if zone.Get("dash-create-team").InBounds(msg) {
			return m, func() tea.Msg { return CreateTeamMsg{} }
		}
		if zone.Get("dash-view-tasks").InBounds(msg) {
			return m, func() tea.Msg { return ViewTasksMsg{} }
		}
	}

	// Mouse wheel — scroll content
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp {
			if m.scrollOffset > 0 {
				m.scrollOffset--
			}
			return m, nil
		}
		if msg.Button == tea.MouseButtonWheelDown {
			m.scrollOffset++
			return m, nil
		}
	}

	return m, nil
}

// --- Rendering ---

func (m DashboardModel) renderActiveTasks(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("ACTIVE TASKS")
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.tasks) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No active tasks")
		return "\n" + header + "\n" + rule + "\n" + empty + "\n"
	}

	cardW := w - 8
	if cardW > styles.MaxCardWidth {
		cardW = styles.MaxCardWidth
	}
	if cardW < 30 {
		cardW = 30
	}

	var cards []string
	for _, task := range m.tasks {
		card := m.renderTaskCard(task, cardW)
		cards = append(cards, card)
	}

	body := lipgloss.NewStyle().
		Padding(1, 3).
		Render(strings.Join(cards, "\n"))

	return "\n" + header + "\n" + rule + "\n" + body
}

func (m DashboardModel) renderTaskCard(task taskEntry, w int) string {
	t := m.theme

	// Status badge
	badge := styles.StatusBadgeCard(task.Status, t)

	// Type tag
	typeTag := ""
	if task.Type != "" {
		typeTag = " " + styles.TypeTagCard(task.Type, t)
	}

	// Title
	title := lipgloss.NewStyle().
		Bold(true).
		Foreground(t.Text).
		Render(fmt.Sprintf("#%d %s", task.ID, task.Title))

	// ID line
	idStr := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Render(fmt.Sprintf("Task %d", task.ID))

	content := title + "\n" + badge + typeTag + "  " + idStr

	cardStyle := styles.CardStyle(t, task.Status, false, w)
	rendered := cardStyle.Render(content)

	return zone.Mark(fmt.Sprintf("dash-task-%d", task.ID), rendered)
}

func (m DashboardModel) renderQuickActions(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("QUICK ACTIONS")
	rule := t.Faint.Render(strings.Repeat("─", w))

	// Render buttons using styles.RenderButton
	btn1 := styles.RenderButton("Spawn Freelancer", "dash-spawn-freelancer", true, t)
	btn2 := styles.RenderButton("Get Status", "dash-get-status", false, t)
	btn3 := styles.RenderButton("Create Team", "dash-create-team", true, t)
	btn4 := styles.RenderButton("View Tasks", "dash-view-tasks", false, t)

	gap := "  "
	row1 := lipgloss.JoinHorizontal(lipgloss.Center, btn1, gap, btn2)
	row2 := lipgloss.JoinHorizontal(lipgloss.Center, btn3, gap, btn4)

	grid := lipgloss.NewStyle().
		Padding(1, 3).
		Render(row1 + "\n\n" + row2)

	return "\n" + header + "\n" + rule + "\n" + grid + "\n"
}
