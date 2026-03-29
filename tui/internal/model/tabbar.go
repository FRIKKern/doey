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
	Icon        string
	HasActivity bool
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

// View renders the tab bar.
func (m TabBarModel) View() string {
	if len(m.tabs) == 0 {
		return ""
	}

	t := m.theme
	sepStyle := lipgloss.NewStyle().Foreground(t.Muted).Faint(true)
	activityDot := lipgloss.NewStyle().Foreground(t.Warning).Render("●")

	// Calculate available width for tab labels
	availWidth := m.width
	if availWidth < 20 {
		availWidth = 80 // fallback
	}

	// Determine if we need to truncate: each tab uses icon + name + padding
	truncate := false
	totalWidth := 2 // leading padding
	for i, tab := range m.tabs {
		w := len(tab.Icon) + 1 + len(tab.Name) + 8 // icon + space + name + padding (3 each side)
		if tab.HasActivity {
			w += 2 // dot + space
		}
		if i > 0 {
			w += 3 // separator " · "
		}
		totalWidth += w
	}
	if totalWidth > availWidth {
		truncate = true
	}

	var parts []string
	for i, tab := range m.tabs {
		label := tab.Icon + " " + tab.Name
		if truncate && len(tab.Name) > 4 {
			label = tab.Icon + " " + tab.Name[:3] + "…"
		}

		if tab.HasActivity && i != m.activeIndex {
			label = activityDot + " " + label
		}

		zoneID := fmt.Sprintf("tab-%d", i)
		if i == m.activeIndex {
			parts = append(parts, zone.Mark(zoneID, t.MenuActive.Padding(0, 3).Render(label)))
		} else {
			parts = append(parts, zone.Mark(zoneID, t.MenuInactive.Padding(0, 3).Render(label)))
		}
	}

	menu := "  " + strings.Join(parts, sepStyle.Render("·"))

	rule := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Width(m.width).
		Render(strings.Repeat("─", m.width))

	return menu + "\n" + rule
}
