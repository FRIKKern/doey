package remote

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// ProviderModel lets the user select a cloud provider.
type ProviderModel struct {
	theme  styles.Theme
	width  int
	height int
}

func NewProviderModel(theme styles.Theme) ProviderModel {
	return ProviderModel{theme: theme}
}

func (m ProviderModel) Init() tea.Cmd { return nil }

func (m ProviderModel) Update(msg tea.Msg) (ProviderModel, tea.Cmd) {
	if msg, ok := msg.(tea.KeyMsg); ok {
		switch msg.String() {
		case "enter":
			return m, func() tea.Msg { return NextStepMsg{} }
		case "esc":
			return m, func() tea.Msg { return PrevStepMsg{} }
		}
	}
	return m, nil
}

func (m *ProviderModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

func (m ProviderModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}

	title := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		Render("Select Cloud Provider")

	check := lipgloss.NewStyle().Foreground(t.Success).Bold(true).Render("[x]")
	providerName := lipgloss.NewStyle().Foreground(t.Text).Bold(true).Render(" Hetzner Cloud")
	providerDesc := lipgloss.NewStyle().Foreground(t.Muted).Render("      High-performance cloud servers in Europe and US")

	selected := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Primary).
		Padding(0, 2).
		Width(w - 10).
		Render(check + providerName + "\n" + providerDesc)

	note := lipgloss.NewStyle().
		Foreground(t.Muted).
		Italic(true).
		Render("More providers coming soon.")

	hint := lipgloss.NewStyle().
		Foreground(t.Muted).
		Render("Enter: continue  Esc: back")

	content := strings.Join([]string{
		"",
		title,
		"",
		selected,
		"",
		note,
		"",
		"",
		hint,
	}, "\n")

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Padding(1, 3).
		Render(content)
}
