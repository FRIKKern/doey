package model

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// LifecycleEvent is a single lifecycle event from events.jsonl.
// JSON tags match shell hooks and daemon events.go ("ts", "type", "source").
type LifecycleEvent struct {
	Timestamp int64  `json:"ts"`
	EventType string `json:"type"`
	Source    string `json:"source"`
	TaskID    string `json:"task_id"`
	Summary   string `json:"summary"`
	Severity  string `json:"severity"` // "info", "warning", "critical"
}

// LifecycleAlert is an active alert from alerts.jsonl.
type LifecycleAlert struct {
	Timestamp int64  `json:"timestamp"`
	AlertType string `json:"alert_type"` // "stall_warning", "stall_alert"
	Pane      string `json:"pane"`
	TaskID    string `json:"task_id"`
	Message   string `json:"message"`
	Severity  string `json:"severity"` // "warning", "critical"
}

// lifecycleTickMsg triggers a file re-read.
type lifecycleTickMsg time.Time

// LifecycleModel displays a timeline of lifecycle events with drilldown,
// alerts, and pane status grid.
type LifecycleModel struct {
	runtimeDir string
	theme      styles.Theme
	keyMap     keys.KeyMap

	// Data
	events []LifecycleEvent
	alerts []LifecycleAlert

	// Filters
	filterPane      string // "" = all
	filterTaskID    string // "" = all
	filterEventType string // "" = all
	filterSeverity  string // "" = all
	filtered        []LifecycleEvent

	// Navigation
	cursor     int
	offset     int
	detailMode bool // true = showing all events for selected task_id
	autoScroll bool
	viewMode   int // 0=timeline, 1=alerts, 2=status grid

	// Layout
	width   int
	height  int
	focused bool
}

// NewLifecycleModel creates a lifecycle tab.
func NewLifecycleModel(runtimeDir string, theme styles.Theme) LifecycleModel {
	return LifecycleModel{
		runtimeDir: runtimeDir,
		theme:      theme,
		keyMap:     keys.DefaultKeyMap(),
		autoScroll: true,
	}
}

// Init is a no-op — the root model's tick drives updates.
func (m LifecycleModel) Init() tea.Cmd { return nil }

// SetSize updates dimensions.
func (m *LifecycleModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetFocused sets focus state.
func (m *LifecycleModel) SetFocused(focused bool) { m.focused = focused }

// SetRuntimeDir updates the runtime directory (for late binding).
func (m *LifecycleModel) SetRuntimeDir(dir string) { m.runtimeDir = dir }

// Reload reads events and alerts from disk.
func (m *LifecycleModel) Reload() {
	m.events = readJSONL[LifecycleEvent](filepath.Join(m.runtimeDir, "lifecycle", "events.jsonl"))
	m.alerts = readJSONL[LifecycleAlert](filepath.Join(m.runtimeDir, "lifecycle", "alerts.jsonl"))

	// Sort events newest first.
	sort.Slice(m.events, func(i, j int) bool {
		return m.events[i].Timestamp > m.events[j].Timestamp
	})

	m.applyFilters()

	if m.autoScroll && !m.detailMode {
		m.cursor = 0
		m.offset = 0
	}
	if m.cursor >= len(m.filtered) {
		m.cursor = max(0, len(m.filtered)-1)
	}
}

// Update handles key events for navigation and filtering.
func (m LifecycleModel) Update(msg tea.Msg) (LifecycleModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.KeyMsg:
		// Filter toggles (only when not in detail mode).
		if !m.detailMode {
			switch msg.String() {
			case "p":
				m.cycleFilterPane()
				return m, nil
			case "t":
				m.cycleFilterTaskID()
				return m, nil
			case "e":
				m.cycleFilterEventType()
				return m, nil
			case "v":
				m.viewMode = (m.viewMode + 1) % 3
				m.cursor = 0
				m.offset = 0
				return m, nil
			}
		}

		if key.Matches(msg, m.keyMap.Up) {
			if m.cursor > 0 {
				m.cursor--
				m.autoScroll = false
			}
			if m.cursor < m.offset {
				m.offset = m.cursor
			}
			return m, nil
		}
		if key.Matches(msg, m.keyMap.Down) {
			limit := len(m.filtered) - 1
			if m.viewMode == 1 {
				limit = len(m.alerts) - 1
			}
			if m.cursor < limit {
				m.cursor++
			}
			visible := m.visibleRows()
			if m.cursor >= m.offset+visible {
				m.offset = m.cursor - visible + 1
			}
			return m, nil
		}
		if key.Matches(msg, m.keyMap.Select) {
			if m.viewMode == 0 && !m.detailMode && m.cursor < len(m.filtered) {
				m.detailMode = true
				m.filterTaskID = m.filtered[m.cursor].TaskID
				m.applyFilters()
				m.cursor = 0
				m.offset = 0
			}
			return m, nil
		}
		if key.Matches(msg, m.keyMap.Back) {
			if m.detailMode {
				m.detailMode = false
				m.filterTaskID = ""
				m.applyFilters()
				m.cursor = 0
				m.offset = 0
			}
			return m, nil
		}
	}

	return m, nil
}

