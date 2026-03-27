package model

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// MessagesModel displays IPC messages with direction arrows, subject coloring,
// filtering, and a detail view.
type MessagesModel struct {
	// Data
	messages []runtime.Message
	filtered []runtime.Message
	theme    styles.Theme

	// Navigation
	cursor     int
	offset     int
	detailMode bool
	autoScroll bool
	keyMap     keys.KeyMap

	// Filters
	subjectFilter string // "" = all, or specific subject
	searchQuery   string
	searchActive  bool

	// Layout
	width   int
	height  int
	focused bool
}

// NewMessagesModel creates a messages panel with auto-scroll enabled.
func NewMessagesModel(theme styles.Theme) MessagesModel {
	return MessagesModel{
		theme:      theme,
		autoScroll: true,
		keyMap:     keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the messages sub-model.
func (m MessagesModel) Init() tea.Cmd { return nil }

// SetSize updates the panel dimensions.
func (m *MessagesModel) SetSize(w, h int) { m.width = w; m.height = h }

// SetFocused toggles focus state.
func (m *MessagesModel) SetFocused(focused bool) { m.focused = focused }

// SetSnapshot updates the message list from a fresh snapshot.
func (m *MessagesModel) SetSnapshot(snap runtime.Snapshot) {
	m.messages = snap.Messages
	m.applyMsgFilters()
	if m.autoScroll && !m.detailMode {
		m.cursor = 0
		m.offset = 0
	}
}

// applyMsgFilters rebuilds the filtered slice from messages.
func (m *MessagesModel) applyMsgFilters() {
	m.filtered = m.filtered[:0]
	for _, msg := range m.messages {
		if m.subjectFilter != "" && msg.Subject != m.subjectFilter {
			continue
		}
		if m.searchQuery != "" &&
			!containsFold(msg.Body, m.searchQuery) &&
			!containsFold(msg.From, m.searchQuery) &&
			!containsFold(msg.To, m.searchQuery) &&
			!containsFold(msg.Subject, m.searchQuery) {
			continue
		}
		m.filtered = append(m.filtered, msg)
	}
	if m.cursor >= len(m.filtered) {
		m.cursor = max(0, len(m.filtered)-1)
	}
}

// Update handles navigation, filter cycling, and search input.
func (m MessagesModel) Update(msg tea.Msg) (MessagesModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	kmsg, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}

	if m.searchActive {
		return m.updateMsgSearch(kmsg), nil
	}

	if m.detailMode {
		if key.Matches(kmsg, m.keyMap.Back) {
			m.detailMode = false
		}
		return m, nil
	}

	return m.updateMsgList(kmsg), nil
}

func (m MessagesModel) updateMsgSearch(msg tea.KeyMsg) MessagesModel {
	switch msg.Type {
	case tea.KeyEnter, tea.KeyEsc:
		m.searchActive = false
	case tea.KeyBackspace:
		if len(m.searchQuery) > 0 {
			m.searchQuery = m.searchQuery[:len(m.searchQuery)-1]
			m.applyMsgFilters()
		}
	default:
		if msg.Type == tea.KeyRunes {
			m.searchQuery += string(msg.Runes)
			m.applyMsgFilters()
		} else if msg.Type == tea.KeySpace {
			m.searchQuery += " "
			m.applyMsgFilters()
		}
	}
	return m
}

func (m MessagesModel) updateMsgList(msg tea.KeyMsg) MessagesModel {
	total := len(m.filtered)

	switch {
	case key.Matches(msg, m.keyMap.Up):
		m.autoScroll = false
		if m.cursor > 0 {
			m.cursor--
		}
		m.ensureMsgVisible()

	case key.Matches(msg, m.keyMap.Down):
		if m.cursor < total-1 {
			m.cursor++
		}
		if m.cursor == 0 {
			m.autoScroll = true
		}
		m.ensureMsgVisible()

	case key.Matches(msg, m.keyMap.Select):
		if total > 0 {
			m.detailMode = true
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
			// Cycle subject filter
			switch m.subjectFilter {
			case "":
				m.subjectFilter = "status_report"
			case "status_report":
				m.subjectFilter = "worker_finished"
			case "worker_finished":
				m.subjectFilter = "task_complete"
			case "task_complete":
				m.subjectFilter = "question"
			case "question":
				m.subjectFilter = "commit_request"
			case "commit_request":
				m.subjectFilter = "error"
			case "error":
				m.subjectFilter = ""
			}
			m.applyMsgFilters()
		case "c":
			m.subjectFilter = ""
			m.searchQuery = ""
			m.applyMsgFilters()
		}
	}

	return m
}

// ensureMsgVisible adjusts scroll offset so the cursor is in view.
func (m *MessagesModel) ensureMsgVisible() {
	viewH := m.msgViewportHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+viewH {
		m.offset = m.cursor - viewH + 1
	}
}

// msgViewportHeight returns the number of message lines visible in the list.
func (m MessagesModel) msgViewportHeight() int {
	h := m.height - 5
	if h < 1 {
		h = 1
	}
	return h
}

// View renders the messages panel (list or detail mode).
func (m MessagesModel) View() string {
	if m.detailMode {
		return m.viewMsgDetail()
	}
	return m.viewMsgList()
}

func (m MessagesModel) viewMsgList() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("MESSAGES")
	rule := t.Faint.Render(strings.Repeat("\u2500", w))

	filterBar := m.renderMsgFilterBar()

	// Empty state
	if len(m.filtered) == 0 {
		emptyMsg := "No messages"
		if m.subjectFilter != "" || m.searchQuery != "" {
			emptyMsg = "No messages match current filters"
		}
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render(emptyMsg)
		content := header + "\n" + rule + "\n" + filterBar + "\n" + empty
		return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
	}

	// Summary bar with subject counts
	summaryBar := m.renderSummaryBar()

	// Auto-scroll indicator
	scrollInd := ""
	if m.autoScroll {
		scrollInd = lipgloss.NewStyle().Foreground(t.Success).Render(" LIVE")
	} else {
		scrollInd = lipgloss.NewStyle().Foreground(t.Warning).Render(" PAUSED")
	}

	// Render visible entries
	viewH := m.msgViewportHeight()
	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	var lines []string
	end := m.offset + viewH
	if end > len(m.filtered) {
		end = len(m.filtered)
	}

	for i := m.offset; i < end; i++ {
		line := m.renderMsgLine(m.filtered[i], w)
		if m.focused && i == m.cursor {
			line = lipgloss.NewStyle().
				Background(selectedBg).
				Width(w - 4).
				Render(line)
		}
		lines = append(lines, line)
	}

	body := lipgloss.NewStyle().
		Padding(0, 2).
		Render(strings.Join(lines, "\n"))

	hint := ""
	if m.focused {
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Padding(1, 3).
			Render("enter = detail  s = subject  / = search  f = follow  c = clear")
	}

	content := header + "\n" + rule + "\n" + summaryBar + scrollInd + "\n" + filterBar + "\n" + body + "\n" + hint
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}

