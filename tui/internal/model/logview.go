package model

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
	zone "github.com/lrstanley/bubblezone"
)

const maxLogLines = 500

// logEntry is a flattened, display-ready result entry.
type logEntry struct {
	Timestamp int64
	Pane      string
	Title     string
	Status    string
	ToolCalls int
	Output    string // first 2 lines of LastOutput
	Files     string // comma-joined changed files (truncated)
}

// LogViewModel displays a streaming log of worker results with auto-scroll.
type LogViewModel struct {
	entries    []logEntry
	theme      styles.Theme
	cursor     int
	offset     int
	autoScroll bool
	detailMode bool
	keyMap     keys.KeyMap
	width      int
	height     int
	focused    bool
}

// NewLogViewModel creates a log view panel with auto-scroll enabled.
func NewLogViewModel(theme styles.Theme) LogViewModel {
	return LogViewModel{
		theme:      theme,
		autoScroll: true,
		keyMap:     keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the log sub-model.
func (m LogViewModel) Init() tea.Cmd { return nil }

// SetSize updates the panel dimensions.
func (m *LogViewModel) SetSize(w, h int) { m.width = w; m.height = h }

// SetFocused toggles focus state.
func (m *LogViewModel) SetFocused(focused bool) { m.focused = focused }

// SetSnapshot rebuilds the log entries from the snapshot's Results map.
func (m *LogViewModel) SetSnapshot(snap runtime.Snapshot) {
	m.entries = m.entries[:0]
	for _, res := range snap.Results {
		output := firstNLines(res.LastOutput, 2)
		files := ""
		if len(res.FilesChanged) > 0 {
			files = strings.Join(res.FilesChanged, ", ")
			if len(files) > 60 {
				files = files[:57] + "..."
			}
		}
		m.entries = append(m.entries, logEntry{
			Timestamp: res.Timestamp,
			Pane:      res.Pane,
			Title:     res.Title,
			Status:    res.Status,
			ToolCalls: res.ToolCalls,
			Output:    output,
			Files:     files,
		})
	}
	sort.Slice(m.entries, func(i, j int) bool {
		return m.entries[i].Timestamp > m.entries[j].Timestamp
	})
	if len(m.entries) > maxLogLines {
		m.entries = m.entries[:maxLogLines]
	}
	if m.autoScroll && !m.detailMode {
		m.cursor = 0
		m.offset = 0
	}
}

// Update handles navigation keys and mouse events.
func (m LogViewModel) Update(msg tea.Msg) (LogViewModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if m.detailMode {
			if key.Matches(msg, m.keyMap.Back) {
				m.detailMode = false
			}
			return m, nil
		}
		return m.updateList(msg), nil
	case tea.MouseMsg:
		return m.updateMouse(msg), nil
	}
	return m, nil
}

func (m LogViewModel) updateList(msg tea.KeyMsg) LogViewModel {
	total := len(m.entries)
	switch {
	case key.Matches(msg, m.keyMap.Up):
		m.autoScroll = false
		if m.cursor > 0 {
			m.cursor--
		}
		m.ensureVisible()
	case key.Matches(msg, m.keyMap.Down):
		if m.cursor < total-1 {
			m.cursor++
		}
		if m.cursor == 0 {
			m.autoScroll = true
		}
		m.ensureVisible()
	case key.Matches(msg, m.keyMap.Select):
		if total > 0 {
			m.detailMode = true
		}
	default:
		switch msg.String() {
		case "G":
			m.autoScroll = true
			m.cursor = 0
			m.offset = 0
		case "f":
			m.autoScroll = !m.autoScroll
			if m.autoScroll {
				m.cursor = 0
				m.offset = 0
			}
		}
	}
	return m
}

func (m LogViewModel) updateMouse(msg tea.MouseMsg) LogViewModel {
	total := len(m.entries)

	// Wheel events fire on press, not release
	if msg.Button == tea.MouseButtonWheelUp {
		m.autoScroll = false
		if m.cursor > 0 {
			m.cursor--
		}
		m.ensureVisible()
		return m
	}
	if msg.Button == tea.MouseButtonWheelDown {
		if m.cursor < total-1 {
			m.cursor++
		}
		if m.cursor == 0 {
			m.autoScroll = true
		}
		m.ensureVisible()
		return m
	}

	// All other mouse interactions on release only to prevent double-fire
	if msg.Action != tea.MouseActionRelease {
		return m
	}

	if m.detailMode {
		// Back button in detail view
		if zone.Get("log-back").InBounds(msg) {
			m.detailMode = false
		}
		return m
	}

	// Follow toggle
	if zone.Get("log-follow-toggle").InBounds(msg) {
		m.autoScroll = !m.autoScroll
		if m.autoScroll {
			m.cursor = 0
			m.offset = 0
		}
		return m
	}

	// Click on log entries
	viewH := m.viewportHeight()
	end := m.offset + viewH
	if end > total {
		end = total
	}
	for i := m.offset; i < end; i++ {
		if zone.Get(fmt.Sprintf("log-%d", i)).InBounds(msg) {
			if m.cursor == i {
				// Click on already-selected entry opens detail
				m.detailMode = true
			} else {
				m.cursor = i
				m.autoScroll = false
			}
			return m
		}
	}

	return m
}

func (m *LogViewModel) ensureVisible() {
	viewH := m.viewportHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+viewH {
		m.offset = m.cursor - viewH + 1
	}
}

func (m LogViewModel) viewportHeight() int {
	h := m.height - 5
	if h < 1 {
		h = 1
	}
	return h
}

// View renders the log panel (list or detail mode).
func (m LogViewModel) View() string {
	if m.detailMode {
		return m.viewDetail()
	}
	return m.viewList()
}

func (m LogViewModel) viewList() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("WORKER LOGS")
	rule := styles.ThinSeparator(t, w)

	if len(m.entries) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).PaddingTop(1).
			Render("No worker results yet")
		content := header + "\n" + rule + "\n" + empty
		return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
	}

	// Summary bar — colored counts per status
	busy, finished, errored := 0, 0, 0
	for _, e := range m.entries {
		switch e.Status {
		case "BUSY":
			busy++
		case "FINISHED":
			finished++
		case "ERROR":
			errored++
		}
	}
	summary := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(fmt.Sprintf("%d results", len(m.entries)))
	var counts []string
	if finished > 0 {
		counts = append(counts, lipgloss.NewStyle().Foreground(t.Success).Bold(true).
			Render(fmt.Sprintf("\u2714 %d done", finished)))
	}
	if busy > 0 {
		counts = append(counts, lipgloss.NewStyle().Foreground(t.Warning).Bold(true).
			Render(fmt.Sprintf("\u25CF %d busy", busy)))
	}
	if errored > 0 {
		counts = append(counts, lipgloss.NewStyle().Foreground(t.Danger).Bold(true).
			Render(fmt.Sprintf("\u2717 %d error", errored)))
	}
	if len(counts) > 0 {
		summary += "  " + strings.Join(counts, t.Faint.Render(" \u00b7 "))
	}

	scrollInd := ""
	if m.autoScroll {
		scrollInd = lipgloss.NewStyle().Foreground(t.Success).Bold(true).Render(" \u25CF LIVE")
	} else {
		scrollInd = lipgloss.NewStyle().Foreground(t.Warning).Render(" \u25CB PAUSED")
	}
	scrollInd = zone.Mark("log-follow-toggle", scrollInd)

	summaryRule := styles.ThinSeparator(t, w)

	// Render visible entries
	viewH := m.viewportHeight()
	selectedBg := lipgloss.AdaptiveColor{Light: "#EFF6FF", Dark: "#1E3A5F"}
	selectedBorder := lipgloss.NewStyle().
		Foreground(t.Primary).
		Render("\u25B6 ")
	normalIndent := "  "

	var lines []string
	end := m.offset + viewH
	if end > len(m.entries) {
		end = len(m.entries)
	}
	for i := m.offset; i < end; i++ {
		line := m.renderLine(m.entries[i], w-4)
		if m.focused && i == m.cursor {
			line = selectedBorder + lipgloss.NewStyle().
				Background(selectedBg).
				Width(w - 6).
				Render(line)
		} else {
			line = normalIndent + line
		}
		line = zone.Mark(fmt.Sprintf("log-%d", i), line)
		lines = append(lines, line)
	}

	body := strings.Join(lines, "\n")

	hint := ""
	if m.focused {
		hint = t.Faint.Copy().Padding(1, 3).
			Render("enter = detail  f = follow  G = go to top")
	}

	content := header + "\n" + rule + "\n" + summary + scrollInd + "\n" + summaryRule + "\n" + body + "\n" + hint
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}

