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

// InteractionsModel displays a scrollable feed of Boss interaction logs,
// following the same list+detail rendering pattern as DebugModel / LogViewModel.
type InteractionsModel struct {
	// Data
	interactions []runtime.Interaction
	theme        styles.Theme

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

// NewInteractionsModel creates an interactions feed panel with auto-scroll enabled.
func NewInteractionsModel(theme styles.Theme) InteractionsModel {
	return InteractionsModel{
		theme:      theme,
		autoScroll: true,
		keyMap:     keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the interactions sub-model.
func (m InteractionsModel) Init() tea.Cmd { return nil }

// SetSnapshot updates the interaction list from a new snapshot.
// Capped at 200 entries for display.
func (m *InteractionsModel) SetSnapshot(snap runtime.Snapshot) {
	m.interactions = snap.Interactions
	if len(m.interactions) > 200 {
		m.interactions = m.interactions[:200]
	}
	if m.autoScroll && !m.detailMode {
		m.cursor = 0
		m.offset = 0
	}
	if m.cursor >= len(m.interactions) {
		m.cursor = max(0, len(m.interactions)-1)
	}
	m.clampOffset()
}

// SetSize updates the panel dimensions.
func (m *InteractionsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetFocused sets the focus state.
func (m *InteractionsModel) SetFocused(focused bool) { m.focused = focused }

// Update handles key/mouse events for navigation and detail expansion.
func (m InteractionsModel) Update(msg tea.Msg) (InteractionsModel, tea.Cmd) {
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

// updateMouse handles all mouse interactions for the interactions panel.
func (m InteractionsModel) updateMouse(msg tea.MouseMsg) (InteractionsModel, tea.Cmd) {
	// Detail mode — click back or ignore
	if m.detailMode {
		if msg.Action == tea.MouseActionRelease {
			if zone.Get("interactions-back").InBounds(msg) {
				m.detailMode = false
				return m, nil
			}
		}
		return m, nil
	}

	// List mode — click follow toggle or an entry
	if msg.Action == tea.MouseActionRelease {
		if zone.Get("interactions-follow").InBounds(msg) {
			m.autoScroll = !m.autoScroll
			if m.autoScroll {
				m.cursor = 0
				m.offset = 0
			}
			return m, nil
		}

		for i := m.offset; i < len(m.interactions); i++ {
			if zone.Get(fmt.Sprintf("interactions-entry-%d", i)).InBounds(msg) {
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
			if m.cursor < len(m.interactions)-1 {
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
func (m InteractionsModel) updateList(msg tea.KeyMsg) InteractionsModel {
	total := len(m.interactions)

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
func (m *InteractionsModel) ensureVisible() {
	viewH := m.viewportHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+viewH {
		m.offset = m.cursor - viewH + 1
	}
	m.clampOffset()
}

// clampOffset prevents the scroll offset from exceeding the content bounds.
func (m *InteractionsModel) clampOffset() {
	maxOffset := len(m.interactions) - m.viewportHeight()
	if maxOffset < 0 {
		maxOffset = 0
	}
	if m.offset > maxOffset {
		m.offset = maxOffset
	}
	if m.offset < 0 {
		m.offset = 0
	}
}

// viewportHeight returns the number of entry lines visible in the list.
func (m InteractionsModel) viewportHeight() int {
	// header(2) + count/live(1) + footer hint(2) = 5 lines overhead
	h := m.height - 5
	if h < 1 {
		h = 1
	}
	return h
}

// View renders the interactions panel (list or detail mode).
func (m InteractionsModel) View() string {
	if m.detailMode {
		return m.viewDetail()
	}
	return m.viewList()
}

func (m InteractionsModel) viewList() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("INTERACTIONS")
	rule := t.Faint.Render(strings.Repeat("\u2500", w))

	if len(m.interactions) == 0 {
		return styles.RenderListFrame([]string{header, rule, styles.RenderEmptyState("No interactions recorded yet", t)}, w, m.height)
	}

	// Count + live indicator
	countText := fmt.Sprintf("%d entries", len(m.interactions))
	count := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(countText)

	scrollInd := styles.ScrollIndicator(m.autoScroll, "interactions-follow", t)

	// Render visible entries
	viewH := m.viewportHeight()
	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}

	var lines []string
	end := m.offset + viewH
	if end > len(m.interactions) {
		end = len(m.interactions)
	}

	for i := m.offset; i < end; i++ {
		line := m.renderEntryLine(m.interactions[i], w-4)
		if m.focused && i == m.cursor {
			line = lipgloss.NewStyle().
				Background(selectedBg).
				Width(w - 4).
				Render(line)
		}
		lines = append(lines, zone.Mark(fmt.Sprintf("interactions-entry-%d", i), line))
	}

	body := lipgloss.NewStyle().
		Padding(0, 2).
		Render(strings.Join(lines, "\n"))

	hint := ""
	if m.focused {
		followBtn := zone.Mark("interactions-follow", "f = follow")
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Padding(1, 3).
			Render("enter = detail  " + followBtn + "  G = top")
	}

	return styles.RenderListFrame([]string{header, rule, count + scrollInd, body, hint}, w, m.height)
}

// interactionTypeBadge returns a colored pill for the interaction type.
func (m InteractionsModel) interactionTypeBadge(msgType string) string {
	var bg lipgloss.AdaptiveColor
	switch msgType {
	case "question":
		bg = m.theme.Info
	case "command":
		bg = m.theme.Success
	case "feedback":
		bg = m.theme.Warning
	case "status":
		bg = lipgloss.AdaptiveColor{Light: "#0891B2", Dark: "#22D3EE"} // cyan
	default:
		bg = m.theme.Muted
	}
	return lipgloss.NewStyle().
		Background(bg).
		Foreground(m.theme.BgText).
		Padding(0, 1).
		Render(msgType)
}

// renderEntryLine renders a single interaction as a one-liner.
// Preserves the prior decoration: timestamp + type badge + source + message + task ref + age.
func (m InteractionsModel) renderEntryLine(ix runtime.Interaction, maxW int) string {
	t := m.theme

	ts := ix.CreatedAt.Format("15:04:05")

	msgType := ix.MessageType
	if msgType == "" {
		msgType = "other"
	}
	badge := m.interactionTypeBadge(msgType)

	// Source label
	source := ix.Source
	if source == "" {
		source = "unknown"
	}
	sourceStyle := lipgloss.NewStyle().
		Foreground(t.Accent).
		Bold(true).
		Render(source)

	// Timestamp
	tsStyle := lipgloss.NewStyle().
		Foreground(t.Subtle).
		Faint(true).
		Width(10).
		Render(ts)

	// Message text — truncate if too long
	msg := ix.MessageText
	maxMsgLen := maxW - 30
	if maxMsgLen < 20 {
		maxMsgLen = 20
	}
	if len(msg) > maxMsgLen {
		msg = msg[:maxMsgLen-3] + "..."
	}
	msgStyle := lipgloss.NewStyle().
		Foreground(t.Text).
		Render(msg)

	// Task link
	var taskRef string
	if ix.TaskID != nil {
		taskRef = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Render(fmt.Sprintf(" [task:%d]", *ix.TaskID))
	}

	// Relative time
	ago := time.Since(ix.CreatedAt)
	var agoStr string
	switch {
	case ago < time.Minute:
		agoStr = fmt.Sprintf("%ds ago", int(ago.Seconds()))
	case ago < time.Hour:
		agoStr = fmt.Sprintf("%dm ago", int(ago.Minutes()))
	default:
		agoStr = fmt.Sprintf("%dh ago", int(ago.Hours()))
	}
	agoStyle := lipgloss.NewStyle().
		Foreground(t.Subtle).
		Faint(true).
		Render(agoStr)

	return tsStyle + " " + badge + " " + sourceStyle + " " + msgStyle + taskRef + " " + agoStyle
}

// viewDetail renders full info for the selected interaction.
func (m InteractionsModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	if m.cursor < 0 || m.cursor >= len(m.interactions) {
		m.detailMode = false
		return m.viewList()
	}

	ix := m.interactions[m.cursor]

	msgType := ix.MessageType
	if msgType == "" {
		msgType = "other"
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(fmt.Sprintf("INTERACTIONS \u2014 %s", msgType))
	rule := t.Faint.Render(strings.Repeat("\u2500", w))
	backHint := zone.Mark("interactions-back", lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc to go back"))

	labelStyle := t.StatLabel.Copy().Width(12)
	valueStyle := t.Body

	var fields []string

	fields = append(fields, labelStyle.Render("Time")+valueStyle.Render(ix.CreatedAt.Format("2006-01-02 15:04:05")))

	ago := time.Since(ix.CreatedAt)
	var ageStr string
	switch {
	case ago < 0:
		ageStr = "just now"
	case ago < time.Minute:
		ageStr = fmt.Sprintf("%ds ago", int(ago.Seconds()))
	case ago < time.Hour:
		ageStr = fmt.Sprintf("%dm ago", int(ago.Minutes()))
	case ago < 24*time.Hour:
		ageStr = fmt.Sprintf("%dh ago", int(ago.Hours()))
	default:
		ageStr = fmt.Sprintf("%dd ago", int(ago.Hours()/24))
	}
	fields = append(fields, labelStyle.Render("Age")+t.Faint.Render(ageStr))

	fields = append(fields, labelStyle.Render("Type")+m.interactionTypeBadge(msgType))

	source := ix.Source
	if source == "" {
		source = "unknown"
	}
	fields = append(fields, labelStyle.Render("Source")+valueStyle.Render(source))

	if ix.SessionName != "" {
		fields = append(fields, labelStyle.Render("Session")+valueStyle.Render(ix.SessionName))
	}
	if ix.TaskID != nil {
		fields = append(fields, labelStyle.Render("Task")+valueStyle.Render(fmt.Sprintf("%d", *ix.TaskID)))
	}
	if ix.ID != 0 {
		fields = append(fields, labelStyle.Render("ID")+t.Faint.Render(fmt.Sprintf("%d", ix.ID)))
	}

	fieldBlock := lipgloss.NewStyle().Padding(1, 3).Render(strings.Join(fields, "\n"))

	// Message content block
	msgHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("MESSAGE")
	msgRule := lipgloss.NewStyle().PaddingLeft(3).
		Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))

	msgText := ix.MessageText
	if msgText == "" {
		msgText = t.Faint.Render("(no message)")
	}
	maxDetailH := m.height - 16
	if maxDetailH < 3 {
		maxDetailH = 3
	}
	msgLines := strings.Split(msgText, "\n")
	if len(msgLines) > maxDetailH {
		totalLines := len(msgLines)
		msgLines = msgLines[:maxDetailH]
		msgLines = append(msgLines,
			t.Faint.Render(fmt.Sprintf("\u2026 (%d more lines)", totalLines-maxDetailH)))
	}
	msgBlock := lipgloss.NewStyle().Padding(0, 3).Foreground(t.Text).
		Render(strings.Join(msgLines, "\n"))

	// Context block (if present)
	var ctxSection string
	if ix.Context != "" {
		ctxHeader := t.SectionHeader.Copy().PaddingLeft(3).Render("CONTEXT")
		ctxRule := lipgloss.NewStyle().PaddingLeft(3).
			Render(t.Faint.Render(strings.Repeat("\u2500", w-6)))
		ctxLines := strings.Split(ix.Context, "\n")
		maxCtxH := 5
		if len(ctxLines) > maxCtxH {
			totalLines := len(ctxLines)
			ctxLines = ctxLines[:maxCtxH]
			ctxLines = append(ctxLines,
				t.Faint.Render(fmt.Sprintf("\u2026 (%d more lines)", totalLines-maxCtxH)))
		}
		ctxBlock := lipgloss.NewStyle().Padding(0, 3).Foreground(t.Text).
			Render(strings.Join(ctxLines, "\n"))
		ctxSection = "\n" + ctxHeader + "\n" + ctxRule + "\n" + ctxBlock
	}

	content := header + "\n" + rule + "\n" + backHint + "\n" + fieldBlock + "\n" +
		msgHeader + "\n" + msgRule + "\n" + msgBlock + ctxSection
	return lipgloss.NewStyle().Width(w).Height(m.height).MaxHeight(m.height).Render(content)
}
