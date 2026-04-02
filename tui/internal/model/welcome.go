package model

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// WelcomeModel renders the home/welcome tab with onboarding, team status,
// and command reference.
type WelcomeModel struct {
	snapshot     runtime.Snapshot
	theme        styles.Theme
	keyMap       keys.KeyMap
	width        int
	height       int
	scrollOffset int
	focused      bool
}

// NewWelcomeModel creates the welcome panel.
func NewWelcomeModel() WelcomeModel {
	return WelcomeModel{
		theme:  styles.DefaultTheme(),
		keyMap: keys.DefaultKeyMap(),
	}
}

// Init is a no-op.
func (m WelcomeModel) Init() tea.Cmd { return nil }

// Update handles messages relevant to the welcome view.
func (m WelcomeModel) Update(msg tea.Msg) (WelcomeModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.KeyMsg:
		maxOff := m.maxScrollOffset()
		switch {
		case key.Matches(msg, m.keyMap.Up):
			if m.scrollOffset > 0 {
				m.scrollOffset--
			}
		case key.Matches(msg, m.keyMap.Down):
			if m.scrollOffset < maxOff {
				m.scrollOffset++
			}
		}
		return m, nil
	case tea.MouseMsg:
		return m.updateMouse(msg)
	}

	return m, nil
}

// SetFocused toggles focus state.
func (m *WelcomeModel) SetFocused(focused bool) {
	m.focused = focused
}

// updateMouse handles mouse interactions for the welcome panel.
func (m WelcomeModel) updateMouse(msg tea.MouseMsg) (WelcomeModel, tea.Cmd) {
	// Click release — check interactive zones
	if msg.Action == tea.MouseActionRelease {
		// Team status entries
		for i := 0; i < 20; i++ {
			if zone.Get(fmt.Sprintf("welcome-team-%d", i)).InBounds(msg) {
				// Could trigger team switch — for now just acknowledge
				return m, nil
			}
		}
		// How-to-use steps
		for i := 0; i < 3; i++ {
			if zone.Get(fmt.Sprintf("welcome-step-%d", i)).InBounds(msg) {
				return m, nil
			}
		}
		// Slash command entries
		for i := 0; i < 30; i++ {
			if zone.Get(fmt.Sprintf("welcome-cmd-%d", i)).InBounds(msg) {
				return m, nil
			}
		}
		// CLI command entries
		for i := 0; i < 10; i++ {
			if zone.Get(fmt.Sprintf("welcome-cli-%d", i)).InBounds(msg) {
				return m, nil
			}
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
			if m.scrollOffset < m.maxScrollOffset() {
				m.scrollOffset++
			}
			return m, nil
		}
	}

	return m, nil
}

// maxScrollOffset returns the maximum valid scroll offset based on content height.
func (m WelcomeModel) maxScrollOffset() int {
	content := m.renderAllContent()
	totalLines := strings.Count(content, "\n") + 1
	viewH := m.height
	if viewH <= 0 {
		viewH = 1
	}
	off := totalLines - viewH
	if off < 0 {
		return 0
	}
	return off
}

// renderAllContent builds the full welcome content (used for scroll bounds).
func (m WelcomeModel) renderAllContent() string {
	w := m.width
	if w < 40 {
		w = 40
	}
	var sections []string
	if ts := m.renderTeamStatus(w); ts != "" {
		sections = append(sections, ts)
	}
	sections = append(sections, m.renderHowToUse())
	sections = append(sections, m.renderSlashCommands(w))
	sections = append(sections, m.renderCLICommands(w))
	return strings.Join(sections, "\n")
}

// SetSnapshot updates the welcome panel with fresh runtime data.
func (m *WelcomeModel) SetSnapshot(snap runtime.Snapshot) {
	m.snapshot = snap
}

