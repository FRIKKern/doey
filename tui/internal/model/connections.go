package model

import (
	"fmt"
	"sort"
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

// ConnectionsModel displays external service connections.
type ConnectionsModel struct {
	connections  []runtime.Connection
	theme        styles.Theme
	summaryMode  bool
	cursor       int
	keyMap       keys.KeyMap
	width        int
	height       int
	focused      bool
	scrollOffset int
}

// NewConnectionsModel creates a connections panel starting in summary mode.
func NewConnectionsModel(theme styles.Theme) ConnectionsModel {
	return ConnectionsModel{
		theme:       theme,
		summaryMode: true,
		keyMap:      keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the connections sub-model.
func (m ConnectionsModel) Init() tea.Cmd {
	return nil
}

// Update handles navigation in both modes.
func (m ConnectionsModel) Update(msg tea.Msg) (ConnectionsModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.MouseMsg:
		return m.updateMouse(msg)
	case tea.KeyMsg:
		if m.summaryMode {
			return m.updateSummary(msg)
		}
		return m.updateDetail(msg)
	}

	return m, nil
}

// updateMouse handles all mouse interactions for the connections panel.
func (m ConnectionsModel) updateMouse(msg tea.MouseMsg) (ConnectionsModel, tea.Cmd) {
	// Click release — check interactive zones
	if msg.Action == tea.MouseActionRelease {
		if m.summaryMode {
			for i := range m.connections {
				if zone.Get(fmt.Sprintf("conn-%d", i)).InBounds(msg) {
					m.cursor = i
					m.summaryMode = false
					m.scrollOffset = 0
					return m, nil
				}
			}
		} else {
			if zone.Get("conn-detail-back").InBounds(msg) {
				m.summaryMode = true
				m.scrollOffset = 0
				return m, nil
			}
		}
	}

	// Mouse wheel — scroll
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp {
			if m.summaryMode {
				if m.cursor > 0 {
					m.cursor--
				}
			} else {
				if m.scrollOffset > 0 {
					m.scrollOffset--
				}
			}
			return m, nil
		}
		if msg.Button == tea.MouseButtonWheelDown {
			if m.summaryMode {
				if m.cursor < len(m.connections)-1 {
					m.cursor++
				}
			} else {
				maxOff := m.maxScrollOffset()
				if m.scrollOffset < maxOff {
					m.scrollOffset++
				}
			}
			return m, nil
		}
	}

	return m, nil
}

func (m ConnectionsModel) updateSummary(msg tea.KeyMsg) (ConnectionsModel, tea.Cmd) {
	total := len(m.connections)
	if total == 0 {
		return m, nil
	}

	switch {
	case key.Matches(msg, m.keyMap.Up):
		m.cursor--
		if m.cursor < 0 {
			m.cursor = total - 1
		}
	case key.Matches(msg, m.keyMap.Down):
		m.cursor++
		if m.cursor >= total {
			m.cursor = 0
		}
	case key.Matches(msg, m.keyMap.Select):
		m.summaryMode = false
		m.scrollOffset = 0
	}
	return m, nil
}

func (m ConnectionsModel) updateDetail(msg tea.KeyMsg) (ConnectionsModel, tea.Cmd) {
	switch {
	case key.Matches(msg, m.keyMap.Back):
		m.summaryMode = true
		m.scrollOffset = 0
		return m, nil
	case key.Matches(msg, m.keyMap.Up):
		if m.scrollOffset > 0 {
			m.scrollOffset--
		}
	case key.Matches(msg, m.keyMap.Down):
		maxOff := m.maxScrollOffset()
		if m.scrollOffset < maxOff {
			m.scrollOffset++
		}
	}
	return m, nil
}

// SetSnapshot updates connection list from fresh snapshot.
func (m *ConnectionsModel) SetSnapshot(snap runtime.Snapshot) {
	m.connections = snap.Connections
	if m.cursor >= len(m.connections) {
		m.cursor = max(0, len(m.connections)-1)
	}
}

// SetSize updates the panel dimensions.
func (m *ConnectionsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetFocused toggles focus state.
func (m *ConnectionsModel) SetFocused(focused bool) {
	m.focused = focused
}

// View renders summary or detail mode.
func (m ConnectionsModel) View() string {
	if m.summaryMode {
		return m.viewSummary()
	}
	return m.viewDetail()
}

// maxScrollOffset returns the maximum scroll offset for the current view.
func (m ConnectionsModel) maxScrollOffset() int {
	content := m.renderAllContent()
	totalLines := strings.Count(content, "\n") + 1
	off := totalLines - m.height
	if off < 0 {
		return 0
	}
	return off
}

// renderAllContent returns the full content for the current mode (before scroll slicing).
func (m ConnectionsModel) renderAllContent() string {
	if m.summaryMode {
		return m.renderSummaryContent()
	}
	return m.renderDetailContent()
}

// statusDot returns a colored status indicator for a connection.
func statusDot(status string, t styles.Theme) string {
	switch status {
	case "connected":
		return lipgloss.NewStyle().Foreground(t.Success).Render("●")
	case "error":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("●")
	case "pending":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("●")
	default: // disconnected or unknown
		return lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("○")
	}
}

// renderSummaryContent builds the full summary body (before scroll slicing).
func (m ConnectionsModel) renderSummaryContent() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	cardW := w - 10
	if cardW > styles.MaxCardWidth {
		cardW = styles.MaxCardWidth
	}
	if cardW < 20 {
		cardW = 20
	}

	var lines []string

	for i, conn := range m.connections {
		selected := m.focused && i == m.cursor

		// Title line: status dot + name + type badge
		dot := statusDot(conn.Status, t)
		name := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(conn.Name)
		typeBadge := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("[" + conn.Type + "]")
		titleLine := dot + " " + name + " " + typeBadge

		// URL line (truncated)
		urlLine := ""
		if conn.URL != "" {
			url := conn.URL
			maxURL := cardW - 8
			if maxURL < 10 {
				maxURL = 10
			}
			if len(url) > maxURL {
				url = url[:maxURL-1] + "…"
			}
			urlLine = lipgloss.NewStyle().Foreground(t.Muted).Render(url)
		}

		var cardContent string
		if urlLine != "" {
			cardContent = titleLine + "\n" + urlLine
		} else {
			cardContent = titleLine
		}

		// Card border
		borderColor := t.Separator
		if selected {
			borderColor = t.Primary
		}
		bgColor := lipgloss.AdaptiveColor{Light: "#FFFFFF", Dark: "#0F172A"}
		if selected {
			bgColor = lipgloss.AdaptiveColor{Light: "#F8FAFC", Dark: "#1E293B"}
		}

		card := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(borderColor).
			Background(bgColor).
			Width(cardW).
			Padding(1, 2).
			Render(cardContent)

		lines = append(lines, zone.Mark(fmt.Sprintf("conn-%d", i), card))
	}

	return lipgloss.NewStyle().
		Padding(0, 2).
		Render(strings.Join(lines, "\n"))
}

// viewSummary renders the connection list.
func (m ConnectionsModel) viewSummary() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	header := t.SectionHeader.Copy().PaddingLeft(2).Render("CONNECTIONS")
	rule := t.Faint.Render(strings.Repeat("─", w))

	if len(m.connections) == 0 {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			PaddingLeft(3).
			PaddingTop(1).
			Render("No connections configured\n\nAdd connections in .doey/connections.json")
		return header + "\n" + rule + "\n" + empty
	}

	// Summary count
	connected := 0
	for _, c := range m.connections {
		if c.Status == "connected" {
			connected++
		}
	}
	summary := lipgloss.NewStyle().Bold(true).Foreground(t.Text).PaddingLeft(2).
		Render(fmt.Sprintf("%d connections (%d active)", len(m.connections), connected))

	// Build body and apply scroll
	body := m.renderSummaryContent()
	lines := strings.Split(body, "\n")
	viewport := m.height - 5
	if viewport < 1 {
		viewport = 1
	}
	if m.scrollOffset > 0 && m.scrollOffset < len(lines) {
		lines = lines[m.scrollOffset:]
	}
	if len(lines) > viewport {
		lines = lines[:viewport]
	}
	body = strings.Join(lines, "\n")

	hint := ""
	if m.focused && len(m.connections) > 0 {
		hint = lipgloss.NewStyle().
			Foreground(t.Muted).
			Faint(true).
			Padding(1, 3).
			Render("enter to view details")
	}

	return header + "\n" + rule + "\n" + summary + "\n" + body + "\n" + hint
}

