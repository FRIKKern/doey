package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/styles"
)

// paneState tracks the observed status of a single tmux pane.
type paneState struct {
	name   string // e.g., "Boss", "Taskmaster", "Worker 1"
	group  string // e.g., "Dashboard", "Core Team", "Team 2"
	paneID string // safe form, e.g., "doey_doey_0_1"
	status string // "waiting", "booting", "ready"
}

// pollMsg carries the result of a status-directory scan.
type pollMsg struct {
	statuses map[string]string // paneID → STATUS value
}

// timeoutMsg signals the timeout has elapsed.
type timeoutMsg struct{}

// model is the root Bubble Tea model for the loading screen.
type model struct {
	theme     styles.Theme
	session   string
	runtime   string
	timeout   time.Duration
	width     int
	height    int
	ready     bool
	startTime time.Time
	spinner   spinner.Model
	panes     []paneState
	done      bool
	exitCode  int
}

// ── Pane discovery ─────────────────────────────────────────────────────

// readEnvFile parses a KEY=VALUE (or KEY="VALUE") file and returns a map.
func readEnvFile(path string) map[string]string {
	m := make(map[string]string)
	f, err := os.Open(path)
	if err != nil {
		return m
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		m[k] = strings.Trim(v, `"`)
	}
	return m
}

// safePaneID converts "doey-doey" + W + P to "doey_doey_W_P".
func safePaneID(session string, w, p string) string {
	safe := strings.NewReplacer("-", "_", ".", "_", ":", "_").Replace(session)
	return safe + "_" + w + "_" + p
}

// discoverPanes reads session.env and team_*.env to build the pane list.
func discoverPanes(runtimeDir, session string) []paneState {
	var panes []paneState

	// Fixed panes: Dashboard window (0)
	panes = append(panes,
		paneState{name: "Info Panel", group: "Dashboard", paneID: safePaneID(session, "0", "0")},
		paneState{name: "Boss", group: "Dashboard", paneID: safePaneID(session, "0", "1")},
	)

	// Fixed panes: Core Team window (1)
	panes = append(panes,
		paneState{name: "Taskmaster", group: "Core Team", paneID: safePaneID(session, "1", "0")},
		paneState{name: "Task Reviewer", group: "Core Team", paneID: safePaneID(session, "1", "1")},
		paneState{name: "Deployment", group: "Core Team", paneID: safePaneID(session, "1", "2")},
		paneState{name: "Doey Expert", group: "Core Team", paneID: safePaneID(session, "1", "3")},
	)

	// Dynamic team windows from session.env
	sessEnv := readEnvFile(filepath.Join(runtimeDir, "session.env"))
	teamWindows := strings.Split(sessEnv["TEAM_WINDOWS"], ",")
	for _, w := range teamWindows {
		w = strings.TrimSpace(w)
		if w == "" || w == "0" || w == "1" {
			continue
		}

		teamEnv := readEnvFile(filepath.Join(runtimeDir, fmt.Sprintf("team_%s.env", w)))
		groupName := teamEnv["TEAM_NAME"]
		if groupName == "" {
			groupName = "Team " + w
		}

		// Subtaskmaster at pane 0
		panes = append(panes, paneState{
			name:   "Subtaskmaster",
			group:  groupName,
			paneID: safePaneID(session, w, "0"),
		})

		// Workers
		workerPanes := strings.Split(teamEnv["WORKER_PANES"], ",")
		for i, p := range workerPanes {
			p = strings.TrimSpace(p)
			if p == "" {
				continue
			}
			panes = append(panes, paneState{
				name:   fmt.Sprintf("Worker %d", i+1),
				group:  groupName,
				paneID: safePaneID(session, w, p),
			})
		}
	}

	// Initialize all to "waiting"
	for i := range panes {
		panes[i].status = "waiting"
	}
	return panes
}

// ── Status polling ─────────────────────────────────────────────────────

// readStatuses scans {runtime}/status/*.status and returns paneID → STATUS.
func readStatuses(runtimeDir string) map[string]string {
	result := make(map[string]string)
	dir := filepath.Join(runtimeDir, "status")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return result
	}
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".status") {
			continue
		}
		paneID := strings.TrimSuffix(e.Name(), ".status")
		data, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			// Handle both "STATUS=X" and "STATUS: X" formats
			if strings.HasPrefix(line, "STATUS=") {
				result[paneID] = strings.TrimSpace(strings.TrimPrefix(line, "STATUS="))
				break
			}
			if strings.HasPrefix(line, "STATUS: ") {
				result[paneID] = strings.TrimSpace(strings.TrimPrefix(line, "STATUS: "))
				break
			}
		}
	}
	return result
}

func pollStatusCmd(runtimeDir string) tea.Cmd {
	return tea.Tick(500*time.Millisecond, func(_ time.Time) tea.Msg {
		return pollMsg{statuses: readStatuses(runtimeDir)}
	})
}