// SetSize updates the panel dimensions.
func (m *WelcomeModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// View renders the welcome content (no banner — root.go handles that).
func (m WelcomeModel) View() string {
	w := m.width
	content := m.renderAllContent()

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

// ── Team Status ─────────────────────────────────────────────────────

func (m WelcomeModel) renderTeamStatus(w int) string {
	if len(m.snapshot.Teams) == 0 {
		return ""
	}

	t := m.theme
	header := t.SectionHeader.Copy().PaddingLeft(2).Render("TEAM STATUS")

	windows := make([]int, 0, len(m.snapshot.Teams))
	for wi := range m.snapshot.Teams {
		windows = append(windows, wi)
	}
	sort.Ints(windows)

	var lines []string
	lines = append(lines, "")
	lines = append(lines, header)
	lines = append(lines, "")

	for _, wi := range windows {
		tc := m.snapshot.Teams[wi]
		busy, idle, reserved := 0, 0, 0
		for _, pi := range tc.WorkerPanes {
			paneID := fmt.Sprintf("%d.%d", wi, pi)
			if ps, ok := m.snapshot.Panes[paneID]; ok {
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

		label := fmt.Sprintf("Team %d", wi)
		if tc.TeamName != "" {
			label = tc.TeamName
		}

		badge := ""
		if tc.TeamType == "freelancer" {
			badge = " " + styles.TeamBadge("freelancer")
		} else if tc.WorktreeDir != "" {
			badge = " " + styles.TeamBadge("worktree")
		}

		busyStr := lipgloss.NewStyle().Foreground(t.Warning).Render(fmt.Sprintf("%d busy", busy))
		idleStr := lipgloss.NewStyle().Foreground(t.Success).Render(fmt.Sprintf("%d idle", idle))

		summary := fmt.Sprintf("%dW (%s, %s", tc.WorkerCount, busyStr, idleStr)
		if reserved > 0 {
			rsvStr := lipgloss.NewStyle().Foreground(t.Accent).Render(fmt.Sprintf("%d rsv", reserved))
			summary += ", " + rsvStr
		}
		summary += ")"

		teamLine := fmt.Sprintf("  %s%s  %s", label, badge, summary)
		lines = append(lines, zone.Mark(fmt.Sprintf("welcome-team-%d", wi), teamLine))
	}

	lines = append(lines, "")
	return strings.Join(lines, "\n")
}

// ── How To Use Doey ─────────────────────────────────────────────────

func (m WelcomeModel) renderHowToUse() string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("HOW TO USE DOEY")

	numStyle := lipgloss.NewStyle().Bold(true).Foreground(t.Text)
	cyanStyle := lipgloss.NewStyle().Foreground(t.Primary)
	yellowStyle := lipgloss.NewStyle().Foreground(t.Warning)
	greenStyle := lipgloss.NewStyle().Foreground(t.Success)
	dimStyle := lipgloss.NewStyle().Foreground(t.Muted)

	steps := []string{
		fmt.Sprintf("  %s Talk to the %s (right pane\n     in this window) %s describe your task and\n     it routes work to the right team.",
			numStyle.Render("1."),
			cyanStyle.Render("Boss"),
			dimStyle.Render("—")),
		fmt.Sprintf("  %s Switch to a team window (%s) and\n     talk to the Subtaskmaster directly.",
			numStyle.Render("2."),
			yellowStyle.Render("Ctrl-b 1")),
		fmt.Sprintf("  %s Click any worker pane and run %s\n     to claim it for yourself.",
			numStyle.Render("3."),
			greenStyle.Render("/doey-reserve")),
	}

	var lines []string
	lines = append(lines, "")
	lines = append(lines, header)
	lines = append(lines, "")
	for i, step := range steps {
		lines = append(lines, zone.Mark(fmt.Sprintf("welcome-step-%d", i), step))
		lines = append(lines, "")
	}

	return strings.Join(lines, "\n")
}

// ── Slash Commands ──────────────────────────────────────────────────

type cmdEntry struct {
	name string
	desc string
}

func (m WelcomeModel) renderSlashCommands(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("SLASH COMMANDS")

	greenStyle := lipgloss.NewStyle().Foreground(t.Success)
	cyanStyle := lipgloss.NewStyle().Foreground(t.Primary)
	yellowStyle := lipgloss.NewStyle().Foreground(t.Warning)
	magentaStyle := lipgloss.NewStyle().Foreground(t.Accent)

	type cmdGroup struct {
		label string
		style lipgloss.Style
		cmds  []cmdEntry
	}

	groups := []cmdGroup{
		{
			label: "Tasks",
			style: lipgloss.NewStyle().Foreground(t.Success).Bold(true),
			cmds: []cmdEntry{
				{greenStyle.Render("/doey-task"), "Manage tasks"},
				{greenStyle.Render("/doey-dispatch"), "Send tasks"},
				{greenStyle.Render("/doey-delegate"), "Delegate task"},
				{greenStyle.Render("/doey-broadcast"), "Broadcast"},
				{greenStyle.Render("/doey-research"), "Research task"},
				{greenStyle.Render("/doey-reserve"), "Reserve pane"},
			},
		},
		{
			label: "Monitoring",
			style: lipgloss.NewStyle().Foreground(t.Primary).Bold(true),
			cmds: []cmdEntry{
				{cyanStyle.Render("/doey-status"), "Pane status"},
				{cyanStyle.Render("/doey-monitor"), "Monitor workers"},
				{cyanStyle.Render("/doey-list-windows"), "List teams"},
			},
		},
		{
			label: "Team Management",
			style: lipgloss.NewStyle().Foreground(t.Warning).Bold(true),
			cmds: []cmdEntry{
				{yellowStyle.Render("/doey-add-window"), "Add team"},
				{yellowStyle.Render("/doey-kill-window"), "Kill team"},
				{yellowStyle.Render("/doey-worktree"), "Git worktree"},
				{yellowStyle.Render("/doey-clear"), "Relaunch"},
				{yellowStyle.Render("/doey-reload"), "Hot-reload"},
			},
		},
		{
			label: "Maintenance",
			style: lipgloss.NewStyle().Foreground(t.Accent).Bold(true),
			cmds: []cmdEntry{
				{magentaStyle.Render("/doey-stop"), "Stop worker"},
				{magentaStyle.Render("/doey-purge"), "Audit/fix"},
				{magentaStyle.Render("/doey-simplify-everything"), "Simplify"},
				{magentaStyle.Render("/doey-repair"), "Fix dashboard"},
				{magentaStyle.Render("/doey-kill-session"), "Kill session"},
				{magentaStyle.Render("/doey-reinstall"), "Reinstall"},
			},
		},
	}

	colW := w - 6
	twoCol := w > 100
	if twoCol {
		colW = (w - 8) / 2
	}

	var lines []string
	lines = append(lines, "")
	lines = append(lines, header)
	lines = append(lines, "")

	cmdIdx := 0
	for _, g := range groups {
		lines = append(lines, "  "+g.style.Render(g.label))
		if twoCol {
			for i := 0; i < len(g.cmds); i += 2 {
				left := t.DottedLeader(g.cmds[i].name, g.cmds[i].desc, colW)
				right := ""
				if i+1 < len(g.cmds) {
					right = "  " + t.DottedLeader(g.cmds[i+1].name, g.cmds[i+1].desc, colW)
				}
				line := "  " + left + right
				lines = append(lines, zone.Mark(fmt.Sprintf("welcome-cmd-%d", cmdIdx), line))
				cmdIdx++
			}
		} else {
			for _, c := range g.cmds {
				line := "  " + t.DottedLeader(c.name, c.desc, colW)
				lines = append(lines, zone.Mark(fmt.Sprintf("welcome-cmd-%d", cmdIdx), line))
				cmdIdx++
			}
		}
		lines = append(lines, "")
	}

	return strings.Join(lines, "\n")
}

// ── CLI Commands ────────────────────────────────────────────────────

func (m WelcomeModel) renderCLICommands(w int) string {
	t := m.theme

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("CLI COMMANDS")

	cmdStyle := lipgloss.NewStyle().Foreground(t.Warning)

	cmds := []cmdEntry{
		{cmdStyle.Render("doey"), "Launch Doey session"},
		{cmdStyle.Render("doey add"), "Add a team window"},
		{cmdStyle.Render("doey task"), "Manage tasks"},
		{cmdStyle.Render("doey stop"), "Stop session"},
		{cmdStyle.Render("doey reload"), "Hot-reload (--workers)"},
		{cmdStyle.Render("doey list"), "List all projects"},
		{cmdStyle.Render("doey doctor"), "Check installation"},
		{cmdStyle.Render("doey test"), "Run E2E tests"},
		{cmdStyle.Render("doey version"), "Show version info"},
	}

	colW := w - 6

	var lines []string
	lines = append(lines, "")
	lines = append(lines, header)
	lines = append(lines, "")
	for i, c := range cmds {
		line := "  " + t.DottedLeader(c.name, c.desc, colW)
		lines = append(lines, zone.Mark(fmt.Sprintf("welcome-cli-%d", i), line))
	}
	lines = append(lines, "")

	return strings.Join(lines, "\n")
}