// renderDetailContent returns the scrollable body portion of the detail view.
func (m ConnectionsModel) renderDetailContent() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	if m.cursor < 0 || m.cursor >= len(m.connections) {
		return ""
	}
	conn := m.connections[m.cursor]

	detailCardW := w - 8
	if detailCardW > styles.MaxCardWidth+10 {
		detailCardW = styles.MaxCardWidth + 10
	}

	labelStyle := t.StatLabel.Copy().Width(14)
	valueStyle := t.Body

	var fields []string

	// Status with colored badge
	dot := statusDot(conn.Status, t)
	statusLabel := lipgloss.NewStyle().Foreground(styles.StatusAccentColor(t, conn.Status)).Render(conn.Status)
	fields = append(fields, labelStyle.Render("Status")+"  "+dot+" "+statusLabel)

	fields = append(fields, labelStyle.Render("Type")+"  "+valueStyle.Render(conn.Type))

	if conn.URL != "" {
		fields = append(fields, labelStyle.Render("URL")+"  "+valueStyle.Render(conn.URL))
	}

	if conn.LastChecked > 0 {
		checked := time.Unix(conn.LastChecked, 0).Format("2006-01-02 15:04:05")
		fields = append(fields, labelStyle.Render("Last Checked")+"  "+valueStyle.Render(checked))
	}

	if conn.Error != "" {
		errStyle := lipgloss.NewStyle().Foreground(t.Danger)
		fields = append(fields, labelStyle.Render("Error")+"  "+errStyle.Render(conn.Error))
	}

	// Metadata key-value pairs
	if len(conn.Metadata) > 0 {
		fields = append(fields, "")
		fields = append(fields, lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render("Metadata"))

		// Sort keys for stable output
		metaKeys := make([]string, 0, len(conn.Metadata))
		for k := range conn.Metadata {
			metaKeys = append(metaKeys, k)
		}
		sort.Strings(metaKeys)

		for _, k := range metaKeys {
			fields = append(fields, labelStyle.Render(k)+"  "+t.Dim.Render(conn.Metadata[k]))
		}
	}

	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Separator).
		Width(detailCardW).
		Padding(1, 2).
		MarginLeft(2).
		Render(strings.Join(fields, "\n"))
}

// viewDetail renders full info for the selected connection.
func (m ConnectionsModel) viewDetail() string {
	t := m.theme
	w := m.width
	if w < 20 {
		w = 20
	}

	if m.cursor < 0 || m.cursor >= len(m.connections) {
		m.summaryMode = true
		return m.viewSummary()
	}
	conn := m.connections[m.cursor]

	dot := statusDot(conn.Status, t)
	header := t.SectionHeader.Copy().PaddingLeft(2).
		Render(dot + " " + strings.ToUpper(conn.Name))

	rule := t.Faint.Render(strings.Repeat("─", w))

	back := zone.Mark("conn-detail-back", lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).
		Render("esc to go back"))

	// Render scrollable body and apply scroll offset
	body := m.renderDetailContent()
	lines := strings.Split(body, "\n")
	viewport := m.height - 5
	if viewport < 1 {
		viewport = 1
	}
	if m.scrollOffset > 0 && m.scrollOffset < len(lines) {
		lines = lines[m.scrollOffset:]
	}
	if len(lines) > viewport {
		lines = lines[:viewport]
	}
	body = strings.Join(lines, "\n")

	return header + "\n" + rule + "\n" + back + "\n\n" + body
}
