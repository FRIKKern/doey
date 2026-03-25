package model

import (
	"github.com/charmbracelet/bubbles/help"
	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// FooterModel displays keyboard help at the bottom of the dashboard.
type FooterModel struct {
	help     help.Model
	keyMap   keys.KeyMap
	showFull bool
	theme    styles.Theme
	width    int
}

// NewFooterModel creates a footer with short help visible.
func NewFooterModel() FooterModel {
	t := styles.DefaultTheme()
	h := help.New()
	h.Styles.ShortKey = lipgloss.NewStyle().Foreground(t.Primary)
	h.Styles.ShortDesc = lipgloss.NewStyle().Foreground(t.Muted)
	h.Styles.FullKey = lipgloss.NewStyle().Foreground(t.Primary)
	h.Styles.FullDesc = lipgloss.NewStyle().Foreground(t.Muted)

	return FooterModel{
		help:   h,
		keyMap: keys.DefaultKeyMap(),
		theme:  t,
	}
}

// Init is a no-op for the footer sub-model.
func (m FooterModel) Init() tea.Cmd {
	return nil
}

// Update handles the help toggle key.
func (m FooterModel) Update(msg tea.Msg) (FooterModel, tea.Cmd) {
	if msg, ok := msg.(tea.KeyMsg); ok {
		if key.Matches(msg, m.keyMap.Help) {
			m.showFull = !m.showFull
		}
	}
	return m, nil
}

// SetWidth sets the available width for rendering.
func (m *FooterModel) SetWidth(w int) {
	m.width = w
	m.help.Width = w - 2
}

// View renders the help footer.
func (m FooterModel) View() string {
	style := lipgloss.NewStyle().
		Width(m.width).
		Padding(0, 1).
		BorderStyle(lipgloss.NormalBorder()).
		BorderTop(true).
		BorderForeground(m.theme.Muted)

	if m.showFull {
		return style.Render(m.help.FullHelpView(m.keyMap.FullHelp()))
	}
	return style.Render(m.help.ShortHelpView(m.keyMap.ShortHelp()))
}
