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

// logsGroupEntry defines a sub-view in the logs group.
type logsGroupEntry struct {
	icon string
	name string
	desc string
}

var logsGroupItems = []logsGroupEntry{
	{icon: "◆", name: "Logs", desc: "Live log stream"},
	{icon: "→", name: "Messages", desc: "IPC messages"},
	{icon: "•", name: "Debug", desc: "Flight recorder"},
	{icon: "›", name: "Info", desc: "Session overview"},
	{icon: "⚡", name: "Activity", desc: "Event feed"},
	{icon: "◇", name: "Interactions", desc: "Boss interactions"},
	{icon: "⛔", name: "Violations", desc: "Polling-loop offenders"},
}

// LogsGroupModel groups Logs, Messages, Debug, and Info sub-models under
// a single split-pane tab with a left selector and right content panel.
type LogsGroupModel struct {
	logs         LogViewModel
	messages     MessagesModel
	debug        DebugModel
	info         WelcomeModel
	activity     ActivityModel
	interactions InteractionsModel
	violations   ViolationsModel

	theme   styles.Theme
	cursor  int
	keyMap  keys.KeyMap
	width   int
	height  int
	focused bool
}

// NewLogsGroupModel creates a logs group panel with the first sub-view selected.
func NewLogsGroupModel(theme styles.Theme) LogsGroupModel {
	return LogsGroupModel{
		logs:         NewLogViewModel(theme),
		messages:     NewMessagesModel(theme),
		debug:        NewDebugModel(theme),
		info:         NewWelcomeModel(),
		activity:     NewActivityModel(theme),
		interactions: NewInteractionsModel(theme),
		violations:   NewViolationsModel(theme),
		theme:        theme,
		keyMap:       keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the logs group.
func (m LogsGroupModel) Init() tea.Cmd {
	return nil
}

// Update handles navigation in the split-panel layout and delegates to the
// active sub-model when the right panel is focused.
func (m LogsGroupModel) Update(msg tea.Msg) (LogsGroupModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.MouseMsg:
		return m.updateMouse(msg)
	case tea.KeyMsg:
		return m.updateKey(msg)
	}

	return m, nil
}

// updateMouse handles mouse interactions. A click on a left-list item selects
// that sub-view; every other mouse event (wheel, drag, click in the right
// pane) is delegated to the currently active sub-model so scroll input always
// lands on the feed.
func (m LogsGroupModel) updateMouse(msg tea.MouseMsg) (LogsGroupModel, tea.Cmd) {
	if msg.Action == tea.MouseActionRelease {
		for i := range logsGroupItems {
			if zone.Get(fmt.Sprintf("logsgrp-%d", i)).InBounds(msg) {
				m.cursor = i
				m.updateSubFocus()
				m.propagateSizeToActive()
				return m, nil
			}
		}
	}
	return m.delegateUpdate(msg)
}

// updateKey cycles the left list selection on Tab/Shift-Tab; everything else
// (arrows, j/k, Enter, Esc, filters, etc.) flows through to the active
// sub-model on the right.
func (m LogsGroupModel) updateKey(msg tea.KeyMsg) (LogsGroupModel, tea.Cmd) {
	switch {
	case key.Matches(msg, m.keyMap.NextPanel):
		m.cursor = (m.cursor + 1) % len(logsGroupItems)
		m.updateSubFocus()
		m.propagateSizeToActive()
		return m, nil
	case key.Matches(msg, m.keyMap.PrevPanel):
		m.cursor = (m.cursor - 1 + len(logsGroupItems)) % len(logsGroupItems)
		m.updateSubFocus()
		m.propagateSizeToActive()
		return m, nil
	}
	return m.delegateUpdate(msg)
}

// delegateUpdate forwards a message to the currently active sub-model.
func (m LogsGroupModel) delegateUpdate(msg tea.Msg) (LogsGroupModel, tea.Cmd) {
	var cmd tea.Cmd
	switch m.cursor {
	case 0:
		m.logs, cmd = m.logs.Update(msg)
	case 1:
		m.messages, cmd = m.messages.Update(msg)
	case 2:
		m.debug, cmd = m.debug.Update(msg)
	case 3:
		m.info, cmd = m.info.Update(msg)
	case 4:
		m.activity, cmd = m.activity.Update(msg)
	case 5:
		m.interactions, cmd = m.interactions.Update(msg)
	case 6:
		m.violations, cmd = m.violations.Update(msg)
	}
	return m, cmd
}

// SetSnapshot propagates snapshot data to all sub-models.
func (m *LogsGroupModel) SetSnapshot(snap runtime.Snapshot) {
	m.logs.SetSnapshot(snap)
	m.messages.SetSnapshot(snap)
	m.debug.SetSnapshot(snap)
	m.info.SetSnapshot(snap)
	m.activity.SetSnapshot(snap)
	m.interactions.SetSnapshot(snap)
	m.violations.SetSnapshot(snap)
}

// SetSize stores dimensions and propagates to the active sub-model.
func (m *LogsGroupModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.propagateSizeToActive()
}

// SetFocused toggles focus state.
func (m *LogsGroupModel) SetFocused(focused bool) {
	m.focused = focused
	m.updateSubFocus()
}

// updateSubFocus sets the focused state on all sub-models so only the
// currently selected one receives delegated input.
func (m *LogsGroupModel) updateSubFocus() {
	active := m.focused
	m.logs.SetFocused(active && m.cursor == 0)
	m.messages.SetFocused(active && m.cursor == 1)
	m.debug.SetFocused(active && m.cursor == 2)
	m.info.SetFocused(active && m.cursor == 3)
	m.activity.SetFocused(active && m.cursor == 4)
	m.interactions.SetFocused(active && m.cursor == 5)
	m.violations.SetFocused(active && m.cursor == 6)
}

// propagateSizeToActive calculates the right-panel dimensions and sets them
// on the currently selected sub-model.
func (m *LogsGroupModel) propagateSizeToActive() {
	w := m.width
	if w < 40 {
		w = 40
	}
	h := m.height
	if h < 10 {
		h = 10
	}

	leftW := w * 33 / 100
	if leftW < 24 {
		leftW = 24
	}
	rightW := w - leftW - 1
	if rightW < 20 {
		rightW = 20
	}

	switch m.cursor {
	case 0:
		m.logs.SetSize(rightW, h)
	case 1:
		m.messages.SetSize(rightW, h)
	case 2:
		m.debug.SetSize(rightW, h)
	case 3:
		m.info.SetSize(rightW, h)
	case 4:
		m.activity.SetSize(rightW, h)
	case 5:
		m.interactions.SetSize(rightW, h)
	case 6:
		m.violations.SetSize(rightW, h)
	}
}

// View renders the split-pane layout with left selector and right content.
func (m LogsGroupModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}
	h := m.height
	if h < 10 {
		h = 10
	}

	// Panel widths: ~33% left, ~67% right, minus separator
	leftW := w * 33 / 100
	if leftW < 24 {
		leftW = 24
	}
	rightW := w - leftW - 1
	if rightW < 20 {
		rightW = 20
	}

	leftPanel := m.renderLeftPanel(leftW, h)
	rightPanel := m.renderRightPanel(rightW, h)

	// Separator
	sepColor := t.Separator
	sep := lipgloss.NewStyle().
		Foreground(sepColor).
		Render(strings.Repeat("│\n", h-1) + "│")

	return lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, sep, rightPanel)
}

