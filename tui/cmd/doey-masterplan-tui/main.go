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

	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// ── Messages ──────────────────────────────────────────────────────────

type planReadMsg struct{ content string }
type statusReadMsg struct{ workers []workerStatus }
type researchReadMsg struct{ reports []researchReport }
type tickMsg time.Time

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
	planPath    string
	runtimeDir  string
	goal        string
	teamWindow  int
	theme       styles.Theme
	viewport    viewport.Model
	planContent  string
	renderedPlan string
	lastRenderW  int
	workers      []workerStatus
	reports      []researchReport
	width        int
	height       int
	ready        bool
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
		data, err := os.ReadFile(path)
		if err != nil {
			return planReadMsg{content: fmt.Sprintf("*Error reading plan: %s*", err)}
		}
		return planReadMsg{content: string(data)}
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
						// Strip leading markdown heading markers
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

func nextTickCmd() tea.Cmd {
	return tea.Tick(2*time.Second, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

// ── Tea interface ─────────────────────────────────────────────────────

func (m model) Init() tea.Cmd {
	return tea.Batch(
		readPlanCmd(m.planPath),
		readStatusCmd(m.runtimeDir, m.teamWindow),
		readResearchCmd(m.runtimeDir),
		nextTickCmd(),
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

		// Re-render if width changed
		if m.planContent != "" && m.width != m.lastRenderW {
			m.renderedPlan = renderMarkdown(m.planContent, m.width-4)
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
			w := m.width - 4
			if w < 20 {
				w = 20
			}
			m.renderedPlan = renderMarkdown(m.planContent, w)
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

	case tickMsg:
		return m, tea.Batch(
			readPlanCmd(m.planPath),
			readStatusCmd(m.runtimeDir, m.teamWindow),
			readResearchCmd(m.runtimeDir),
			nextTickCmd(),
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
	lines = append(lines, th.Dim.Render("Plan: "+basename))

	scrollPct := 0
	if m.viewport.TotalLineCount() > 0 {
		scrollPct = int(m.viewport.ScrollPercent() * 100)
	}
	lines = append(lines, th.Faint.Render(fmt.Sprintf("↑↓/j/k scroll · q quit · %d%%", scrollPct)))

	return strings.Join(lines, "\n") + "\n"
}

// ── Status bar ────────────────────────────────────────────────────────

func (m model) statusBarHeight() int {
	if len(m.workers) == 0 && len(m.reports) == 0 {
		return 1 // "No workers detected"
	}
	h := 2 // separator + worker status line
	// Research reports
	rCount := len(m.reports)
	if rCount > 0 {
		h++ // "Research (N reports)" header
		if rCount > 5 {
			h += 5 + 1 // 5 shown + overflow line
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

	// Worker status line
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
				entry += th.Faint.Render(" "+truncate(w.task, 20))
			}
			parts = append(parts, entry)
		}
		out.WriteString(strings.Join(parts, th.Faint.Render(" | ")))
		out.WriteByte('\n')
	} else {
		out.WriteString(th.Faint.Render("No workers detected"))
		out.WriteByte('\n')
	}

	// Research reports section
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
	if len(s) <= max {
		return s
	}
	return s[:max-1] + "…"
}

// ── Markdown rendering ────────────────────────────────────────────────

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
