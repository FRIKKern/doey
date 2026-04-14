package model

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// ActivityModel displays a scrollable feed of recent events from the store,
// following the same list+detail rendering pattern as DebugModel / LogViewModel.
type ActivityModel struct {
	// Data
	events []runtime.Event
	theme  styles.Theme

	// Navigation
	cursor     int  // selected entry index
	offset     int  // scroll offset for viewport
	detailMode bool // true = showing detail for selected entry
	autoScroll bool // true = follow newest entries (default on)
	keyMap     keys.KeyMap

	// Layout
	width   int
	height  int
	focused bool
}

// NewActivityModel creates an activity feed panel with auto-scroll enabled.
func NewActivityModel(theme styles.Theme) ActivityModel {
	return ActivityModel{
		theme:      theme,
		autoScroll: true,
		keyMap:     keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the activity sub-model.
func (m ActivityModel) Init() tea.Cmd { return nil }

// SetSnapshot updates the event list from a new snapshot. Events are assumed
// to be newest-first; the list is capped at 100 entries for display.
func (m *ActivityModel) SetSnapshot(snap runtime.Snapshot) {
	m.events = snap.Events
	if len(m.events) > 100 {
		m.events = m.events[:100]
	}
	if m.autoScroll && !m.detailMode {
		m.cursor = 0
		m.offset = 0
	}
	if m.cursor >= len(m.events) {
		m.cursor = max(0, len(m.events)-1)
	}
}

// SetSize updates the panel dimensions.
func (m *ActivityModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetFocused sets the focus state.
func (m *ActivityModel) SetFocused(focused bool) { m.focused = focused }

// Update handles key/mouse events for navigation and detail expansion.
func (m ActivityModel) Update(msg tea.Msg) (ActivityModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.MouseMsg:
		return m.updateMouse(msg)

	case tea.KeyMsg:
		if m.detailMode {
			if key.Matches(msg, m.keyMap.Back) {
				m.detailMode = false
			}
			return m, nil
		}
		return m.updateList(msg), nil
	}

	return m, nil
}

// updateMouse handles all mouse interactions for the activity panel.
func (m ActivityModel) updateMouse(msg tea.MouseMsg) (ActivityModel, tea.Cmd) {
	// Detail mode — click back or ignore
	if m.detailMode {
		if msg.Action == tea.MouseActionRelease {
			if zone.Get("activity-back").InBounds(msg) {
				m.detailMode = false
				return m, nil
			}
		}
		return m, nil
	}

	// List mode — click follow toggle or an entry
	if msg.Action == tea.MouseActionRelease {
		if zone.Get("activity-follow").InBounds(msg) {
			m.autoScroll = !m.autoScroll
			if m.autoScroll {
				m.cursor = 0
				m.offset = 0
			}
			return m, nil
		}

		for i := m.offset; i < len(m.events); i++ {
			if zone.Get(fmt.Sprintf("activity-entry-%d", i)).InBounds(msg) {
				m.cursor = i
				m.detailMode = true
				return m, nil
			}
		}
	}

	// Mouse wheel in list mode
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp {
			m.autoScroll = false
			if m.cursor > 0 {
				m.cursor--
			}
			m.ensureVisible()
			return m, nil
		}
		if msg.Button == tea.MouseButtonWheelDown {
			if m.cursor < len(m.events)-1 {
				m.cursor++
			}
			if m.cursor == 0 {
				m.autoScroll = true
			}
			m.ensureVisible()
			return m, nil
		}
	}

	return m, nil
}

// updateList handles keyboard navigation in list mode.
func (m ActivityModel) updateList(msg tea.KeyMsg) ActivityModel {
	total := len(m.events)

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
		case "f":
			m.autoScroll = !m.autoScroll
			if m.autoScroll {
				m.cursor = 0
				m.offset = 0
			}
		case "G":
			m.autoScroll = true
			m.cursor = 0
			m.offset = 0
		}
	}

	return m
}

// ensureVisible adjusts scroll offset so the cursor is in view.
func (m *ActivityModel) ensureVisible() {
	viewH := m.viewportHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+viewH {
		m.offset = m.cursor - viewH + 1
	}
}

// viewportHeight returns the number of entry lines visible in the list.
func (m ActivityModel) viewportHeight() int {
	// header(2) + count/live(1) + footer hint(2) = 5 lines overhead
	h := m.height - 5
	if h < 1 {
		h = 1
	}
	return h
}

// View renders the activity panel (list or detail mode).
func (m ActivityModel) View() string {
	if m.detailMode {
		return m.viewDetail()
	}
	return m.viewList()
}