func (m LogViewModel) renderLine(e logEntry, maxW int) string {
	t := m.theme

	// Timestamp — subtle, non-distracting
	ts := styles.LogTimestamp(t, time.Unix(e.Timestamp, 0).Format("15:04:05"))

	// Status — colored text badge
	badge := lipgloss.NewStyle().
		Foreground(m.statusColor(e.Status)).
		Bold(true).
		Width(9).
		Render(e.Status)

	// Pane ID — muted label with padding
	pane := styles.LogPaneLabel(t, e.Pane)

	// Tool calls — faint metadata
	tools := t.Faint.Render(fmt.Sprintf("%dt", e.ToolCalls))

	prefix := ts + " " + badge + " " + pane + " " + tools + " "
	prefixW := lipgloss.Width(prefix)

	// Body text — title or first output line
	maxBody := maxW - prefixW - 6
	body := firstLogLine(e.Output)
	if e.Title != "" {
		body = e.Title
	}
	if maxBody > 0 && len(body) > maxBody {
		body = body[:maxBody-1] + "\u2026"
	}

	return prefix + t.LogEntry.Render(body)
}

func (m LogViewModel) statusColor(status string) lipgloss.AdaptiveColor {
	t := m.theme
	switch status {
	case "BUSY":
		return t.Primary
	case "FINISHED":
		return t.Success
	case "ERROR":
		return t.Danger
	default:
		return t.Muted
	}
}

