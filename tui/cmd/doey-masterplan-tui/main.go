package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/planparse"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// ── Messages ──────────────────────────────────────────────────────────

type planReadMsg struct {
	content string
	mtime   time.Time
}
type statusReadMsg struct{ workers []workerStatus }
type researchReadMsg struct{ reports []researchReport }
type consensusReadMsg struct {
	present bool
	state   consensusState
	mtime   time.Time
}
type planTickMsg time.Time
type slowTickMsg time.Time

// ── Consensus state ───────────────────────────────────────────────────

// consensusState mirrors the key=value fields written to
// <plan-dir>/consensus.state by shell/masterplan-consensus.sh.
type consensusState struct {
	State            string // DRAFT | UNDER_REVIEW | REVISIONS_NEEDED | CONSENSUS | ESCALATED
	Round            string
	ArchitectVerdict string
	CriticVerdict    string
}

// ── Worker status ─────────────────────────────────────────────────────

type workerStatus struct {
	paneIdx int
	status  string
	task    string
}

// ── Research report ──────────────────────────────────────────────────

type researchReport struct {
	filename string
	summary  string
}

// ── Model ─────────────────────────────────────────────────────────────

type model struct {
	planPath         string
	runtimeDir       string
	goal             string
	teamWindow       int
	theme            styles.Theme
	viewport         viewport.Model
	planContent      string
	plan             *planparse.Plan
	renderedPlan     string
	lastRenderW      int
	lastChanged      time.Time
	planMtime        time.Time
	consensus        consensusState
	consensusPresent bool
	consensusMtime   time.Time
	workers          []workerStatus
	reports          []researchReport
	width            int
	height           int
	ready            bool
}

func initialModel(planPath, runtimeDir, goal string, teamWindow int) model {
	return model{
		planPath:   planPath,
		runtimeDir: runtimeDir,
		goal:       goal,
		teamWindow: teamWindow,
		theme:      styles.DefaultTheme(),
	}
}

// ── Commands ──────────────────────────────────────────────────────────

func readPlanCmd(path string) tea.Cmd {
	return func() tea.Msg {
		info, err := os.Stat(path)
		if err != nil {
			return planReadMsg{content: fmt.Sprintf("*Error reading plan: %s*", err)}
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return planReadMsg{content: fmt.Sprintf("*Error reading plan: %s*", err), mtime: info.ModTime()}
		}
		return planReadMsg{content: string(data), mtime: info.ModTime()}
	}
}

func readStatusCmd(runtimeDir string, teamWindow int) tea.Cmd {
	return func() tea.Msg {
		statuses := runtime.ReadPaneStatuses(runtimeDir)
		var workers []workerStatus
		for _, ps := range statuses {
			if ps.WindowIdx != teamWindow {
				continue
			}
			if ps.Role != "worker" {
				continue
			}
			workers = append(workers, workerStatus{
				paneIdx: ps.PaneIdx,
				status:  ps.Status,
				task:    ps.Task,
			})
		}
		sort.Slice(workers, func(i, j int) bool {
			return workers[i].paneIdx < workers[j].paneIdx
		})
		return statusReadMsg{workers: workers}
	}
}

func readResearchCmd(runtimeDir string) tea.Cmd {
	return func() tea.Msg {
		var reports []researchReport
		dirs, _ := filepath.Glob(filepath.Join(runtimeDir, "masterplan-*", "research"))
		for _, dir := range dirs {
			files, _ := filepath.Glob(filepath.Join(dir, "worker-*.md"))
			for _, f := range files {
				summary := ""
				data, err := os.ReadFile(f)
				if err == nil {
					lines := strings.SplitN(string(data), "\n", 2)
					if len(lines) > 0 {
						summary = strings.TrimSpace(lines[0])
						summary = strings.TrimLeft(summary, "# ")
					}
				}
				reports = append(reports, researchReport{
					filename: filepath.Base(f),
					summary:  summary,
				})
			}
		}
		return researchReadMsg{reports: reports}
	}
}

// readConsensusCmd reads <plan-dir>/consensus.state — a simple key=value
// file written by shell/masterplan-consensus.sh. Missing file is not an
// error; the badge is hidden until the file first appears.
func readConsensusCmd(planPath string) tea.Cmd {
	return func() tea.Msg {
		statePath := filepath.Join(filepath.Dir(planPath), "consensus.state")
		info, err := os.Stat(statePath)
		if err != nil {
			return consensusReadMsg{present: false}
		}
		data, err := os.ReadFile(statePath)
		if err != nil {
			return consensusReadMsg{present: false}
		}
		cs := parseConsensusState(string(data))
		return consensusReadMsg{present: true, state: cs, mtime: info.ModTime()}
	}
}