// renderSummaryBar shows message counts by subject type.
func (m MessagesModel) renderSummaryBar() string {
	t := m.theme
	counts := make(map[string]int)
	for _, msg := range m.filtered {
		counts[msg.Subject]++
	}

	total := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(fmt.Sprintf("%d messages", len(m.filtered)))

	var parts []string
	for _, subj := range []string{"status_report", "worker_finished", "task_complete", "question", "commit_request", "error"} {
		if c, ok := counts[subj]; ok && c > 0 {
			color := m.subjectColor(subj)
			parts = append(parts, lipgloss.NewStyle().Foreground(color).
				Render(fmt.Sprintf("%d %s", c, subjectShort(subj))))
		}
	}

	// Count any subjects not in the known list
	known := map[string]bool{
		"status_report": true, "worker_finished": true, "task_complete": true,
		"question": true, "commit_request": true, "error": true,
	}
	other := 0
	for subj, c := range counts {
		if !known[subj] {
			other += c
		}
	}
	if other > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.Muted).
			Render(fmt.Sprintf("%d other", other)))
	}

	if len(parts) > 0 {
		return total + "  " + strings.Join(parts, "  ")
	}
	return total
}

// renderMsgFilterBar shows active filters.
func (m MessagesModel) renderMsgFilterBar() string {
	t := m.theme
	var parts []string

	if m.subjectFilter != "" {
		color := m.subjectColor(m.subjectFilter)
		parts = append(parts, lipgloss.NewStyle().Foreground(color).
			Render("subj:"+subjectShort(m.subjectFilter)))
	}
	if m.searchQuery != "" {
		q := m.searchQuery
		if m.searchActive {
			q += "\u2588"
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

// renderMsgLine renders a single message as a one-liner.
func (m MessagesModel) renderMsgLine(msg runtime.Message, maxW int) string {
	t := m.theme

	// Timestamp (HH:MM:SS)
	ts := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).
		Render(time.Unix(msg.Timestamp, 0).Format("15:04:05"))

	// Subject badge (color-coded, abbreviated)
	subjColor := m.subjectColor(msg.Subject)
	subjText := subjectShort(msg.Subject)
	subjBadge := lipgloss.NewStyle().Foreground(subjColor).Width(9).Render(subjText)

	// Direction: From → To
	arrow := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render(" \u2192 ")
	from := lipgloss.NewStyle().Foreground(t.Text).Render(msg.From)
	to := lipgloss.NewStyle().Foreground(t.Text).Render(msg.To)
	direction := from + arrow + to

	// Body preview (first line, truncated)
	prefix := ts + " " + subjBadge + " " + direction + "  "
	prefixW := lipgloss.Width(prefix)
	maxBody := maxW - prefixW - 6
	body := firstMsgLine(msg.Body)
	if maxBody > 0 && len(body) > maxBody {
		body = body[:maxBody-1] + "\u2026"
	}

	bodyStyle := lipgloss.NewStyle().Foreground(t.Text)
	if msg.Subject == "status_report" {
		bodyStyle = bodyStyle.Foreground(t.Muted)
	}

	return prefix + bodyStyle.Render(body)
}

// firstMsgLine returns the first non-empty line of text.
func firstMsgLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			return trimmed
		}
	}
	return ""
}