func timeoutCmd(d time.Duration) tea.Cmd {
	return tea.Tick(d, func(_ time.Time) tea.Msg {
		return timeoutMsg{}
	})
}

// ── Model ──────────────────────────────────────────────────────────────

func newModel(session, runtimeDir string, timeout time.Duration) model {
	theme := styles.DefaultTheme()
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(theme.Accent)

	panes := discoverPanes(runtimeDir, session)

	return model{
		theme:     theme,
		session:   session,
		runtime:   runtimeDir,
		timeout:   timeout,
		startTime: time.Now(),
		spinner:   sp,
		panes:     panes,
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(
		m.spinner.Tick,
		pollStatusCmd(m.runtime),
		timeoutCmd(m.timeout),
	)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.ready = true
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c", "esc":
			m.done = true
			m.exitCode = 1
			return m, tea.Quit
		}

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd

	case pollMsg:
		m.applyStatuses(msg.statuses)
		if m.allKeyPanesReady() {
			m.done = true
			m.exitCode = 0
			return m, tea.Quit
		}
		return m, pollStatusCmd(m.runtime)

	case timeoutMsg:
		m.done = true
		m.exitCode = 2
		return m, tea.Quit
	}
	return m, nil
}

// applyStatuses maps polled STATUS values to pane states.
func (m *model) applyStatuses(statuses map[string]string) {
	for i := range m.panes {
		raw, ok := statuses[m.panes[i].paneID]
		if !ok {
			continue
		}
		switch strings.ToUpper(raw) {
		case "READY", "BUSY", "WORKING", "FINISHED":
			m.panes[i].status = "ready"
		case "BOOTING":
			m.panes[i].status = "booting"
		case "ERROR":
			m.panes[i].status = "ready" // still counts as alive
		default:
			m.panes[i].status = "booting"
		}
	}
}

// allKeyPanesReady checks if the minimum set of panes are alive.
// Key panes: Boss (0.1) and Taskmaster (1.0) only — workers come online
// asynchronously after the loading screen exits and should not gate startup.
func (m *model) allKeyPanesReady() bool {
	bossReady := false
	taskmasterReady := false
	bossSuffix := "_0_1"
	tmSuffix := "_1_0"

	for _, p := range m.panes {
		if p.status != "ready" {
			continue
		}
		if strings.HasSuffix(p.paneID, bossSuffix) {
			bossReady = true
		}
		if strings.HasSuffix(p.paneID, tmSuffix) {
			taskmasterReady = true
		}
	}
	return bossReady && taskmasterReady
}

// ── View ───────────────────────────────────────────────────────────────

func (m model) View() string {
	if !m.ready {
		return ""
	}

	// Collect group names in order
	groupOrder := m.orderedGroups()

	// Build group boxes
	var boxes []string
	for _, g := range groupOrder {
		boxes = append(boxes, m.renderGroup(g))
	}

	// Title
	title := m.renderTitle()

	// Progress
	progress := m.renderProgress()

	// Hint
	hint := lipgloss.NewStyle().Foreground(m.theme.Muted).Faint(true).Render("Press q to skip")

	// Compose group boxes into a grid (2 columns)
	grid := m.layoutGrid(boxes)

	// Join all sections vertically
	content := lipgloss.JoinVertical(lipgloss.Center,
		"",
		title,
		"",
		grid,
		"",
		progress,
		"",
		hint,
	)

	// Center in terminal
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, content)
}

func (m model) renderTitle() string {
	letters := []string{"d", " ", "o", " ", "e", " ", "y"}
	titleStr := strings.Join(letters, "")
	titleStyle := lipgloss.NewStyle().
		Foreground(m.theme.Accent).
		Bold(true)

	inner := titleStyle.Render(titleStr)

	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(m.theme.Subtle).
		Padding(0, 3).
		Align(lipgloss.Center)

	maxW := m.width - 4
	if maxW > 50 {
		maxW = 50
	}
	if maxW < 20 {
		maxW = 20
	}
	box = box.Width(maxW)

	return box.Render(inner)
}

func (m model) orderedGroups() []string {
	seen := make(map[string]bool)
	var order []string
	for _, p := range m.panes {
		if !seen[p.group] {
			seen[p.group] = true
			order = append(order, p.group)
		}
	}
	return order
}