// View renders the lifecycle tab.
func (m LifecycleModel) View() string {
	if m.width < 10 || m.height < 3 {
		return ""
	}

	t := m.theme

	// Header line: view mode tabs + active filters.
	header := m.renderHeader(t)

	// Body depends on view mode.
	bodyH := m.height - lipgloss.Height(header) - 1
	if bodyH < 1 {
		bodyH = 1
	}

	var body string
	switch m.viewMode {
	case 0:
		body = m.renderTimeline(t, bodyH)
	case 1:
		body = m.renderAlerts(t, bodyH)
	case 2:
		body = m.renderStatusGrid(t, bodyH)
	}

	return lipgloss.JoinVertical(lipgloss.Left, header, body)
}

// ── Rendering helpers ─────────────────────────────────────────────

func (m LifecycleModel) renderHeader(t styles.Theme) string {
	modes := []string{"Timeline", "Alerts", "Status"}
	var parts []string
	for i, name := range modes {
		if i == m.viewMode {
			parts = append(parts, lipgloss.NewStyle().Bold(true).Foreground(t.Primary).Render("["+name+"]"))
		} else {
			parts = append(parts, t.RenderDim(" "+name+" "))
		}
	}
	viewTabs := strings.Join(parts, " ")

	var filters []string
	if m.filterPane != "" {
		filters = append(filters, "pane:"+m.filterPane)
	}
	if m.filterTaskID != "" {
		filters = append(filters, "task:"+m.filterTaskID)
	}
	if m.filterEventType != "" {
		filters = append(filters, "type:"+m.filterEventType)
	}
	filterStr := ""
	if len(filters) > 0 {
		filterStr = t.RenderDim("  " + strings.Join(filters, " "))
	}

	hint := lipgloss.NewStyle().Foreground(t.Subtle).Render("  v:view p:pane t:task e:type")
	return "  " + viewTabs + filterStr + hint
}

func (m LifecycleModel) renderTimeline(t styles.Theme, h int) string {
	if len(m.filtered) == 0 {
		return lipgloss.NewStyle().Foreground(t.Muted).Padding(1, 2).Render("No lifecycle events found")
	}

	visible := h
	if visible > len(m.filtered)-m.offset {
		visible = len(m.filtered) - m.offset
	}

	var lines []string
	for i := m.offset; i < m.offset+visible && i < len(m.filtered); i++ {
		ev := m.filtered[i]
		ts := time.Unix(ev.Timestamp, 0).Format("15:04:05")

		tsStyle := lipgloss.NewStyle().Foreground(t.Subtle)
		typeStyle := m.eventTypeStyle(t, ev.EventType)
		paneStyle := lipgloss.NewStyle().Foreground(t.Accent)
		taskStyle := lipgloss.NewStyle().Foreground(t.Muted)
		summStyle := lipgloss.NewStyle().Foreground(t.Text)

		line := fmt.Sprintf("  %s %s %s %s %s",
			tsStyle.Render(ts),
			typeStyle.Render(padRight(ev.EventType, 16)),
			paneStyle.Render(padRight(ev.Source, 12)),
			taskStyle.Render(padRight(ev.TaskID, 6)),
			summStyle.Render(truncStr(ev.Summary, m.width-60)),
		)

		if i == m.cursor {
			line = lipgloss.NewStyle().Background(t.Primary).Foreground(t.BgText).Width(m.width).Render(line)
		}

		lines = append(lines, line)
	}

	return strings.Join(lines, "\n")
}

func (m LifecycleModel) renderAlerts(t styles.Theme, h int) string {
	if len(m.alerts) == 0 {
		return lipgloss.NewStyle().Foreground(t.Muted).Padding(1, 2).Render("No active alerts")
	}

	visible := h
	if visible > len(m.alerts)-m.offset {
		visible = len(m.alerts) - m.offset
	}

	var lines []string
	for i := m.offset; i < m.offset+visible && i < len(m.alerts); i++ {
		a := m.alerts[i]
		ts := time.Unix(a.Timestamp, 0).Format("15:04:05")

		var sevStyle lipgloss.Style
		switch a.Severity {
		case "critical":
			sevStyle = lipgloss.NewStyle().Bold(true).Foreground(t.Danger)
		default:
			sevStyle = lipgloss.NewStyle().Foreground(t.Warning)
		}

		line := fmt.Sprintf("  %s %s %s %s %s",
			lipgloss.NewStyle().Foreground(t.Subtle).Render(ts),
			sevStyle.Render(padRight(a.Severity, 10)),
			t.RenderAccent(padRight(a.Pane, 12)),
			t.RenderDim(padRight(a.TaskID, 6)),
			lipgloss.NewStyle().Foreground(t.Text).Render(truncStr(a.Message, m.width-55)),
		)

		if i == m.cursor {
			line = lipgloss.NewStyle().Background(t.Warning).Foreground(t.BgText).Width(m.width).Render(line)
		}

		lines = append(lines, line)
	}

	return strings.Join(lines, "\n")
}