// parseConsensusState parses the key=value format written by the shell
// consensus helper. Unknown keys are ignored; values may be quoted.
func parseConsensusState(content string) consensusState {
	var cs consensusState
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		val = strings.Trim(val, `"'`)
		switch key {
		case "CONSENSUS_STATE", "STATE":
			cs.State = strings.ToUpper(val)
		case "ROUND":
			cs.Round = val
		case "ARCHITECT_VERDICT":
			cs.ArchitectVerdict = strings.ToUpper(val)
		case "CRITIC_VERDICT":
			cs.CriticVerdict = strings.ToUpper(val)
		}
	}
	return cs
}

// planTick drives the streaming re-read of the plan file. 400ms is fast
// enough to feel live for partial writes but cheap enough to avoid churn.
func planTickCmd() tea.Cmd {
	return tea.Tick(400*time.Millisecond, func(t time.Time) tea.Msg {
		return planTickMsg(t)
	})
}

// slowTick refreshes worker status and research reports less often.
func slowTickCmd() tea.Cmd {
	return tea.Tick(2*time.Second, func(t time.Time) tea.Msg {
		return slowTickMsg(t)
	})
}

// ── Tea interface ─────────────────────────────────────────────────────

func (m model) Init() tea.Cmd {
	return tea.Batch(
		readPlanCmd(m.planPath),
		readConsensusCmd(m.planPath),
		readStatusCmd(m.runtimeDir, m.teamWindow),
		readResearchCmd(m.runtimeDir),
		planTickCmd(),
		slowTickCmd(),
	)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

		headerH := m.headerHeight()
		statusH := m.statusBarHeight()
		vpH := m.height - headerH - statusH
		if vpH < 1 {
			vpH = 1
		}

		if !m.ready {
			m.viewport = viewport.New(m.width, vpH)
			m.viewport.SetContent(m.renderedPlan)
			m.ready = true
		} else {
			m.viewport.Width = m.width
			m.viewport.Height = vpH
		}

		if m.planContent != "" && m.width != m.lastRenderW {
			m.renderedPlan = m.renderPlan(m.width - 2)
			m.lastRenderW = m.width
			m.viewport.SetContent(m.renderedPlan)
		}

		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "g":
			m.viewport.GotoTop()
			return m, nil
		case "G":
			m.viewport.GotoBottom()
			return m, nil
		}
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd

	case planReadMsg:
		if msg.content != m.planContent {
			m.planContent = msg.content
			m.lastChanged = time.Now()
			m.planMtime = msg.mtime
			if plan, err := planparse.Parse([]byte(msg.content)); err == nil {
				m.plan = plan
			} else {
				m.plan = &planparse.Plan{Raw: msg.content}
			}
			m.renderedPlan = m.renderPlan(m.width - 2)
			m.lastRenderW = m.width
			if m.ready {
				m.viewport.SetContent(m.renderedPlan)
			}
		}
		return m, nil

	case statusReadMsg:
		m.workers = msg.workers
		return m, nil

	case researchReadMsg:
		m.reports = msg.reports
		return m, nil

	case consensusReadMsg:
		if !msg.present {
			if m.consensusPresent {
				m.consensusPresent = false
				m.consensus = consensusState{}
				m.consensusMtime = time.Time{}
			}
			return m, nil
		}
		if !msg.mtime.Equal(m.consensusMtime) {
			m.consensusPresent = true
			m.consensus = msg.state
			m.consensusMtime = msg.mtime
		}
		return m, nil

	case planTickMsg:
		return m, tea.Batch(
			readPlanCmd(m.planPath),
			readConsensusCmd(m.planPath),
			planTickCmd(),
		)

	case slowTickMsg:
		return m, tea.Batch(
			readStatusCmd(m.runtimeDir, m.teamWindow),
			readResearchCmd(m.runtimeDir),
			slowTickCmd(),
		)
	}

	return m, nil
}

func (m model) View() string {
	if !m.ready {
		return "Loading..."
	}

	header := m.renderHeader()
	statusBar := m.renderStatusBar()
	return header + m.viewport.View() + "\n" + statusBar
}

