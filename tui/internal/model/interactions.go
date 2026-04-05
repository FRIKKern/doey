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

// InteractionsModel displays a scrollable feed of Boss interaction logs.
type InteractionsModel struct {
	interactions []runtime.Interaction
	theme        styles.Theme
	width        int
	height       int
	focused      bool
	viewport     viewport.Model
	keyMap       keys.KeyMap
}

// NewInteractionsModel creates an interactions feed panel.
func NewInteractionsModel(theme styles.Theme) InteractionsModel {
	vp := viewport.New(80, 20)
	return InteractionsModel{
		theme:    theme,
		viewport: vp,
		keyMap:   keys.DefaultKeyMap(),
	}
}

// SetSnapshot updates the interaction list from a new snapshot.
func (m *InteractionsModel) SetSnapshot(snap runtime.Snapshot) {
	m.interactions = snap.Interactions
	m.rebuildContent()
}

// SetSize updates the viewport dimensions.
func (m *InteractionsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.viewport.Width = w - 2
	m.viewport.Height = h - 2
	m.rebuildContent()
}

// SetFocused sets the focus state.
func (m *InteractionsModel) SetFocused(focused bool) { m.focused = focused }

// Update handles key/mouse events for scrolling.
func (m InteractionsModel) Update(msg tea.Msg) (InteractionsModel, tea.Cmd) {
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

// View renders the interactions feed.
func (m InteractionsModel) View() string {
	if len(m.interactions) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(m.theme.Muted).
			Padding(2, 4).
			Render("No interactions recorded yet.")
		return empty
	}
	return m.viewport.View()
}

// interactionTypeBadge returns a colored pill for the interaction type.
func (m *InteractionsModel) interactionTypeBadge(msgType string) string {
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

// rebuildContent re-renders interaction entries into the viewport.
func (m *InteractionsModel) rebuildContent() {
	if m.width < 10 {
		return
	}
	contentWidth := m.width - 4
	if contentWidth < 20 {
		contentWidth = 20
	}

	cap := len(m.interactions)
	if cap > 200 {
		cap = 200
	}

	var lines []string
	lines = append(lines, styles.SectionTitle(m.theme, fmt.Sprintf("Interactions (%d entries)", cap)))
	lines = append(lines, "")

	for i := 0; i < cap; i++ {
		ix := m.interactions[i]

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
			Foreground(m.theme.Accent).
			Bold(true).
			Render(source)

		// Timestamp
		tsStyle := lipgloss.NewStyle().
			Foreground(m.theme.Subtle).
			Faint(true).
			Width(10).
			Render(ts)

		// Message text — truncate if too long
		msg := ix.MessageText
		maxMsgLen := contentWidth - 30
		if maxMsgLen < 20 {
			maxMsgLen = 20
		}
		if len(msg) > maxMsgLen {
			msg = msg[:maxMsgLen-3] + "..."
		}
		msgStyle := lipgloss.NewStyle().
			Foreground(m.theme.Text).
			Render(msg)

		// Task link
		var taskRef string
		if ix.TaskID != nil {
			taskRef = lipgloss.NewStyle().
				Foreground(m.theme.Muted).
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
			Foreground(m.theme.Subtle).
			Faint(true).
			Render(agoStr)

		line := tsStyle + " " + badge + " " + sourceStyle + " " + msgStyle + taskRef + " " + agoStyle
		lines = append(lines, line)
	}

	m.viewport.SetContent(strings.Join(lines, "\n"))
}
