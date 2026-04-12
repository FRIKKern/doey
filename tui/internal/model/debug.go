package model

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"
	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// DebugModel is a live log viewer with filtering, auto-scroll, severity
// coloring, and detail expansion for debug events.
type DebugModel struct {
	// Data
	entries  []runtime.DebugEntry // all entries from snapshot
	filtered []runtime.DebugEntry // after applying filters
	theme    styles.Theme

	// Navigation
	cursor             int  // selected entry index in filtered list
	offset             int  // scroll offset for viewport
	detailMode         bool // true = showing detail for selected entry
	detailScrollOffset int  // scroll offset within the detail content
	autoScroll         bool // true = follow newest entries (default on)
	keyMap             keys.KeyMap

	// Filters
	severityFilter string // "" = all, "ERROR", "WARN", "INFO", "DEBUG"
	typeFilter     string // "" = all, "STATUS_CHANGE", "IPC_MESSAGE", etc.
	searchQuery    string // free-text filter on Summary
	searchActive   bool   // true = typing search query

	// Layout
	width   int
	height  int
	focused bool
}

// NewDebugModel creates a debug panel with auto-scroll enabled.
func NewDebugModel(theme styles.Theme) DebugModel {
	return DebugModel{
		theme:      theme,
		autoScroll: true,
		keyMap:     keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the debug sub-model.
func (m DebugModel) Init() tea.Cmd {
	return nil
}

// SetSnapshot updates the event list from a fresh snapshot.
func (m *DebugModel) SetSnapshot(snap runtime.Snapshot) {
	m.entries = snap.DebugEntries
	m.applyFilters()
	if m.autoScroll && !m.detailMode {
		m.cursor = 0 // newest is first (entries sorted desc)
		m.offset = 0
	}
}

// SetSize updates the panel dimensions.
func (m *DebugModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetFocused toggles focus state.
func (m *DebugModel) SetFocused(focused bool) {
	m.focused = focused
}

// applyFilters rebuilds the filtered slice from entries.
func (m *DebugModel) applyFilters() {
	m.filtered = m.filtered[:0]
	for _, e := range m.entries {
		if m.severityFilter != "" && e.Severity != m.severityFilter {
			continue
		}
		if m.typeFilter != "" && e.Type != m.typeFilter {
			continue
		}
		if m.searchQuery != "" &&
			!containsFold(e.Summary, m.searchQuery) &&
			!containsFold(e.Source, m.searchQuery) {
			continue
		}
		m.filtered = append(m.filtered, e)
	}
	if m.cursor >= len(m.filtered) {
		m.cursor = max(0, len(m.filtered)-1)
	}
}

// containsFold reports whether s contains substr, case-insensitive.
func containsFold(s, substr string) bool {
	return strings.Contains(strings.ToLower(s), strings.ToLower(substr))
}

// Update handles navigation, filter cycling, search input, and mouse events.
func (m DebugModel) Update(msg tea.Msg) (DebugModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.MouseMsg:
		return m.updateMouse(msg)

	case tea.KeyMsg:
		// Search input mode
		if m.searchActive {
			return m.updateSearch(msg), nil
		}

		// Detail mode — scroll or exit
		if m.detailMode {
			switch {
			case key.Matches(msg, m.keyMap.Back):
				m.detailMode = false
				m.detailScrollOffset = 0
			case key.Matches(msg, m.keyMap.Up):
				if m.detailScrollOffset > 0 {
					m.detailScrollOffset--
				}
			case key.Matches(msg, m.keyMap.Down):
				if ms := m.maxDetailScroll(); m.detailScrollOffset < ms {
					m.detailScrollOffset++
				}
			}
			return m, nil
		}

		// List mode
		return m.updateList(msg), nil
	}

	return m, nil
}

// updateMouse handles all mouse interactions for the debug panel.
func (m DebugModel) updateMouse(msg tea.MouseMsg) (DebugModel, tea.Cmd) {
	// Detail mode — click back or scroll content
	if m.detailMode {
		if msg.Action == tea.MouseActionRelease {
			if zone.Get("debug-back").InBounds(msg) {
				m.detailMode = false
				m.detailScrollOffset = 0
				return m, nil
			}
		}
		if msg.Action == tea.MouseActionPress {
			if msg.Button == tea.MouseButtonWheelUp {
				if m.detailScrollOffset > 0 {
					m.detailScrollOffset--
				}
				return m, nil
			}
			if msg.Button == tea.MouseButtonWheelDown {
				if ms := m.maxDetailScroll(); m.detailScrollOffset < ms {
					m.detailScrollOffset++
				}
				return m, nil
			}
		}
		return m, nil
	}

	// List mode — click entries to expand
	if msg.Action == tea.MouseActionRelease {
		// Click follow toggle
		if zone.Get("debug-follow").InBounds(msg) {
			m.autoScroll = !m.autoScroll
			if m.autoScroll {
				m.cursor = 0
				m.offset = 0
			}
			return m, nil
		}

		// Click severity filter buttons
		for _, sev := range []string{"ERROR", "WARN", "INFO", "DEBUG"} {
			if zone.Get("debug-sev-"+sev).InBounds(msg) {
				if m.severityFilter == sev {
					m.severityFilter = ""
				} else {
					m.severityFilter = sev
				}
				m.applyFilters()
				return m, nil
			}
		}

		// Click type filter buttons
		for _, typ := range []string{"STATUS_CHANGE", "IPC_MESSAGE", "HOOK_EVENT", "CRASH", "ISSUE", "LOG"} {
			if zone.Get("debug-type-"+typ).InBounds(msg) {
				if m.typeFilter == typ {
					m.typeFilter = ""
				} else {
					m.typeFilter = typ
				}
				m.applyFilters()
				return m, nil
			}
		}

		// Click search toggle
		if zone.Get("debug-search").InBounds(msg) {
			m.searchActive = !m.searchActive
			return m, nil
		}

		// Click entries to open detail
		for i := m.offset; i < len(m.filtered); i++ {
			if zone.Get(fmt.Sprintf("debug-entry-%d", i)).InBounds(msg) {
				m.cursor = i
				m.detailMode = true
				m.detailScrollOffset = 0
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
			if m.cursor < len(m.filtered)-1 {
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

func (m DebugModel) updateSearch(msg tea.KeyMsg) DebugModel {
	switch msg.Type {
	case tea.KeyEnter, tea.KeyEsc:
		m.searchActive = false
	case tea.KeyBackspace:
		if len(m.searchQuery) > 0 {
			m.searchQuery = m.searchQuery[:len(m.searchQuery)-1]
			m.applyFilters()
		}
	default:
		if msg.Type == tea.KeyRunes {
			m.searchQuery += string(msg.Runes)
			m.applyFilters()
		} else if msg.Type == tea.KeySpace {
			m.searchQuery += " "
			m.applyFilters()
		}
	}
	return m
}

func (m DebugModel) updateList(msg tea.KeyMsg) DebugModel {
	total := len(m.filtered)

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
			m.detailScrollOffset = 0
		}

	case key.Matches(msg, m.keyMap.Filter):
		m.searchActive = true

	default:
		switch msg.String() {
		case "f":
			m.autoScroll = !m.autoScroll
			if m.autoScroll {
				m.cursor = 0
				m.offset = 0
			}
		case "s":
			// Cycle severity: ALL → ERROR → WARN → INFO → DEBUG → ALL
			switch m.severityFilter {
			case "":
				m.severityFilter = "ERROR"
			case "ERROR":
				m.severityFilter = "WARN"
			case "WARN":
				m.severityFilter = "INFO"
			case "INFO":
				m.severityFilter = "DEBUG"
			case "DEBUG":
				m.severityFilter = ""
			}
			m.applyFilters()
		case "t":
			// Cycle type filter
			switch m.typeFilter {
			case "":
				m.typeFilter = "STATUS_CHANGE"
			case "STATUS_CHANGE":
				m.typeFilter = "IPC_MESSAGE"
			case "IPC_MESSAGE":
				m.typeFilter = "HOOK_EVENT"
			case "HOOK_EVENT":
				m.typeFilter = "CRASH"
			case "CRASH":
				m.typeFilter = "ISSUE"
			case "ISSUE":
				m.typeFilter = "LOG"
			case "LOG":
				m.typeFilter = ""
			}
			m.applyFilters()
		case "c":
			m.severityFilter = ""
			m.typeFilter = ""
			m.searchQuery = ""
			m.applyFilters()
		}
	}

	return m
}

// ensureVisible adjusts scroll offset so the cursor is in view.
func (m *DebugModel) ensureVisible() {
	viewH := m.viewportHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+viewH {
		m.offset = m.cursor - viewH + 1
	}
}

// viewportHeight returns the number of entry lines visible in the list.
func (m DebugModel) viewportHeight() int {
	// header(2) + filter bar(1) + footer hint(2) = 5 lines overhead
	h := m.height - 5
	if h < 1 {
		h = 1
	}
	return h
}

// detailViewportHeight returns the number of detail content lines visible.
func (m DebugModel) detailViewportHeight() int {
	// header(1) + rule(1) + backHint(1) + fields(7 with padding) + detailHeader(1) + detailRule(1) = ~12 overhead
	h := m.height - 14
	if h < 3 {
		h = 3
	}
	return h
}

// maxDetailScroll returns the max valid detailScrollOffset for current entry.
func (m DebugModel) maxDetailScroll() int {
	if m.cursor < 0 || m.cursor >= len(m.filtered) {
		return 0
	}
	detail := m.filtered[m.cursor].Detail
	totalLines := len(strings.Split(detail, "\n"))
	viewH := m.detailViewportHeight()
	if totalLines <= viewH {
		return 0
	}
	return totalLines - viewH
}

// View renders the debug panel (list or detail mode).
func (m DebugModel) View() string {
	if m.detailMode {
		return m.viewDetail()
	}
	return m.viewList()
}

func (m DebugModel) viewList() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	// Header
	header := t.SectionHeader.Copy().PaddingLeft(2).Render("DEBUG")
	rule := t.Faint.Render(strings.Repeat("─", w))

	// Filter status bar
	filterBar := m.renderFilterBar()

	// Empty state
	if len(m.filtered) == 0 {
		emptyMsg := "No debug events"
		if m.severityFilter != "" || m.typeFilter != "" || m.searchQuery != "" {
			emptyMsg = "No events match current filters"
		}
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render(emptyMsg)
		content := header + "\n" + rule + "\n" + filterBar + "\n" + empty
		return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
	}

	// Entry count + live indicator
	countText := fmt.Sprintf("%d events", len(m.filtered))
	if len(m.filtered) != len(m.entries) {
		countText += fmt.Sprintf(" (of %d)", len(m.entries))
	}
	count := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(countText)

	scrollInd := ""
	if m.autoScroll {
		scrollInd = zone.Mark("debug-follow", lipgloss.NewStyle().Foreground(t.Success).Render(" LIVE"))
	} else {
		scrollInd = zone.Mark("debug-follow", lipgloss.NewStyle().Foreground(t.Warning).Render(" PAUSED"))
	}

	// Render visible entries
	viewH := m.viewportHeight()
	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	var lines []string
	end := m.offset + viewH
	if end > len(m.filtered) {
		end = len(m.filtered)
	}

	for i := m.offset; i < end; i++ {
		line := m.renderEntryLine(m.filtered[i], w)
		if m.focused && i == m.cursor {
			line = lipgloss.NewStyle().
				Background(selectedBg).
				Width(w - 4).
				Render(line)
		}
		lines = append(lines, zone.Mark(fmt.Sprintf("debug-entry-%d", i), line))
	}

	body := lipgloss.NewStyle().
		Padding(0, 2).
		Render(strings.Join(lines, "\n"))

	// Hint
	hint := ""
	if m.focused {
		searchBtn := zone.Mark("debug-search", "/ = search")
		followBtn := zone.Mark("debug-follow", "f = follow")
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Padding(1, 3).
			Render("enter = detail  s = severity  t = type  " + searchBtn + "  " + followBtn + "  c = clear")
	}

	content := header + "\n" + rule + "\n" + count + scrollInd + "\n" + filterBar + "\n" + body + "\n" + hint
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}

// renderFilterBar shows active filters.
func (m DebugModel) renderFilterBar() string {
	t := m.theme
	var parts []string

	// Severity filter chips
	for _, sev := range []string{"ERROR", "WARN", "INFO", "DEBUG"} {
		color := m.severityColor(sev)
		style := lipgloss.NewStyle().Foreground(color)
		if m.severityFilter == sev {
			style = style.Bold(true).Underline(true)
		} else {
			style = style.Faint(true)
		}
		parts = append(parts, zone.Mark("debug-sev-"+sev, style.Render(sev)))
	}
	// Type filter chips
	for _, typ := range []string{"STATUS_CHANGE", "IPC_MESSAGE", "HOOK_EVENT", "CRASH", "ISSUE", "LOG"} {
		style := lipgloss.NewStyle().Foreground(t.Accent)
		if m.typeFilter == typ {
			style = style.Bold(true).Underline(true)
		} else {
			style = style.Faint(true)
		}
		parts = append(parts, zone.Mark("debug-type-"+typ, style.Render(m.typeShort(typ))))
	}
	if m.searchQuery != "" {
		q := m.searchQuery
		if m.searchActive {
			q += "\u2588" // block cursor
		}
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Primary).Render("/"+q))
	} else if m.searchActive {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Primary).Render("/\u2588"))
	}

	if len(parts) == 0 {
		return ""
	}
	return lipgloss.NewStyle().PaddingLeft(3).Render("Filters: " + strings.Join(parts, "  "))
}