// subjectColor returns the theme color for a message subject.
func (m MessagesModel) subjectColor(subject string) lipgloss.AdaptiveColor {
	t := m.theme
	switch subject {
	case "status_report":
		return t.Muted
	case "worker_finished":
		return t.Success
	case "task_complete":
		return t.Primary
	case "question":
		return t.Warning
	case "commit_request":
		return t.Accent
	case "error":
		return t.Danger
	default:
		return t.Text
	}
}

// subjectShort abbreviates a subject for compact display.
func subjectShort(s string) string {
	switch s {
	case "status_report":
		return "status"
	case "worker_finished":
		return "finished"
	case "task_complete":
		return "complete"
	case "commit_request":
		return "commit"
	default:
		return s
	}
}

// viewMsgDetail renders full info for the selected message.
func (m MessagesModel) viewMsgDetail() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	if m.cursor < 0 || m.cursor >= len(m.filtered) {
		m.detailMode = false
		return m.viewMsgList()
	}

	msg := m.filtered[m.cursor]

	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(fmt.Sprintf("MESSAGES \u2014 %s", msg.Subject))
	rule := t.Faint.Render(strings.Repeat("\u2500", w))
	backHint := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc to go back")

	labelStyle := t.StatLabel.Copy().Width(12)
	valueStyle := t.Body

	var fields []string
	fields = append(fields, labelStyle.Render("Time")+valueStyle.Render(
		time.Unix(msg.Timestamp, 0).Format("2006-01-02 15:04:05")))
	fields = append(fields, labelStyle.Render("From")+valueStyle.Render(msg.From))
	fields = append(fields, labelStyle.Render("To")+valueStyle.Render(msg.To))
	fields = append(fields, labelStyle.Render("Subject")+
		lipgloss.NewStyle().Foreground(m.subjectColor(msg.Subject)).Render(msg.Subject))

	fieldBlock := lipgloss.NewStyle().Padding(1, 3).Render(strings.Join(fields, "\n"))

	// Body content
	bodyHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("BODY")
	bodyRule := lipgloss.NewStyle().PaddingLeft(3).
		Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))

	body := msg.Body
	maxBodyH := m.height - 14
	if maxBodyH < 3 {
		maxBodyH = 3
	}
	bodyLines := strings.Split(body, "\n")
	if len(bodyLines) > maxBodyH {
		totalLines := len(bodyLines)
		bodyLines = bodyLines[:maxBodyH]
		bodyLines = append(bodyLines,
			t.Faint.Render(fmt.Sprintf("\u2026 (%d more lines)", totalLines-maxBodyH)))
	}
	bodyBlock := lipgloss.NewStyle().Padding(0, 3).Foreground(t.Text).
		Render(strings.Join(bodyLines, "\n"))

	content := header + "\n" + rule + "\n" + backHint + "\n" + fieldBlock + "\n" +
		bodyHeader + "\n" + bodyRule + "\n" + bodyBlock
	return lipgloss.NewStyle().Width(w).Height(m.height).Render(content)
}