func (m ActivityModel) viewList() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("ACTIVITY")
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.events) == 0 {
		return styles.RenderListFrame([]string{header, rule, styles.RenderEmptyState("No events recorded yet", t)}, w, m.height)
	}

	// Count + live indicator
	countText := fmt.Sprintf("%d events", len(m.events))
	count := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(countText)

	scrollInd := styles.ScrollIndicator(m.autoScroll, "activity-follow", t)

	// Render visible entries
	viewH := m.viewportHeight()
	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	var lines []string
	end := m.offset + viewH
	if end > len(m.events) {
		end = len(m.events)
	}

	for i := m.offset; i < end; i++ {
		line := m.renderEntryLine(m.events[i], w-4)
		if m.focused && i == m.cursor {
			line = lipgloss.NewStyle().
				Background(selectedBg).
				Width(w - 4).
				Render(line)
		}
		lines = append(lines, zone.Mark(fmt.Sprintf("activity-entry-%d", i), line))
	}

	body := lipgloss.NewStyle().
		Padding(0, 2).
		Render(strings.Join(lines, "\n"))

	hint := ""
	if m.focused {
		followBtn := zone.Mark("activity-follow", "f = follow")
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Padding(1, 3).
			Render("enter = detail  " + followBtn + "  G = top")
	}

	return styles.RenderListFrame([]string{header, rule, count + scrollInd, body, hint}, w, m.height)
}

// renderEntryLine renders a single event as a one-liner. Preserves the
// prior decoration: timestamp + type badge + composed message.
func (m ActivityModel) renderEntryLine(e runtime.Event, maxW int) string {
	ts := ""
	if e.Timestamp > 0 {
		ts = time.Unix(e.Timestamp, 0).Format("15:04:05")
	}
	eventType := e.Type
	if eventType == "" {
		eventType = "info"
	}

	var parts []string
	if e.Source != "" {
		parts = append(parts, e.Source)
	}
	if e.Data != "" {
		parts = append(parts, e.Data)
	}
	if e.TaskID != "" {
		parts = append(parts, fmt.Sprintf("[task:%s]", e.TaskID))
	}
	msg := strings.Join(parts, " ")
	if msg == "" {
		msg = eventType
	}

	if maxW < 20 {
		maxW = 20
	}
	return styles.ActivityEntry(m.theme, ts, eventType, msg, maxW)
}

// viewDetail renders full info for the selected event.
func (m ActivityModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	if m.cursor < 0 || m.cursor >= len(m.events) {
		m.detailMode = false
		return m.viewList()
	}

	e := m.events[m.cursor]

	eventType := e.Type
	if eventType == "" {
		eventType = "info"
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(fmt.Sprintf("ACTIVITY — %s", eventType))
	rule := t.Faint.Render(strings.Repeat("─", w))
	backHint := zone.Mark("activity-back", lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc to go back"))

	labelStyle := t.StatLabel.Copy().Width(12)
	valueStyle := t.Body

	var fields []string

	timeStr := ""
	ageStr := ""
	if e.Timestamp > 0 {
		at := time.Unix(e.Timestamp, 0)
		timeStr = at.Format("2006-01-02 15:04:05")
		ageStr = relativeAge(time.Since(at))
	}

	fields = append(fields, labelStyle.Render("Time")+valueStyle.Render(timeStr))
	if ageStr != "" {
		fields = append(fields, labelStyle.Render("Age")+t.Faint.Render(ageStr))
	}
	fields = append(fields, labelStyle.Render("Type")+valueStyle.Render(eventType))
	if e.Source != "" {
		fields = append(fields, labelStyle.Render("Source")+valueStyle.Render(e.Source))
	}
	if e.Target != "" {
		fields = append(fields, labelStyle.Render("Target")+valueStyle.Render(e.Target))
	}
	if e.TaskID != "" {
		fields = append(fields, labelStyle.Render("Task")+valueStyle.Render(e.TaskID))
	}
	if e.ID != "" {
		fields = append(fields, labelStyle.Render("ID")+t.Faint.Render(e.ID))
	}

	fieldBlock := lipgloss.NewStyle().Padding(1, 3).Render(strings.Join(fields, "\n"))

	// Content block
	dataHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("DATA")
	dataRule := lipgloss.NewStyle().PaddingLeft(3).
		Render(t.Faint.Render(strings.Repeat("─", w-6)))

	data := e.Data
	if data == "" {
		data = t.Faint.Render("(no data)")
	}
	maxDetailH := m.height - 14
	if maxDetailH < 3 {
		maxDetailH = 3
	}
	dataLines := strings.Split(data, "\n")
	if len(dataLines) > maxDetailH {
		totalLines := len(dataLines)
		dataLines = dataLines[:maxDetailH]
		dataLines = append(dataLines,
			t.Faint.Render(fmt.Sprintf("… (%d more lines)", totalLines-maxDetailH)))
	}
	dataBlock := lipgloss.NewStyle().Padding(0, 3).Foreground(t.Text).
		Render(strings.Join(dataLines, "\n"))

	content := header + "\n" + rule + "\n" + backHint + "\n" + fieldBlock + "\n" +
		dataHeader + "\n" + dataRule + "\n" + dataBlock
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}

// relativeAge formats a duration as a short human-friendly string.
func relativeAge(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	switch {
	case d < time.Second:
		return "just now"
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}