// renderEntryLine renders a single log entry as a one-liner.
func (m DebugModel) renderEntryLine(e runtime.DebugEntry, maxW int) string {
	t := m.theme

	// Timestamp (HH:MM:SS)
	ts := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).
		Render(e.Time.Format("15:04:05"))

	// Severity badge
	sevColor := m.severityColor(e.Severity)
	sevBadge := lipgloss.NewStyle().Foreground(sevColor).Bold(e.Severity == "ERROR").
		Width(5).Render(e.Severity)

	// Type badge (abbreviated)
	typeShort := m.typeShort(e.Type)
	typeBadge := lipgloss.NewStyle().Foreground(t.Accent).Width(4).Render(typeShort)

	// Source
	source := ""
	if e.Source != "" {
		source = lipgloss.NewStyle().Foreground(t.Primary).Render("[" + e.Source + "]")
	}

	// Summary (fill remaining width)
	prefix := ts + " " + sevBadge + " " + typeBadge + " " + source + " "
	prefixW := lipgloss.Width(prefix)
	maxSummary := maxW - prefixW - 6
	summary := e.Summary
	if maxSummary > 0 && len(summary) > maxSummary {
		summary = summary[:maxSummary-1] + "\u2026"
	}

	summaryStyle := lipgloss.NewStyle().Foreground(t.Text)
	if e.Severity == "DEBUG" {
		summaryStyle = summaryStyle.Foreground(t.Muted)
	}

	return prefix + summaryStyle.Render(summary)
}

