package model

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// ActivityModel displays a scrollable feed of recent events from the store.
type ActivityModel struct {
	events   []runtime.Event
	theme    styles.Theme
	width    int
	height   int
	focused  bool
	viewport viewport.Model
	keyMap   keys.KeyMap
}

// NewActivityModel creates an activity feed panel.
func NewActivityModel(theme styles.Theme) ActivityModel {
	vp := viewport.New(80, 20)
	return ActivityModel{
		theme:    theme,
		viewport: vp,
		keyMap:   keys.DefaultKeyMap(),
	}
}

// SetSnapshot updates the event list from a new snapshot.
func (m *ActivityModel) SetSnapshot(snap runtime.Snapshot) {
	m.events = snap.Events
	m.rebuildContent()
}

// SetSize updates the viewport dimensions.
func (m *ActivityModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.viewport.Width = w - 2
	m.viewport.Height = h - 2
	m.rebuildContent()
}

// SetFocused sets the focus state.
func (m *ActivityModel) SetFocused(focused bool) { m.focused = focused }

// Update handles key/mouse events for scrolling.
func (m ActivityModel) Update(msg tea.Msg) (ActivityModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.KeyMsg:
		if key.Matches(msg, m.keyMap.Up, m.keyMap.Down) {
			var cmd tea.Cmd
			m.viewport, cmd = m.viewport.Update(msg)
			return m, cmd
		}
	case tea.MouseMsg:
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd
	}

	return m, nil
}

// View renders the activity feed.
func (m ActivityModel) View() string {
	if len(m.events) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(m.theme.Muted).
			Padding(2, 4).
			Render("No events recorded yet.")
		return empty
	}
	return m.viewport.View()
}

// rebuildContent re-renders event entries into the viewport.
func (m *ActivityModel) rebuildContent() {
	if m.width < 10 {
		return
	}
	contentWidth := m.width - 4
	if contentWidth < 20 {
		contentWidth = 20
	}

	cap := len(m.events)
	if cap > 100 {
		cap = 100
	}

	var lines []string
	lines = append(lines, styles.SectionTitle(m.theme, fmt.Sprintf("Activity Feed (%d events)", cap)))
	lines = append(lines, "")

	for i := 0; i < cap; i++ {
		ev := m.events[i]
		ts := ""
		if ev.Timestamp > 0 {
			ts = time.Unix(ev.Timestamp, 0).Format("15:04:05")
		}
		eventType := ev.Type
		if eventType == "" {
			eventType = "info"
		}

		// Build message: source + data
		var parts []string
		if ev.Source != "" {
			parts = append(parts, ev.Source)
		}
		if ev.Data != "" {
			parts = append(parts, ev.Data)
		}
		if ev.TaskID != "" {
			parts = append(parts, fmt.Sprintf("[task:%s]", ev.TaskID))
		}
		msg := strings.Join(parts, " ")
		if msg == "" {
			msg = eventType
		}

		line := styles.ActivityEntry(m.theme, ts, eventType, msg, contentWidth)
		lines = append(lines, line)
	}

	m.viewport.SetContent(strings.Join(lines, "\n"))
}