func (m model) renderGroup(group string) string {
	var panes []paneState
	for _, p := range m.panes {
		if p.group == group {
			panes = append(panes, p)
		}
	}

	// Determine if this group is actively spawning
	hasBooting := false
	allReady := true
	for _, p := range panes {
		if p.status == "booting" {
			hasBooting = true
		}
		if p.status != "ready" {
			allReady = false
		}
	}

	// Render pane rows
	var rows []string
	for _, p := range panes {
		rows = append(rows, m.renderPaneRow(p))
	}
	body := strings.Join(rows, "\n")

	// Box styling
	borderColor := m.theme.Subtle
	if hasBooting {
		borderColor = m.theme.Primary
	}
	if allReady {
		borderColor = m.theme.Success
	}

	colW := m.groupWidth()

	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(borderColor).
		Padding(0, 1).
		Width(colW)

	// Title in border top
	titleStyle := lipgloss.NewStyle().
		Foreground(borderColor).
		Bold(true)

	header := titleStyle.Render(group)

	return box.Render(header + "\n" + body)
}

func (m model) groupWidth() int {
	w := (m.width - 8) / 2
	if w > 30 {
		w = 30
	}
	if w < 22 {
		w = 22
	}
	return w
}

func (m model) renderPaneRow(p paneState) string {
	// Status indicator
	var indicator string
	switch p.status {
	case "ready":
		indicator = lipgloss.NewStyle().Foreground(m.theme.Success).Render("●")
	case "booting":
		indicator = lipgloss.NewStyle().Foreground(m.theme.Warning).Render("◐")
	default: // waiting
		indicator = lipgloss.NewStyle().Foreground(m.theme.Muted).Render("○")
	}

	// Name — muted until ready
	nameStyle := lipgloss.NewStyle().Foreground(m.theme.Text)
	if p.status != "ready" {
		nameStyle = nameStyle.Foreground(m.theme.Muted)
	}

	// Right-side indicator
	var trail string
	switch p.status {
	case "ready":
		trail = lipgloss.NewStyle().Foreground(m.theme.Success).Render("✓")
	default:
		trail = m.spinner.View()
	}

	// Pad name to fixed width for alignment
	nameW := m.groupWidth() - 10
	if nameW < 10 {
		nameW = 10
	}
	name := nameStyle.Width(nameW).Render(p.name)

	return fmt.Sprintf("  %s %s %s", indicator, name, trail)
}

func (m model) renderProgress() string {
	readyCount := 0
	for _, p := range m.panes {
		if p.status == "ready" {
			readyCount++
		}
	}
	total := len(m.panes)
	if total == 0 {
		total = 1
	}

	// Label
	var label string
	if readyCount == total {
		label = "All systems ready"
	} else {
		elapsed := time.Since(m.startTime).Round(time.Second)
		label = fmt.Sprintf("Spawning teams... %s", elapsed)
	}
	labelStyled := lipgloss.NewStyle().Foreground(m.theme.Text).Render(label)

	// Progress bar
	barWidth := 20
	filled := barWidth * readyCount / total
	empty := barWidth - filled

	filledStr := lipgloss.NewStyle().Foreground(m.theme.Success).Render(strings.Repeat("█", filled))
	emptyStr := lipgloss.NewStyle().Foreground(m.theme.Subtle).Render(strings.Repeat("░", empty))

	counter := lipgloss.NewStyle().Foreground(m.theme.Muted).Render(
		fmt.Sprintf("%d/%d", readyCount, total),
	)

	sp := m.spinner.View()

	return fmt.Sprintf("  %s  %s%s  %s  %s", labelStyled, filledStr, emptyStr, counter, sp)
}

func (m model) layoutGrid(boxes []string) string {
	if len(boxes) == 0 {
		return ""
	}

	// For small terminals or few boxes, single column
	if m.width < 60 || len(boxes) == 1 {
		return lipgloss.JoinVertical(lipgloss.Center, boxes...)
	}

	// Two-column grid
	var rows []string
	for i := 0; i < len(boxes); i += 2 {
		if i+1 < len(boxes) {
			row := lipgloss.JoinHorizontal(lipgloss.Top, boxes[i], "  ", boxes[i+1])
			rows = append(rows, row)
		} else {
			rows = append(rows, boxes[i])
		}
	}
	return lipgloss.JoinVertical(lipgloss.Center, rows...)
}

// ── Main ───────────────────────────────────────────────────────────────

func main() {
	session := flag.String("session", "", "tmux session name (e.g., doey-myproject)")
	runtimeDir := flag.String("runtime", "", "runtime directory (e.g., /tmp/doey/myproject)")
	timeout := flag.Int("timeout", 30, "max wait time in seconds")
	flag.Parse()

	if *session == "" || *runtimeDir == "" {
		fmt.Fprintf(os.Stderr, "Usage: doey-loading --session <name> --runtime <dir> [--timeout <seconds>]\n")
		os.Exit(1)
	}

	m := newModel(*session, *runtimeDir, time.Duration(*timeout)*time.Second)

	p := tea.NewProgram(m, tea.WithAltScreen())
	finalModel, err := p.Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	fm := finalModel.(model)
	os.Exit(fm.exitCode)
}