// severityColor returns the theme color for a severity level.
func (m DebugModel) severityColor(sev string) lipgloss.AdaptiveColor {
	t := m.theme
	switch sev {
	case "ERROR":
		return t.Danger
	case "WARN":
		return t.Warning
	case "INFO":
		return t.Text
	case "DEBUG":
		return t.Muted
	default:
		return t.Muted
	}
}

// typeShort abbreviates event type for compact display.
func (m DebugModel) typeShort(typ string) string {
	switch typ {
	case "STATUS_CHANGE":
		return "STS"
	case "IPC_MESSAGE":
		return "IPC"
	case "HOOK_EVENT":
		return "HK"
	case "CRASH":
		return "CRA"
	case "ISSUE":
		return "ISS"
	case "LOG":
		return "LOG"
	default:
		return "???"
	}
}

// viewDetail renders full info for the selected event.
func (m DebugModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	if m.cursor < 0 || m.cursor >= len(m.filtered) {
		m.detailMode = false
		return m.viewList()
	}

	e := m.filtered[m.cursor]

	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(fmt.Sprintf("DEBUG \u2014 %s", e.Type))
	rule := t.Faint.Render(strings.Repeat("\u2500", w))
	backHint := zone.Mark("debug-back", lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc to go back"))

	labelStyle := t.StatLabel.Copy().Width(12)
	valueStyle := t.Body

	var fields []string
	fields = append(fields, labelStyle.Render("Time")+valueStyle.Render(e.Time.Format("2006-01-02 15:04:05")))
	fields = append(fields, labelStyle.Render("Type")+valueStyle.Render(e.Type))
	fields = append(fields, labelStyle.Render("Severity")+
		lipgloss.NewStyle().Foreground(m.severityColor(e.Severity)).Bold(e.Severity == "ERROR").Render(e.Severity))
	fields = append(fields, labelStyle.Render("Source")+valueStyle.Render(e.Source))
	fields = append(fields, labelStyle.Render("Summary")+valueStyle.Render(e.Summary))

	fieldBlock := lipgloss.NewStyle().Padding(1, 3).Render(strings.Join(fields, "\n"))

	// Detail content
	detailHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("CONTENT")
	detailRule := lipgloss.NewStyle().PaddingLeft(3).
		Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))

	detail := e.Detail
	viewH := m.detailViewportHeight()
	detailLines := strings.Split(detail, "\n")
	totalLines := len(detailLines)

	// Apply scroll offset
	scrollOff := m.detailScrollOffset
	if scrollOff > totalLines {
		scrollOff = totalLines
	}
	detailLines = detailLines[scrollOff:]
	if len(detailLines) > viewH {
		detailLines = detailLines[:viewH]
	}

	// Scroll indicator
	scrollHint := ""
	if totalLines > viewH {
		remaining := totalLines - scrollOff - viewH
		if remaining < 0 {
			remaining = 0
		}
		scrollHint = t.Faint.Render(fmt.Sprintf("  lines %d–%d of %d (↑/↓ to scroll)",
			scrollOff+1, scrollOff+len(detailLines), totalLines))
	}

	detailBlock := lipgloss.NewStyle().Padding(0, 3).Foreground(t.Text).
		Render(strings.Join(detailLines, "\n"))
	if scrollHint != "" {
		detailBlock += "\n" + lipgloss.NewStyle().PaddingLeft(3).Render(scrollHint)
	}

	content := header + "\n" + rule + "\n" + backHint + "\n" + fieldBlock + "\n" +
		detailHeader + "\n" + detailRule + "\n" + detailBlock
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}