// ── Header ────────────────────────────────────────────────────────────

func (m model) headerHeight() int {
	h := 2 // plan file + status line
	if m.goal != "" {
		h++
	}
	return h
}

func (m model) renderHeader() string {
	th := m.theme
	var lines []string

	if m.goal != "" {
		lines = append(lines, th.Bold.Render(m.goal))
	}

	basename := filepath.Base(m.planPath)
	live := m.liveBadge()
	headerLine := th.Dim.Render("Plan: "+basename) + "  " + live
	if badge := m.consensusBadge(); badge != "" {
		headerLine += "  " + badge
	}
	lines = append(lines, headerLine)

	scrollPct := 0
	if m.viewport.TotalLineCount() > 0 {
		scrollPct = int(m.viewport.ScrollPercent() * 100)
	}
	lines = append(lines, th.Faint.Render(fmt.Sprintf("↑↓/j/k scroll · g/G top/bottom · q quit · %d%%", scrollPct)))

	return strings.Join(lines, "\n") + "\n"
}

// consensusBadge renders a short colored tag reflecting the current
// Planner/Architect/Critic review state. Returns "" when no consensus.state
// file has been written yet — the badge is hidden rather than crashing.
func (m model) consensusBadge() string {
	if !m.consensusPresent {
		return ""
	}
	th := m.theme
	state := m.consensus.State
	round := m.consensus.Round
	if round == "" {
		round = "1"
	}
	var fg lipgloss.AdaptiveColor
	var text string
	switch state {
	case "DRAFT", "":
		fg = th.Muted
		text = "DRAFT"
	case "UNDER_REVIEW":
		fg = th.Warning
		text = "REVIEW r" + round
	case "REVISIONS_NEEDED":
		fg = th.Highlight
		text = "REVISING r" + round
	case "CONSENSUS", "APPROVED":
		fg = th.Success
		text = "✓ CONSENSUS"
	case "ESCALATED":
		fg = th.Danger
		text = "⚠ ESCALATED"
	default:
		fg = th.Muted
		text = state
	}
	return lipgloss.NewStyle().Foreground(fg).Bold(true).Render(text)
}

// liveBadge returns a "● LIVE" pulse when the plan file was written in the
// last 2 seconds, otherwise a dim "○ idle" marker.
func (m model) liveBadge() string {
	th := m.theme
	if !m.lastChanged.IsZero() && time.Since(m.lastChanged) < 2*time.Second {
		return lipgloss.NewStyle().Foreground(th.Success).Bold(true).Render("● LIVE")
	}
	return th.Faint.Render("○ idle")
}

// ── Status bar ────────────────────────────────────────────────────────

func (m model) statusBarHeight() int {
	if len(m.workers) == 0 && len(m.reports) == 0 {
		return 1
	}
	h := 2
	rCount := len(m.reports)
	if rCount > 0 {
		h++
		if rCount > 5 {
			h += 5 + 1
		} else {
			h += rCount
		}
	}
	return h
}

func (m model) renderStatusBar() string {
	th := m.theme

	if len(m.workers) == 0 && len(m.reports) == 0 {
		return th.Faint.Render("No workers detected")
	}

	border := lipgloss.NewStyle().
		Foreground(th.Separator).
		Render(strings.Repeat("─", m.width))

	var out strings.Builder
	out.WriteString(border)
	out.WriteByte('\n')

	if len(m.workers) > 0 {
		var parts []string
		for _, w := range m.workers {
			label := fmt.Sprintf("W%d", w.paneIdx)
			st := w.status
			if st == "" {
				st = "?"
			}
			styled := colorStatus(st, th)
			entry := th.Dim.Render(label+": ") + styled
			if w.task != "" {
				entry += th.Faint.Render(" " + truncate(w.task, 20))
			}
			parts = append(parts, entry)
		}
		out.WriteString(strings.Join(parts, th.Faint.Render(" | ")))
		out.WriteByte('\n')
	} else {
		out.WriteString(th.Faint.Render("No workers detected"))
		out.WriteByte('\n')
	}

	if len(m.reports) > 0 {
		out.WriteString(th.Tag.Render("Research") + th.Faint.Render(fmt.Sprintf(" (%d reports)", len(m.reports))))
		out.WriteByte('\n')
		shown := len(m.reports)
		if shown > 5 {
			shown = 5
		}
		for i := 0; i < shown; i++ {
			r := m.reports[i]
			name := strings.TrimSuffix(r.filename, ".md")
			line := th.Dim.Render("  "+name+": ") + th.Body.Render(truncate(r.summary, m.width-len(name)-6))
			out.WriteString(line)
			out.WriteByte('\n')
		}
		if len(m.reports) > 5 {
			out.WriteString(th.Faint.Render(fmt.Sprintf("  … and %d more", len(m.reports)-5)))
			out.WriteByte('\n')
		}
	}

	return out.String()
}

