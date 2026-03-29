package remote

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// WelcomeModel renders the first screen of the remote setup wizard.
type WelcomeModel struct {
	theme  styles.Theme
	width  int
	height int
}

func NewWelcomeModel(theme styles.Theme) WelcomeModel {
	return WelcomeModel{theme: theme}
}

func (m WelcomeModel) Init() tea.Cmd { return nil }

func (m WelcomeModel) Update(msg tea.Msg) (WelcomeModel, tea.Cmd) {
	if msg, ok := msg.(tea.KeyMsg); ok {
		switch msg.String() {
		case "enter":
			return m, func() tea.Msg { return NextStepMsg{} }
		}
	}
	return m, nil
}

func (m *WelcomeModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

func (m WelcomeModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}

	title := lipgloss.NewStyle().
		Foreground(t.Accent).
		Bold(true).
		Render("Doey Remote Setup")

	subtitle := lipgloss.NewStyle().
		Foreground(t.Text).
		Render("Configure cloud compute for remote Doey sessions.")

	items := []string{
		"Cloud provider (Hetzner)",
		"API credentials",
		"SSH key configuration",
		"Server preferences (region, type)",
	}
	bullet := lipgloss.NewStyle().Foreground(t.Primary).Render("  *  ")
	var bullets []string
	for _, item := range items {
		bullets = append(bullets, bullet+lipgloss.NewStyle().Foreground(t.Text).Render(item))
	}

	listHeader := lipgloss.NewStyle().
		Foreground(t.Text).
		Bold(true).
		Render("This wizard will help you set up:")

	hint := lipgloss.NewStyle().
		Foreground(t.Muted).
		Render("Press Enter to begin ->")

	content := strings.Join([]string{
		"",
		title,
		"",
		subtitle,
		"",
		listHeader,
		"",
		strings.Join(bullets, "\n"),
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
