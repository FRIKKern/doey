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
	"github.com/doey-cli/doey/tui/internal/store"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// violationFilter is the cycle state for the f-key severity filter.
type violationFilter int

const (
	violationFilterAll violationFilter = iota
	violationFilterWarn
	violationFilterBreaker
)

func (f violationFilter) label() string {
	switch f {
	case violationFilterWarn:
		return "warn"
	case violationFilterBreaker:
		return "breaker"
	default:
		return "all"
	}
}

func (f violationFilter) next() violationFilter {
	return (f + 1) % 3
}

// ViolationsModel renders the polling-loop violations sub-view inside the
// Logs tab. Mirrors ActivityModel: list+detail panes, autoscroll, mouse
// wheel, snapshot-driven (consumes runtime.Snapshot.Violations populated
// from store.ListEventsByClass(store.ViolationPolling)). No tickers.
type ViolationsModel struct {
	all []store.Event // unfiltered, newest-first
	theme styles.Theme

	cursor     int
	offset     int
	detailMode bool
	autoScroll bool
	filter     violationFilter
	keyMap     keys.KeyMap

	width   int
	height  int
	focused bool
}

// NewViolationsModel creates a violations sub-view with autoscroll on and the
// "all" severity filter selected.
func NewViolationsModel(theme styles.Theme) ViolationsModel {
	return ViolationsModel{
		theme:      theme,
		autoScroll: true,
		filter:     violationFilterAll,
		keyMap:     keys.DefaultKeyMap(),
	}
}

// Init is a no-op — data arrives via SetSnapshot.
func (m ViolationsModel) Init() tea.Cmd { return nil }

// SetSnapshot replaces the violations slice from the latest runtime
// snapshot. The slice is already newest-first and pre-capped by the runtime
// reader; we cap to 100 again as a defence in depth.
func (m *ViolationsModel) SetSnapshot(snap runtime.Snapshot) {
	m.all = snap.Violations
	if len(m.all) > 100 {
		m.all = m.all[:100]
	}
	if m.autoScroll && !m.detailMode {
		m.cursor = 0
		m.offset = 0
	}
	view := m.visible()
	if m.cursor >= len(view) {
		m.cursor = max(0, len(view)-1)
	}
}