func colorStatus(status string, th styles.Theme) string {
	upper := strings.ToUpper(status)
	switch upper {
	case "BUSY", "WORKING":
		return lipgloss.NewStyle().Foreground(th.Warning).Bold(true).Render(upper)
	case "READY":
		return lipgloss.NewStyle().Foreground(th.Success).Render(upper)
	case "FINISHED":
		return lipgloss.NewStyle().Foreground(th.Info).Render(upper)
	case "ERROR":
		return lipgloss.NewStyle().Foreground(th.Danger).Bold(true).Render(upper)
	case "RESERVED":
		return lipgloss.NewStyle().Foreground(th.Muted).Render(upper)
	default:
		return lipgloss.NewStyle().Foreground(th.Muted).Render(upper)
	}
}

func truncate(s string, max int) string {
	if max <= 1 {
		return ""
	}
	if len(s) <= max {
		return s
	}
	return s[:max-1] + "…"
}

// ── Plan rendering ────────────────────────────────────────────────────

// renderPlan chooses between the structured renderer and the glamour
// markdown fallback. The structured renderer is used whenever the parser
// gave us something to work with; otherwise we fall back to glamour so
// raw markdown still looks reasonable.
func (m model) renderPlan(width int) string {
	if width < 20 {
		width = 20
	}
	if m.plan != nil && m.plan.HasStructure() {
		return m.renderStructured(m.plan, width)
	}
	return renderMarkdown(m.planContent, width)
}

func renderMarkdown(content string, width int) string {
	if width < 20 {
		width = 20
	}
	renderer, err := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(width),
	)
	if err != nil {
		return content
	}
	out, err := renderer.Render(content)
	if err != nil {
		return content
	}
	return out
}