func (m LogViewModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}
	if m.cursor < 0 || m.cursor >= len(m.entries) {
		m.detailMode = false
		return m.viewList()
	}

	e := m.entries[m.cursor]

	// Header with pane label
	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render("WORKER LOGS") +
		t.Faint.Render(" \u2014 ") +
		styles.LogPaneLabel(t, e.Pane)
	rule := styles.ThinSeparator(t, w)
	backHint := zone.Mark("log-back", t.Faint.Copy().PaddingLeft(3).
		Render("\u2190 esc to go back"))

	// Detail fields with section header styling
	labelStyle := t.SectionHeader.Copy().Width(12)
	valueStyle := t.Body

	var fields []string
	fields = append(fields, labelStyle.Render("Time")+
		styles.LogTimestamp(t, time.Unix(e.Timestamp, 0).Format("2006-01-02 15:04:05")))
	fields = append(fields, labelStyle.Render("Pane")+valueStyle.Render(e.Pane))
	fields = append(fields, labelStyle.Render("Title")+t.LogEntry.Render(e.Title))
	fields = append(fields, labelStyle.Render("Status")+
		styles.StatusText(e.Status))
	fields = append(fields, labelStyle.Render("Tool Calls")+t.Dim.Render(
		fmt.Sprintf("%d", e.ToolCalls)))

	// Files as bullet list
	if e.Files != "" {
		fields = append(fields, "")
		fields = append(fields, labelStyle.Render("Files"))
		for _, f := range strings.Split(e.Files, ", ") {
			f = strings.TrimSpace(f)
			if f != "" {
				fields = append(fields, "   "+t.Faint.Render("\u2022")+" "+t.Dim.Render(f))
			}
		}
	}
	fieldBlock := lipgloss.NewStyle().Padding(1, 3).Render(strings.Join(fields, "\n"))

	// Output section
	outputHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("OUTPUT")
	outputRule := lipgloss.NewStyle().PaddingLeft(3).
		Render(styles.ThinSeparator(t, w-6))

	output := e.Output
	if output == "" {
		output = t.Faint.Render("(no output captured)")
	}
	maxBodyH := m.height - 14
	if maxBodyH < 3 {
		maxBodyH = 3
	}
	outputLines := strings.Split(output, "\n")
	if len(outputLines) > maxBodyH {
		totalLines := len(outputLines)
		outputLines = outputLines[:maxBodyH]
		outputLines = append(outputLines,
			t.Faint.Render(fmt.Sprintf("\u2026 (%d more lines)", totalLines-maxBodyH)))
	}

	// Render output with left border accent
	outputContent := strings.Join(outputLines, "\n")
	outputBlock := lipgloss.NewStyle().
		Padding(0, 3).
		Foreground(t.Text).
		BorderLeft(true).
		BorderStyle(lipgloss.Border{Left: "\u2502"}).
		BorderForeground(t.Muted).
		MarginLeft(3).
		Render(outputContent)

	content := header + "\n" + rule + "\n" + backHint + "\n" + fieldBlock + "\n" +
		outputHeader + "\n" + outputRule + "\n" + outputBlock
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}

// firstNLines returns the first n non-empty lines from s.
func firstNLines(s string, n int) string {
	if s == "" {
		return ""
	}
	var result []string
	for _, line := range strings.Split(s, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		result = append(result, trimmed)
		if len(result) >= n {
			break
		}
	}
	return strings.Join(result, "\n")
}

// firstLogLine returns the first non-empty line.
func firstLogLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			return trimmed
		}
	}
	return ""
}
