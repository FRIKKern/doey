package model

import (
	"strings"

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

// NewFooterModel creates a footer with minimal short help visible.
func NewFooterModel() FooterModel {
	t := styles.DefaultTheme()
	h := help.New()
	h.Styles.ShortKey = lipgloss.NewStyle().Foreground(t.Text)
	h.Styles.ShortDesc = lipgloss.NewStyle().Foreground(t.Muted)
	h.Styles.FullKey = lipgloss.NewStyle().Foreground(t.Text)
	h.Styles.FullDesc = lipgloss.NewStyle().Foreground(t.Muted)
	h.ShortSeparator = " · "
	h.FullSeparator = "   "

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

	// Render short help with " · " separators in faint style
	bindings := m.keyMap.ShortHelp()
	var parts []string
	keyStyle := lipgloss.NewStyle().Foreground(m.theme.Text)
	descStyle := lipgloss.NewStyle().Foreground(m.theme.Muted)
	for _, b := range bindings {
		k := keyStyle.Render(b.Help().Key)
		d := descStyle.Render(b.Help().Desc)
		parts = append(parts, k+" "+d)
	}
	sep := m.theme.Faint.Render(" · ")
	return style.Render(strings.Join(parts, sep))
}