// renderStructured lays out a parsed plan using the Doey theme so it
// visually matches the rest of the TUI. Sections: Title → Goal → Phases
// → Deliverables → Risks → Success Criteria.
func (m model) renderStructured(plan *planparse.Plan, width int) string {
	th := m.theme
	var b strings.Builder

	if plan.Title != "" {
		b.WriteString(th.Title.Render(plan.Title))
		b.WriteString("\n")
	}

	if plan.Goal != "" {
		b.WriteString(th.SectionHeader.Render("Goal"))
		b.WriteString("\n")
		b.WriteString(th.Body.Render(wrap(plan.Goal, width-2)))
		b.WriteString("\n\n")
	}

	if plan.Context != "" {
		b.WriteString(th.SectionHeader.Render("Context"))
		b.WriteString("\n")
		b.WriteString(th.Body.Render(wrap(plan.Context, width-2)))
		b.WriteString("\n\n")
	}

	if len(plan.Phases) > 0 {
		b.WriteString(th.SectionHeader.Render("Phases"))
		b.WriteString("\n\n")
		for i, ph := range plan.Phases {
			b.WriteString(m.renderPhase(i+1, ph, width))
			b.WriteString("\n")
		}
	}

	if len(plan.Deliverables) > 0 {
		b.WriteString(th.SectionHeader.Render("Deliverables"))
		b.WriteString("\n")
		for _, d := range plan.Deliverables {
			b.WriteString("  ")
			b.WriteString(th.Tag.Render("•"))
			b.WriteString(" ")
			b.WriteString(th.Body.Render(d))
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}

	if len(plan.Risks) > 0 {
		b.WriteString(th.SectionHeader.Render("Risks"))
		b.WriteString("\n")
		for _, r := range plan.Risks {
			b.WriteString("  ")
			b.WriteString(lipgloss.NewStyle().Foreground(th.Warning).Bold(true).Render("!"))
			b.WriteString(" ")
			b.WriteString(th.Body.Render(r))
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}

	if len(plan.SuccessCriteria) > 0 {
		b.WriteString(th.SectionHeader.Render("Success Criteria"))
		b.WriteString("\n")
		for _, s := range plan.SuccessCriteria {
			b.WriteString("  ")
			b.WriteString(lipgloss.NewStyle().Foreground(th.Success).Render("✓"))
			b.WriteString(" ")
			b.WriteString(th.Body.Render(s))
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}

	return b.String()
}

// renderPhase renders a single phase card with a status badge, the phase
// title, optional prose body, and the step checklist.
func (m model) renderPhase(num int, ph planparse.Phase, width int) string {
	th := m.theme
	var b strings.Builder

	badge, titleStyle, bodyStyle := phaseStyles(ph.Status, th)

	header := fmt.Sprintf("Phase %d — %s", num, ph.Title)
	b.WriteString(titleStyle.Render(header))
	b.WriteString("  ")
	b.WriteString(badge)
	b.WriteString("\n")

	if ph.Body != "" {
		for _, line := range strings.Split(strings.TrimSpace(ph.Body), "\n") {
			b.WriteString("    ")
			b.WriteString(bodyStyle.Render(line))
			b.WriteString("\n")
		}
	}

	for _, s := range ph.Steps {
		var check string
		var lineStyle lipgloss.Style
		if s.Done {
			check = lipgloss.NewStyle().Foreground(th.Success).Render("[✓]")
			lineStyle = th.Dim
		} else if ph.Status == planparse.StatusInProgress {
			check = lipgloss.NewStyle().Foreground(th.Warning).Render("[•]")
			lineStyle = th.Body
		} else {
			check = th.Faint.Render("[ ]")
			lineStyle = bodyStyle
		}
		b.WriteString("    ")
		b.WriteString(check)
		b.WriteString(" ")
		b.WriteString(lineStyle.Render(s.Title))
		b.WriteString("\n")
	}

	return b.String()
}

// phaseStyles returns the badge, title style, and body style appropriate
// for a given phase status. Done phases are dimmed, in-progress are bold
// and foregrounded, planned are muted, failed are danger-colored.
func phaseStyles(s planparse.PhaseStatus, th styles.Theme) (string, lipgloss.Style, lipgloss.Style) {
	switch s {
	case planparse.StatusDone:
		badge := lipgloss.NewStyle().Foreground(th.Success).Bold(true).Render("✓ done")
		return badge, th.Dim.Bold(true), th.Faint
	case planparse.StatusInProgress:
		badge := lipgloss.NewStyle().Foreground(th.Warning).Bold(true).Render("⟳ in-progress")
		return badge, th.Bold, th.Body
	case planparse.StatusFailed:
		badge := lipgloss.NewStyle().Foreground(th.Danger).Bold(true).Render("✗ failed")
		return badge, lipgloss.NewStyle().Foreground(th.Danger).Bold(true), th.Body
	default:
		badge := th.Faint.Render("○ planned")
		return badge, th.Dim, th.Faint
	}
}

// wrap performs naive word-wrap at the given width. Plan strings are
// short so we prefer correctness + simplicity over fancy linebreaking.
func wrap(s string, width int) string {
	if width < 10 {
		width = 10
	}
	var out strings.Builder
	for i, para := range strings.Split(s, "\n") {
		if i > 0 {
			out.WriteByte('\n')
		}
		words := strings.Fields(para)
		line := 0
		for j, w := range words {
			if j > 0 {
				if line+1+len(w) > width {
					out.WriteByte('\n')
					line = 0
				} else {
					out.WriteByte(' ')
					line++
				}
			}
			out.WriteString(w)
			line += len(w)
		}
	}
	return out.String()
}

// ── Main ──────────────────────────────────────────────────────────────

func main() {
	planFile := flag.String("plan-file", "", "Path to the masterplan markdown file (required)")
	runtimeDir := flag.String("runtime-dir", "", "Doey runtime directory (required)")
	goal := flag.String("goal", "", "Goal text to display at top")
	teamWindow := flag.Int("team-window", 0, "Team window index for worker status")
	flag.Parse()

	if *planFile == "" || *runtimeDir == "" {
		fmt.Fprintf(os.Stderr, "Usage: doey-masterplan-tui --plan-file <path> --runtime-dir <path> [--goal <text>] [--team-window <int>]\n")
		os.Exit(1)
	}

	m := initialModel(*planFile, *runtimeDir, *goal, *teamWindow)
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