func (m LifecycleModel) renderStatusGrid(_ styles.Theme, _ int) string {
	// Placeholder — populated when wired to snapshot pane data.
	return lipgloss.NewStyle().Padding(1, 2).Render("Status grid — connect via SetSnapshot for live pane data")
}

// ── Event type styling ────────────────────────────────────────────

func (m LifecycleModel) eventTypeStyle(t styles.Theme, eventType string) lipgloss.Style {
	switch eventType {
	case "task_started":
		return lipgloss.NewStyle().Foreground(t.Info)
	case "task_completed":
		return lipgloss.NewStyle().Foreground(t.Success)
	case "task_failed":
		return lipgloss.NewStyle().Foreground(t.Danger)
	case "stall_warning":
		return lipgloss.NewStyle().Foreground(t.Warning)
	case "stall_alert":
		return lipgloss.NewStyle().Bold(true).Foreground(t.Warning)
	case "tool_blocked":
		return lipgloss.NewStyle().Foreground(t.Muted)
	default:
		return lipgloss.NewStyle().Foreground(t.Text)
	}
}

// ── Filters ───────────────────────────────────────────────────────

func (m *LifecycleModel) applyFilters() {
	m.filtered = nil
	for _, ev := range m.events {
		if m.filterPane != "" && ev.Source != m.filterPane {
			continue
		}
		if m.filterTaskID != "" && ev.TaskID != m.filterTaskID {
			continue
		}
		if m.filterEventType != "" && ev.EventType != m.filterEventType {
			continue
		}
		if m.filterSeverity != "" && ev.Severity != m.filterSeverity {
			continue
		}
		m.filtered = append(m.filtered, ev)
	}
}

func (m *LifecycleModel) cycleFilterPane() {
	panes := m.uniqueValues(func(e LifecycleEvent) string { return e.Source })
	m.filterPane = cycleString(m.filterPane, panes)
	m.applyFilters()
	m.cursor = 0
	m.offset = 0
}

func (m *LifecycleModel) cycleFilterTaskID() {
	ids := m.uniqueValues(func(e LifecycleEvent) string { return e.TaskID })
	m.filterTaskID = cycleString(m.filterTaskID, ids)
	m.applyFilters()
	m.cursor = 0
	m.offset = 0
}

func (m *LifecycleModel) cycleFilterEventType() {
	types := m.uniqueValues(func(e LifecycleEvent) string { return e.EventType })
	m.filterEventType = cycleString(m.filterEventType, types)
	m.applyFilters()
	m.cursor = 0
	m.offset = 0
}

func (m LifecycleModel) uniqueValues(fn func(LifecycleEvent) string) []string {
	seen := map[string]bool{}
	var vals []string
	for _, ev := range m.events {
		v := fn(ev)
		if v != "" && !seen[v] {
			seen[v] = true
			vals = append(vals, v)
		}
	}
	sort.Strings(vals)
	return vals
}

func (m LifecycleModel) visibleRows() int {
	// Header takes ~2 lines; rest is body.
	v := m.height - 3
	if v < 1 {
		v = 1
	}
	return v
}

// ── Utilities ─────────────────────────────────────────────────────

// readJSONL reads a JSONL file and returns parsed entries. Returns nil on
// missing/unreadable files (graceful degradation).
func readJSONL[T any](path string) []T {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var items []T
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 256*1024), 256*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var item T
		if json.Unmarshal([]byte(line), &item) == nil {
			items = append(items, item)
		}
	}
	return items
}

func cycleString(current string, options []string) string {
	if len(options) == 0 {
		return ""
	}
	if current == "" {
		return options[0]
	}
	for i, v := range options {
		if v == current {
			if i+1 < len(options) {
				return options[i+1]
			}
			return "" // wrap to "all"
		}
	}
	return ""
}

func padRight(s string, n int) string {
	if len(s) >= n {
		return s[:n]
	}
	return s + strings.Repeat(" ", n-len(s))
}

func truncStr(s string, maxLen int) string {
	if maxLen <= 0 {
		return ""
	}
	if len(s) <= maxLen {
		return s
	}
	if maxLen <= 3 {
		return s[:maxLen]
	}
	return s[:maxLen-3] + "..."
}
