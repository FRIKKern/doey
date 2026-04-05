package model

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// SplitPaneConfig holds per-tab configuration for the shared split-pane layout.
type SplitPaneConfig struct {
	CardHeight     int  // delegate item height: 3 (plans), 2 (tasks)
	HeaderLines    int  // lines above list: 1 (plans), 2 (tasks)
	HasSeparator   bool // render vertical separator between panels
	VPHeightOffset int  // viewport height = h - this
	VPWidthPad     int  // viewport width  = rightW - this
}

// MouseResult describes what the shared mouse handler detected.
type MouseResult struct {
	Handled    bool
	ClickedIdx int // ≥0 if a card was clicked, -1 otherwise
}

// SplitPaneModel manages shared state, sizing, focus, and navigation for a
// split-pane layout (list left, detail right). Tabs embed this model and add
// their own domain-specific fields and logic.
type SplitPaneModel struct {
	config         SplitPaneConfig
	list           list.Model
	detailViewport viewport.Model
	keyMap         keys.KeyMap
	theme          styles.Theme

	leftFocused  bool
	width        int
	height       int
	focused      bool
	panelOffsetY int
	statusMsg    string
}

// NewSplitPane creates a SplitPaneModel with the given theme, delegate, and config.
func NewSplitPane(theme styles.Theme, delegate list.ItemDelegate, cfg SplitPaneConfig) SplitPaneModel {
	l := list.New([]list.Item{}, delegate, 0, 0)
	l.SetShowTitle(false)
	l.SetShowStatusBar(false)
	l.SetShowFilter(false)
	l.SetShowHelp(false)
	l.SetShowPagination(true)
	l.KeyMap.CursorUp = key.NewBinding(key.WithKeys("k", "up"))
	l.KeyMap.CursorDown = key.NewBinding(key.WithKeys("j", "down"))

	vp := viewport.New(0, 0)
	vp.MouseWheelEnabled = true

	return SplitPaneModel{
		config:         cfg,
		theme:          theme,
		leftFocused:    true,
		detailViewport: vp,
		keyMap:         keys.DefaultKeyMap(),
		list:           l,
	}
}

// ---------- Sizing ----------

// SetSize updates dimensions and recalculates internal sizes.
func (m *SplitPaneModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	leftW := m.LeftWidth()
	m.list.SetSize(leftW, h-m.config.HeaderLines)
	rightW := m.RightWidth()
	vpH := h - m.config.VPHeightOffset
	if vpH < 1 {
		vpH = 1
	}
	m.detailViewport.Width = rightW - m.config.VPWidthPad
	m.detailViewport.Height = vpH
}

// SetFocused toggles focus state.
func (m *SplitPaneModel) SetFocused(focused bool) { m.focused = focused }

// SetPanelOffset sets the absolute Y offset of the panel top in the terminal.
func (m *SplitPaneModel) SetPanelOffset(y int) { m.panelOffsetY = y }

// LeftWidth returns the left panel width (40%, min 28).
func (m *SplitPaneModel) LeftWidth() int {
	leftW := m.width * 40 / 100
	if leftW < 28 {
		leftW = 28
	}
	return leftW
}

// RightWidth returns the right panel width, accounting for separator.
func (m *SplitPaneModel) RightWidth() int {
	rightW := m.width - m.LeftWidth()
	if m.config.HasSeparator {
		rightW--
	}
	if rightW < 24 {
		rightW = 24
	}
	return rightW
}

// ---------- Focus ----------

// FocusRight switches focus to the detail (right) panel and resets viewport scroll.
func (m *SplitPaneModel) FocusRight() {
	m.leftFocused = false
	m.detailViewport.GotoTop()
}

// FocusLeft switches focus to the list (left) panel.
func (m *SplitPaneModel) FocusLeft() { m.leftFocused = true }

// ---------- Content / Accessors ----------

// SetDetailContent sets the detail viewport's content.
func (m *SplitPaneModel) SetDetailContent(content string) {
	m.detailViewport.SetContent(content)
}

// SelectedIndex returns the currently selected list index.
func (m *SplitPaneModel) SelectedIndex() int { return m.list.Index() }

// ItemCount returns the number of items in the list.
func (m *SplitPaneModel) ItemCount() int { return len(m.list.Items()) }

// ---------- Input handling ----------

// HandleKeyMsg handles common split-pane key navigation (panel focus, detail scroll).
// Returns true if the key was consumed.
func (m *SplitPaneModel) HandleKeyMsg(msg tea.KeyMsg) (bool, tea.Cmd) {
	if m.leftFocused {
		if key.Matches(msg, m.keyMap.RightPanel) {
			m.FocusRight()
			return true, nil
		}
	} else {
		if key.Matches(msg, m.keyMap.LeftPanel) || key.Matches(msg, m.keyMap.Back) {
			m.leftFocused = true
			return true, nil
		}
		switch msg.String() {
		case "up", "k", "down", "j", "pgup", "pgdown", "home", "end":
			var cmd tea.Cmd
			m.detailViewport, cmd = m.detailViewport.Update(msg)
			return true, cmd
		}
	}
	return false, nil
}