// SetSize records the panel dimensions.
func (m *ViolationsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetFocused toggles focus state.
func (m *ViolationsModel) SetFocused(focused bool) { m.focused = focused }

// Update routes key/mouse events.
func (m ViolationsModel) Update(msg tea.Msg) (ViolationsModel, tea.Cmd) {
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

func (m ViolationsModel) updateMouse(msg tea.MouseMsg) (ViolationsModel, tea.Cmd) {
	if m.detailMode {
		if msg.Action == tea.MouseActionRelease {
			if zone.Get("viol-back").InBounds(msg) {
				m.detailMode = false
				return m, nil
			}
		}
		return m, nil
	}
	view := m.visible()
	if msg.Action == tea.MouseActionRelease {
		if zone.Get("viol-follow").InBounds(msg) {
			m.autoScroll = !m.autoScroll
			if m.autoScroll {
				m.cursor = 0
				m.offset = 0
			}
			return m, nil
		}
		if zone.Get("viol-filter").InBounds(msg) {
			m.cycleFilter()
			return m, nil
		}
		for i := m.offset; i < len(view); i++ {
			if zone.Get(fmt.Sprintf("viol-entry-%d", i)).InBounds(msg) {
				m.cursor = i
				m.detailMode = true
				return m, nil
			}
		}
	}
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
			if m.cursor < len(view)-1 {
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

func (m ViolationsModel) updateList(msg tea.KeyMsg) ViolationsModel {
	view := m.visible()
	total := len(view)

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
			m.cycleFilter()
		case "G":
			m.autoScroll = true
			m.cursor = 0
			m.offset = 0
		}
	}
	return m
}

func (m *ViolationsModel) cycleFilter() {
	m.filter = m.filter.next()
	m.cursor = 0
	m.offset = 0
}

// visible returns the slice currently shown after applying the severity
// filter. Cheap to call (linear scan, capped at 100 entries).
func (m ViolationsModel) visible() []store.Event {
	if m.filter == violationFilterAll {
		return m.all
	}
	want := m.filter.label()
	out := make([]store.Event, 0, len(m.all))
	for _, e := range m.all {
		if e.Severity == want {
			out = append(out, e)
		}
	}
	return out
}

// counts returns (warn, breaker) totals across the *visible* slice — used by
// the header counter line.
func (m ViolationsModel) counts(view []store.Event) (warn, breaker int) {
	for _, e := range view {
		switch e.Severity {
		case "warn":
			warn++
		case "breaker":
			breaker++
		}
	}
	return
}

func (m *ViolationsModel) ensureVisible() {
	viewH := m.viewportHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+viewH {
		m.offset = m.cursor - viewH + 1
	}
}

func (m ViolationsModel) viewportHeight() int {
	// header(2) + count(1) + footer hint(2) = 5 lines overhead, matches activity.
	h := m.height - 5
	if h < 1 {
		h = 1
	}
	return h
}

// View renders the violations panel — list or detail.
func (m ViolationsModel) View() string {
	if m.detailMode {
		return m.viewDetail()
	}
	return m.viewList()
}

func (m ViolationsModel) viewList() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("VIOLATIONS")
	rule := t.Faint.Render(strings.Repeat("─", w))

	view := m.visible()

	if len(view) == 0 {
		filterPill := zone.Mark("viol-filter",
			lipgloss.NewStyle().Foreground(t.Muted).Faint(true).
				Padding(0, 2).Render("filter: "+m.filter.label()))
		return styles.RenderListFrame([]string{header, rule, filterPill, styles.RenderEmptyState("No violations recorded.", t)}, w, m.height)
	}

	warn, breaker := m.counts(view)
	countText := fmt.Sprintf("polling: %d warn / %d breaker", warn, breaker)
	count := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(countText)

	scrollInd := styles.ScrollIndicator(m.autoScroll, "viol-follow", t)
	filterPill := zone.Mark("viol-filter",
		t.RenderAccent("  ["+m.filter.label()+"]"))

	viewH := m.viewportHeight()
	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	var lines []string
	end := m.offset + viewH
	if end > len(view) {
		end = len(view)
	}
	for i := m.offset; i < end; i++ {
		line := m.renderEntryLine(view[i], w-4)
		if m.focused && i == m.cursor {
			line = lipgloss.NewStyle().
				Background(selectedBg).
				Width(w - 4).
				Render(line)
		}
		lines = append(lines, zone.Mark(fmt.Sprintf("viol-entry-%d", i), line))
	}
	body := lipgloss.NewStyle().Padding(0, 2).Render(strings.Join(lines, "\n"))

	hint := ""
	if m.focused {
		filterBtn := zone.Mark("viol-filter", "f = filter")
		followBtn := zone.Mark("viol-follow", "follow")
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Padding(1, 3).
			Render("enter = detail  " + filterBtn + "  " + followBtn + "  G = top")
	}

	return styles.RenderListFrame([]string{header, rule, count + scrollInd + filterPill, body, hint}, w, m.height)
}

// renderEntryLine renders one violation as: TS  [SEV] pane  reason  ×N  ⛔
func (m ViolationsModel) renderEntryLine(e store.Event, maxW int) string {
	t := m.theme
	if maxW < 20 {
		maxW = 20
	}

	ts := ""
	if e.CreatedAt > 0 {
		ts = time.Unix(e.CreatedAt, 0).Format("15:04:05")
	}
	tsStyled := styles.LogTimestamp(t, ts)

	sev := e.Severity
	if sev == "" {
		sev = "warn"
	}
	sevColor := t.Warning
	if sev == "breaker" {
		sevColor = t.Danger
	}
	sevPill := lipgloss.NewStyle().
		Foreground(sevColor).
		Bold(true).
		Padding(0, 1).
		Render(strings.ToUpper(sev))

	pane := e.Source
	if pane == "" {
		pane = "?"
	}
	paneStyled := styles.LogPaneLabel(t, pane)

	reason := e.WakeReason
	if reason == "" {
		reason = "—"
	}
	reasonStyled := lipgloss.NewStyle().Foreground(t.Text).Render(reason)

	consec := ""
	if e.ConsecutiveCount > 0 {
		consec = lipgloss.NewStyle().Foreground(t.Muted).
			Render(fmt.Sprintf("×%d", e.ConsecutiveCount))
	}

	breakerMark := ""
	if breakerTripped(e) {
		breakerMark = t.RenderDanger(" ⛔")
	}

	parts := []string{tsStyled, sevPill, paneStyled, reasonStyled}
	if consec != "" {
		parts = append(parts, consec)
	}
	line := strings.Join(parts, "  ") + breakerMark

	if lipgloss.Width(line) > maxW {
		line = truncateAnsi(line, maxW)
	}
	return line
}

// breakerTripped reports whether the event has the latched-breaker marker
// embedded in ExtraJSON. We deliberately do not parse JSON here — a substring
// match keeps the renderer cheap and tolerant of schema drift. Documented
// contract: writers include `"breaker_tripped":true` verbatim.
func breakerTripped(e store.Event) bool {
	if e.Severity == "breaker" {
		return true
	}
	if e.ExtraJSON == "" {
		return false
	}
	return strings.Contains(e.ExtraJSON, `"breaker_tripped":true`)
}

// truncateAnsi clamps a string to maxW visible columns, ignoring ANSI escapes.
// We rely on lipgloss.Width which already understands them; tail with an
// ellipsis when we cut.
func truncateAnsi(s string, maxW int) string {
	if lipgloss.Width(s) <= maxW {
		return s
	}
	for len(s) > 0 && lipgloss.Width(s) > maxW-1 {
		s = s[:len(s)-1]
	}
	return s + "…"
}

func (m ViolationsModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	view := m.visible()
	if m.cursor < 0 || m.cursor >= len(view) {
		m.detailMode = false
		return m.viewList()
	}
	e := view[m.cursor]

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("VIOLATION — polling")
	rule := t.Faint.Render(strings.Repeat("─", w))
	backHint := zone.Mark("viol-back", lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc to go back"))

	labelStyle := t.StatLabel.Copy().Width(14)
	valueStyle := t.Body

	var fields []string

	timeStr := ""
	ageStr := ""
	if e.CreatedAt > 0 {
		at := time.Unix(e.CreatedAt, 0)
		timeStr = at.Format("2006-01-02 15:04:05")
		ageStr = relativeAge(time.Since(at))
	}
	fields = append(fields, labelStyle.Render("Time")+valueStyle.Render(timeStr))
	if ageStr != "" {
		fields = append(fields, labelStyle.Render("Age")+t.Faint.Render(ageStr))
	}

	sev := e.Severity
	if sev == "" {
		sev = "warn"
	}
	sevColor := t.Warning
	if sev == "breaker" {
		sevColor = t.Danger
	}
	sevPill := lipgloss.NewStyle().Foreground(sevColor).Bold(true).Render(strings.ToUpper(sev))
	fields = append(fields, labelStyle.Render("Severity")+sevPill)

	if e.Source != "" {
		fields = append(fields, labelStyle.Render("Pane")+valueStyle.Render(e.Source))
	}
	if e.Role != "" {
		fields = append(fields, labelStyle.Render("Role")+valueStyle.Render(e.Role))
	}
	if e.Session != "" {
		fields = append(fields, labelStyle.Render("Session")+valueStyle.Render(e.Session))
	}
	if e.WindowID != "" {
		fields = append(fields, labelStyle.Render("Window")+valueStyle.Render(e.WindowID))
	}
	if e.WakeReason != "" {
		fields = append(fields, labelStyle.Render("Wake reason")+valueStyle.Render(e.WakeReason))
	}
	if e.ConsecutiveCount > 0 {
		fields = append(fields,
			labelStyle.Render("Consecutive")+valueStyle.Render(fmt.Sprintf("%d", e.ConsecutiveCount)))
	}
	if e.WindowSec > 0 {
		fields = append(fields,
			labelStyle.Render("Window (s)")+valueStyle.Render(fmt.Sprintf("%d", e.WindowSec)))
	}
	if e.UnreadMsgIDs != "" {
		fields = append(fields, labelStyle.Render("Unread IDs")+valueStyle.Render(e.UnreadMsgIDs))
	}
	if breakerTripped(e) {
		fields = append(fields,
			labelStyle.Render("Breaker")+lipgloss.NewStyle().Foreground(t.Danger).Bold(true).Render("TRIPPED"))
	}

	fieldBlock := lipgloss.NewStyle().Padding(1, 3).Render(strings.Join(fields, "\n"))

	dataHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("EXTRA")
	dataRule := lipgloss.NewStyle().PaddingLeft(3).
		Render(t.Faint.Render(strings.Repeat("─", w-6)))

	data := e.ExtraJSON
	if data == "" {
		data = e.Data
	}
	if data == "" {
		data = t.Faint.Render("(no extra data)")
	}
	maxDetailH := m.height - 16
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
