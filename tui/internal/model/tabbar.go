package model

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/styles"
)

// TabItem represents a single tab in the bar.
type TabItem struct {
	Name        string
	HasActivity bool
	Closeable   bool
	WindowIdx   int // tmux window index for team tabs, -1 for static panels
}

// TabBarModel renders a horizontal tab bar with active/inactive styling.
type TabBarModel struct {
	tabs        []TabItem
	activeIndex int
	width       int
	theme       styles.Theme
}

// NewTabBarModel creates a tab bar with the given items.
func NewTabBarModel(tabs []TabItem) TabBarModel {
	return TabBarModel{
		tabs:  tabs,
		theme: styles.DefaultTheme(),
	}
}

// SetActive sets the active tab index.
func (m *TabBarModel) SetActive(idx int) {
	if idx >= 0 && idx < len(m.tabs) {
		m.activeIndex = idx
	}
}

// SetWidth sets the available rendering width.
func (m *TabBarModel) SetWidth(w int) {
	m.width = w
}

// SetActivity marks a tab as having pending updates.
func (m *TabBarModel) SetActivity(idx int, active bool) {
	if idx >= 0 && idx < len(m.tabs) {
		m.tabs[idx].HasActivity = active
	}
}

// ActiveIndex returns the currently active tab.
func (m TabBarModel) ActiveIndex() int {
	return m.activeIndex
}

// Next advances to the next tab, wrapping around.
func (m *TabBarModel) Next() {
	m.activeIndex = (m.activeIndex + 1) % len(m.tabs)
}

// Prev moves to the previous tab, wrapping around.
func (m *TabBarModel) Prev() {
	m.activeIndex = (m.activeIndex + len(m.tabs) - 1) % len(m.tabs)
}

// AddTab appends a tab to the bar.
func (m *TabBarModel) AddTab(tab TabItem) {
	m.tabs = append(m.tabs, tab)
}

// RemoveTab removes the tab at index and clamps the active index.
func (m *TabBarModel) RemoveTab(index int) {
	if index < 0 || index >= len(m.tabs) {
		return
	}
	m.tabs = append(m.tabs[:index], m.tabs[index+1:]...)
	if m.activeIndex >= len(m.tabs) {
		m.activeIndex = len(m.tabs) - 1
	}
	if m.activeIndex < 0 {
		m.activeIndex = 0
	}
}

// CloseableCount returns the number of closeable tabs.
func (m TabBarModel) CloseableCount() int {
	n := 0
	for _, t := range m.tabs {
		if t.Closeable {
			n++
		}
	}
	return n
}

// TabCount returns the total number of tabs.
func (m TabBarModel) TabCount() int {
	return len(m.tabs)
}

// View renders the tab bar as pill-shaped cards.
func (m TabBarModel) View() string {
	if len(m.tabs) == 0 {
		return ""
	}

	t := m.theme

	activeStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(t.BgText).
		Background(t.Primary).
		Padding(0, 2).
		MarginRight(1)

	inactiveStyle := lipgloss.NewStyle().
		Foreground(t.Muted).
		Padding(0, 2).
		MarginRight(1)

	activityDot := lipgloss.NewStyle().Foreground(t.Warning).Render("*")

	closeStyle := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true)

	closeActiveStyle := lipgloss.NewStyle().
		Foreground(t.Danger).
		Faint(true)

	var parts []string
	for i, tab := range m.tabs {
		label := tab.Name
		if tab.HasActivity && i != m.activeIndex {
			label = activityDot + " " + label
		}

		var closeBtn string
		if tab.Closeable {
			closeZoneID := fmt.Sprintf("tab-close-%d", i)
			cs := closeStyle
			if i == m.activeIndex {
				cs = closeActiveStyle
			}
			closeBtn = zone.Mark(closeZoneID, cs.Render(" ×"))
		}

		zoneID := fmt.Sprintf("tab-%d", i)
		if i == m.activeIndex {
			parts = append(parts, zone.Mark(zoneID, activeStyle.Render(label))+closeBtn)
		} else {
			parts = append(parts, zone.Mark(zoneID, inactiveStyle.Render(label))+closeBtn)
		}
	}

	// "+" button for adding a team window
	addStyle := lipgloss.NewStyle().
		Foreground(t.Muted).
		Padding(0, 1).
		MarginLeft(1)
	parts = append(parts, zone.Mark("tab-add", addStyle.Render("+")))

	menu := "  " + strings.Join(parts, "")

	rule := lipgloss.NewStyle().
		Foreground(t.Separator).
		Width(m.width).
		Render(strings.Repeat("─", m.width))

	return menu + "\n" + rule
}