// HandleMouseMsg handles mouse wheel routing and card click detection.
// The caller is responsible for acting on ClickedIdx (e.g., selecting the item
// and switching to detail view).
func (m *SplitPaneModel) HandleMouseMsg(msg tea.MouseMsg) (MouseResult, tea.Cmd) {
	result := MouseResult{ClickedIdx: -1}

	// Mouse wheel — route based on cursor X position
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp || msg.Button == tea.MouseButtonWheelDown {
			result.Handled = true
			if msg.X < m.LeftWidth() {
				var cmd tea.Cmd
				m.list, cmd = m.list.Update(msg)
				return result, cmd
			}
			var cmd tea.Cmd
			m.detailViewport, cmd = m.detailViewport.Update(msg)
			return result, cmd
		}
	}

	// Card clicks in left panel
	if msg.Action == tea.MouseActionRelease {
		leftW := m.LeftWidth()
		itemCount := m.ItemCount()
		if msg.X < leftW && itemCount > 0 {
			relY := msg.Y - m.panelOffsetY - m.config.HeaderLines
			if relY >= 0 {
				firstVisible := m.list.Paginator.Page * m.list.Paginator.PerPage
				index := firstVisible + relY/m.config.CardHeight
				perPage := m.list.Paginator.PerPage
				if index < firstVisible+perPage && index >= 0 && index < itemCount {
					result.Handled = true
					result.ClickedIdx = index
				}
			}
		}
	}

	return result, nil
}

// UpdateList delegates a message to the embedded list model.
func (m *SplitPaneModel) UpdateList(msg tea.Msg) tea.Cmd {
	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	return cmd
}

// ---------- Rendering ----------

// RenderLeftPanel renders a standard left panel frame with header, optional
// lines above/below the list, status message, and empty state.
func (m SplitPaneModel) RenderLeftPanel(header string, emptyState string, aboveList string, belowList string) string {
	t := m.theme
	w := m.LeftWidth()
	h := m.height
	if h < 10 {
		h = 10
	}

	headerLine := t.SectionHeader.Copy().Width(w).PaddingLeft(1).Render(header)

	if m.ItemCount() == 0 {
		content := headerLine
		if aboveList != "" {
			content += "\n" + aboveList
		}
		content += "\n" + emptyState
		if m.statusMsg != "" {
			content += "\n" + lipgloss.NewStyle().Foreground(t.Success).PaddingLeft(1).Render(m.statusMsg)
		}
		if belowList != "" {
			content += "\n" + belowList
		}
		return lipgloss.NewStyle().Width(w).Height(h).Render(content)
	}

	listH := h - m.config.HeaderLines
	if listH < 1 {
		listH = 1
	}
	l := m.list
	l.SetSize(w, listH)
	listView := l.View()

	content := headerLine
	if aboveList != "" {
		content += "\n" + aboveList
	}
	content += "\n" + listView

	if m.statusMsg != "" {
		content += "\n" + lipgloss.NewStyle().Foreground(t.Success).PaddingLeft(1).Render(m.statusMsg)
	}
	if belowList != "" {
		content += "\n" + belowList
	}

	return lipgloss.NewStyle().Width(w).Height(h).Render(content)
}

// RenderRightPanel renders the detail viewport with header, scroll percent,
// and optional extra content below.
func (m SplitPaneModel) RenderRightPanel(header string, emptyHint string, belowViewport string) string {
	t := m.theme
	w := m.RightWidth()
	h := m.height
	if h < 10 {
		h = 10
	}

	headerLine := t.SectionHeader.Copy().Width(w).PaddingLeft(1).Render(header)

	if m.SelectedIndex() < 0 || m.SelectedIndex() >= m.ItemCount() {
		hint := lipgloss.NewStyle().
			Foreground(t.Muted).
			Align(lipgloss.Center).
			Width(w).
			PaddingTop(4).
			Render(emptyHint)
		return lipgloss.NewStyle().Width(w).Height(h).Render(headerLine + "\n" + hint)
	}

	vpH := h - m.config.VPHeightOffset
	if vpH < 1 {
		vpH = 1
	}
	m.detailViewport.Width = w - m.config.VPWidthPad
	m.detailViewport.Height = vpH

	vpView := m.detailViewport.View()

	pct := m.detailViewport.ScrollPercent()
	hint := lipgloss.NewStyle().Foreground(t.Muted).Align(lipgloss.Right).Width(w - 2).
		Render(fmt.Sprintf("%.0f%%", pct*100))

	content := headerLine + "\n" + vpView + "\n" + hint

	if belowViewport != "" {
		content += "\n" + belowViewport
	}

	return lipgloss.NewStyle().Width(w).Height(h).Render(content)
}

// RenderPanels joins left and right panels, adding a vertical separator if configured.
func (m SplitPaneModel) RenderPanels(leftPanel, rightPanel string) string {
	if m.config.HasSeparator {
		h := m.height
		if h < 10 {
			h = 10
		}
		sep := lipgloss.NewStyle().
			Foreground(m.theme.Separator).
			Render(strings.Repeat("│\n", h-1) + "│")
		return lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, sep, rightPanel)
	}
	return lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, rightPanel)
}