// renderLeftPanel renders the sub-view selector list.
func (m LogsGroupModel) renderLeftPanel(w, h int) string {
	t := m.theme

	// Header
	headerStyle := t.SectionHeader.Copy().Width(w).PaddingLeft(1)
	header := headerStyle.Render("◆ LOGS & DEBUG")

	borderColor := t.Separator
	if m.focused {
		borderColor = t.Primary
	}

	// List items
	var items []string
	for i, entry := range logsGroupItems {
		selected := m.focused && i == m.cursor

		icon := t.RenderAccent(entry.icon)
		nameStyle := lipgloss.NewStyle().Foreground(t.Text)
		if selected {
			nameStyle = nameStyle.Bold(true)
		}

		line := fmt.Sprintf(" %s  %s", icon, nameStyle.Render(entry.name))
		desc := t.RenderFaint("    " + entry.desc)

		rowStyle := lipgloss.NewStyle().Width(w - 2).PaddingLeft(1)
		if selected {
			rowStyle = rowStyle.
				Background(lipgloss.AdaptiveColor{Light: "#EEF2FF", Dark: "#1A1D27"}).
				Foreground(t.Text)
		}

		rendered := rowStyle.Render(line + "\n" + desc)
		items = append(items, zone.Mark(fmt.Sprintf("logsgrp-%d", i), rendered))
	}

	body := strings.Join(items, "\n")

	content := header + "\n\n" + body

	return lipgloss.NewStyle().
		Width(w).
		Height(h).
		BorderForeground(borderColor).
		Render(content)
}

// renderRightPanel delegates View() to the currently selected sub-model.
func (m LogsGroupModel) renderRightPanel(w, h int) string {
	// Ensure the active sub-model has the right dimensions
	switch m.cursor {
	case 0:
		m.logs.SetSize(w, h)
		return m.logs.View()
	case 1:
		m.messages.SetSize(w, h)
		return m.messages.View()
	case 2:
		m.debug.SetSize(w, h)
		return m.debug.View()
	case 3:
		m.info.SetSize(w, h)
		return m.info.View()
	case 4:
		m.activity.SetSize(w, h)
		return m.activity.View()
	case 5:
		m.interactions.SetSize(w, h)
		return m.interactions.View()
	case 6:
		m.violations.SetSize(w, h)
		return m.violations.View()
	}

	// Fallback (shouldn't happen)
	return lipgloss.NewStyle().
		Width(w).
		Height(h).
		Foreground(m.theme.Muted).
		Padding(2, 3).
		Render("No view selected")
}
