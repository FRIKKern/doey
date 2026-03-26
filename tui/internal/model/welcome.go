package model

import (
	"fmt"
	"math/rand"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// WelcomeModel renders the home/welcome tab with ASCII art, onboarding, and
// command reference — the soul of the bash dashboard.
type WelcomeModel struct {
	snapshot runtime.Snapshot
	theme    styles.Theme
	width    int
	height   int
}

// NewWelcomeModel creates the welcome panel.
func NewWelcomeModel() WelcomeModel {
	return WelcomeModel{
		theme: styles.DefaultTheme(),
	}
}

// Init is a no-op.
func (m WelcomeModel) Init() tea.Cmd { return nil }

// Update handles messages relevant to the welcome view.
func (m WelcomeModel) Update(msg tea.Msg) (WelcomeModel, tea.Cmd) {
	return m, nil
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

// View renders the full welcome screen.
func (m WelcomeModel) View() string {
	w := m.width
	if w < 40 {
		w = 40
	}

	var sections []string

	sections = append(sections, m.renderBanner(w))
	sections = append(sections, m.renderStatsBar(w))
	if ts := m.renderTeamStatus(w); ts != "" {
		sections = append(sections, ts)
	}
	sections = append(sections, m.renderHowToUse())
	sections = append(sections, m.renderSlashCommands(w))
	sections = append(sections, m.renderCLICommands(w))

	content := strings.Join(sections, "\n")

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Render(content)
}

// ── ASCII Art Banner ────────────────────────────────────────────────

// blockFont maps characters to 6-row block-letter representations.
var blockFont = map[byte][6]string{
	'A': {" █████╗ ", "██╔══██╗", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"},
	'B': {"██████╗ ", "██╔══██╗", "██████╔╝", "██╔══██╗", "██████╔╝", "╚═════╝ "},
	'C': {" ██████╗", "██╔════╝", "██║     ", "██║     ", "╚██████╗", " ╚═════╝"},
	'D': {"██████╗ ", "██╔══██╗", "██║  ██║", "██║  ██║", "██████╔╝", "╚═════╝ "},
	'E': {"███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "███████╗", "╚══════╝"},
	'F': {"███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "██║     ", "╚═╝     "},
	'G': {" ██████╗ ", "██╔════╝ ", "██║  ███╗", "██║   ██║", "╚██████╔╝", " ╚═════╝ "},
	'H': {"██╗  ██╗", "██║  ██║", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"},
	'I': {"██╗", "██║", "██║", "██║", "██║", "╚═╝"},
	'J': {"     ██╗", "     ██║", "     ██║", "██   ██║", "╚█████╔╝", " ╚════╝ "},
	'K': {"██╗  ██╗", "██║ ██╔╝", "█████╔╝ ", "██╔═██╗ ", "██║  ██╗", "╚═╝  ╚═╝"},
	'L': {"██╗     ", "██║     ", "██║     ", "██║     ", "███████╗", "╚══════╝"},
	'M': {"███╗   ███╗", "████╗ ████║", "██╔████╔██║", "██║╚██╔╝██║", "██║ ╚═╝ ██║", "╚═╝     ╚═╝"},
	'N': {"███╗   ██╗", "████╗  ██║", "██╔██╗ ██║", "██║╚██╗██║", "██║ ╚████║", "╚═╝  ╚═══╝"},
	'O': {" ██████╗ ", "██╔═══██╗", "██║   ██║", "██║   ██║", "╚██████╔╝", " ╚═════╝ "},
	'P': {"██████╗ ", "██╔══██╗", "██████╔╝", "██╔═══╝ ", "██║     ", "╚═╝     "},
	'Q': {" ██████╗  ", "██╔═══██╗ ", "██║   ██║ ", "██║▄▄ ██║ ", "╚██████╔╝ ", " ╚══▀▀═╝  "},
	'R': {"██████╗ ", "██╔══██╗", "██████╔╝", "██╔══██╗", "██║  ██║", "╚═╝  ╚═╝"},
	'S': {"███████╗", "██╔════╝", "███████╗", "╚════██║", "███████║", "╚══════╝"},
	'T': {"████████╗", "╚══██╔══╝", "   ██║   ", "   ██║   ", "   ██║   ", "   ╚═╝   "},
	'U': {"██╗   ██╗", "██║   ██║", "██║   ██║", "██║   ██║", "╚██████╔╝", " ╚═════╝ "},
	'V': {"██╗   ██╗", "██║   ██║", "██║   ██║", "╚██╗ ██╔╝", " ╚████╔╝ ", "  ╚═══╝  "},
	'W': {"██╗    ██╗", "██║    ██║", "██║ █╗ ██║", "██║███╗██║", "╚███╔███╔╝", " ╚══╝╚══╝ "},
	'X': {"██╗  ██╗", "╚██╗██╔╝", " ╚███╔╝ ", " ██╔██╗ ", "██╔╝ ██╗", "╚═╝  ╚═╝"},
	'Y': {"██╗   ██╗", "╚██╗ ██╔╝", " ╚████╔╝ ", "  ╚██╔╝  ", "   ██║   ", "   ╚═╝   "},
	'Z': {"███████╗", "╚════██║", "  ███╔╝ ", " ███╔╝  ", "███████╗", "╚══════╝"},
	'0': {" ██████╗ ", "██╔═══██╗", "██║   ██║", "██║   ██║", "╚██████╔╝", " ╚═════╝ "},
	'1': {" ██╗", "███║", "╚██║", " ██║", " ██║", " ╚═╝"},
	'2': {"██████╗ ", "╚════██╗", " █████╔╝", "██╔═══╝ ", "███████╗", "╚══════╝"},
	'3': {"██████╗ ", "╚════██╗", " █████╔╝", " ╚═══██╗", "██████╔╝", "╚═════╝ "},
	'4': {"██╗  ██╗", "██║  ██║", "███████║", "╚════██║", "     ██║", "     ╚═╝"},
	'5': {"███████╗", "██╔════╝", "███████╗", "╚════██║", "███████║", "╚══════╝"},
	'6': {" ██████╗ ", "██╔════╝ ", "███████╗ ", "██╔═══██╗", "╚██████╔╝", " ╚═════╝ "},
	'7': {"███████╗", "╚════██║", "    ██╔╝", "   ██╔╝ ", "   ██║  ", "   ╚═╝  "},
	'8': {" █████╗ ", "██╔══██╗", "╚█████╔╝", "██╔══██╗", "╚█████╔╝", " ╚════╝ "},
	'9': {" █████╗ ", "██╔══██╗", "╚██████║", " ╚═══██║", " █████╔╝", " ╚════╝ "},
	'-': {"        ", "        ", "███████╗", "╚══════╝", "        ", "        "},
	'.': {"   ", "   ", "   ", "   ", "██╗", "╚═╝"},
	'_': {"        ", "        ", "        ", "        ", "███████╗", "╚══════╝"},
	' ': {"   ", "   ", "   ", "   ", "   ", "   "},
}

// bannerColors are the 6 colors the title randomly picks from.
var bannerColors = []lipgloss.AdaptiveColor{
	{Light: "#0891B2", Dark: "#06B6D4"}, // cyan (primary)
	{Light: "#16A34A", Dark: "#22C55E"}, // green
	{Light: "#D97706", Dark: "#F59E0B"}, // yellow/amber
	{Light: "#9333EA", Dark: "#A855F7"}, // magenta/purple
	{Light: "#DC2626", Dark: "#EF4444"}, // red
	{Light: "#111827", Dark: "#F9FAFB"}, // white/text
}

func (m WelcomeModel) renderBanner(maxWidth int) string {
	name := strings.ToUpper(m.snapshot.Session.ProjectName)
	if name == "" {
		name = "DOEY"
	}
	// Cap at 9 characters to fit small terminals
	if len(name) > 9 {
		name = name[:9]
	}

	// Build 6 rows of block text
	var rows [6]string
	for i := 0; i < len(name); i++ {
		ch := name[i]
		glyph, ok := blockFont[ch]
		if !ok {
			glyph = blockFont[' ']
		}
		for r := 0; r < 6; r++ {
			rows[r] += glyph[r] + " "
		}
	}

	// Pick a random color
	color := bannerColors[rand.Intn(len(bannerColors))]
	style := lipgloss.NewStyle().
		Foreground(color).
		Bold(true).
		PaddingLeft(4)

	var lines []string
	lines = append(lines, "") // top margin
	for _, row := range rows {
		lines = append(lines, style.Render(row))
	}
	lines = append(lines, "") // bottom margin

	return strings.Join(lines, "\n")
}

// ── Stats Bar ───────────────────────────────────────────────────────

func (m WelcomeModel) renderStatsBar(w int) string {
	t := m.theme

	thickRule := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Render(strings.Repeat("═", w))

	sep := lipgloss.NewStyle().Foreground(t.Muted).Render(" · ")
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(t.Text)
	valueStyle := lipgloss.NewStyle().Foreground(t.Muted)

	projectName := m.snapshot.Session.ProjectName
	if projectName == "" {
		projectName = "—"
	}
	sessionName := m.snapshot.Session.SessionName
	if sessionName == "" {
		sessionName = "—"
	}
	teamCount := len(m.snapshot.Teams)
	uptime := formatDuration(m.snapshot.Uptime)

	line := "  " +
		labelStyle.Render("PROJECT") + " " + valueStyle.Render(projectName) + sep +
		labelStyle.Render("SESSION") + " " + valueStyle.Render(sessionName) + sep +
		labelStyle.Render("UPTIME") + " " + valueStyle.Render(uptime) + sep +
		labelStyle.Render("TEAMS") + " " + valueStyle.Render(fmt.Sprintf("%d", teamCount))

	return thickRule + "\n" + line + "\n" + thickRule + "\n"
}

// ── Team Status ─────────────────────────────────────────────────────

func (m WelcomeModel) renderTeamStatus(w int) string {
	if len(m.snapshot.Teams) == 0 {
		return ""
	}

	t := m.theme
	header := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		PaddingLeft(2).
		Render("TEAM STATUS")

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
			badge = lipgloss.NewStyle().Foreground(t.Warning).Bold(true).Render(" [F]")
		} else if tc.WorktreeDir != "" {
			badge = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render(" [wt]")
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
		lines = append(lines, teamLine)
	}

	lines = append(lines, "")
	return strings.Join(lines, "\n")
}

// ── How To Use Doey ─────────────────────────────────────────────────

func (m WelcomeModel) renderHowToUse() string {
	t := m.theme

	header := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		PaddingLeft(2).
		Render("HOW TO USE DOEY")

	numStyle := lipgloss.NewStyle().Bold(true).Foreground(t.Text)
	cyanStyle := lipgloss.NewStyle().Foreground(t.Primary)
	yellowStyle := lipgloss.NewStyle().Foreground(t.Warning)
	greenStyle := lipgloss.NewStyle().Foreground(t.Success)
	dimStyle := lipgloss.NewStyle().Foreground(t.Muted)

	steps := []string{
		fmt.Sprintf("  %s Talk to the %s (right pane\n     in this window) %s describe your task and\n     it routes work to the right team.",
			numStyle.Render("1."),
			cyanStyle.Render("Session Manager"),
			dimStyle.Render("—")),
		fmt.Sprintf("  %s Switch to a team window (%s) and\n     talk to the Window Manager directly.",
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
	for _, step := range steps {
		lines = append(lines, step)
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

	header := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		PaddingLeft(2).
		Render("SLASH COMMANDS")

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

	// Column width for dotted leaders
	colW := w - 6
	twoCol := w > 100
	if twoCol {
		colW = (w - 8) / 2
	}

	var lines []string
	lines = append(lines, "")
	lines = append(lines, header)
	lines = append(lines, "")

	for _, g := range groups {
		lines = append(lines, "  "+g.style.Render(g.label))
		if twoCol {
			for i := 0; i < len(g.cmds); i += 2 {
				left := dottedLeader(g.cmds[i].name, g.cmds[i].desc, colW, t)
				right := ""
				if i+1 < len(g.cmds) {
					right = "  " + dottedLeader(g.cmds[i+1].name, g.cmds[i+1].desc, colW, t)
				}
				lines = append(lines, "  "+left+right)
			}
		} else {
			for _, c := range g.cmds {
				lines = append(lines, "  "+dottedLeader(c.name, c.desc, colW, t))
			}
		}
		lines = append(lines, "")
	}

	return strings.Join(lines, "\n")
}

// ── CLI Commands ────────────────────────────────────────────────────

func (m WelcomeModel) renderCLICommands(w int) string {
	t := m.theme

	header := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		PaddingLeft(2).
		Render("CLI COMMANDS")

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
	for _, c := range cmds {
		lines = append(lines, "  "+dottedLeader(c.name, c.desc, colW, t))
	}
	lines = append(lines, "")

	return strings.Join(lines, "\n")
}

// ── Helpers ─────────────────────────────────────────────────────────

// visibleLen returns the printed width of a string, stripping ANSI escapes.
func visibleLen(s string) int {
	return lipgloss.Width(s)
}

// dottedLeader renders "name .... desc" with dots filling the gap.
func dottedLeader(name, desc string, maxW int, t styles.Theme) string {
	nameW := visibleLen(name)
	descW := visibleLen(desc)
	dotsNeeded := maxW - nameW - descW - 2
	if dotsNeeded < 2 {
		dotsNeeded = 2
	}
	dots := lipgloss.NewStyle().Faint(true).Foreground(t.Muted).Render(strings.Repeat(".", dotsNeeded))
	return name + " " + dots + " " + desc
}
