package remote

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/styles"
)

type saveResultMsg struct{ err error }

// SaveModel writes the config and shows a completion screen.
type SaveModel struct {
	theme      styles.Theme
	config     Config
	configPath string
	spinner    spinner.Model
	saving     bool
	done       bool
	err        error
	width      int
	height     int
}

func NewSaveModel(theme styles.Theme) SaveModel {
	s := spinner.New()
	s.Spinner = spinner.Dot
	s.Style = lipgloss.NewStyle().Foreground(theme.Primary)
	return SaveModel{
		theme:   theme,
		spinner: s,
	}
}

func (m SaveModel) Init() tea.Cmd {
	return nil
}

// StartSave begins the save operation. Called by the wizard when entering this step.
func (m SaveModel) StartSave() tea.Cmd {
	return tea.Batch(
		m.spinner.Tick,
		m.doSave(),
	)
}

func (m SaveModel) doSave() tea.Cmd {
	path := m.configPath
	cfg := m.config
	return func() tea.Msg {
		err := SaveConfig(path, cfg)
		return saveResultMsg{err: err}
	}
}

func (m SaveModel) Update(msg tea.Msg) (SaveModel, tea.Cmd) {
	switch msg := msg.(type) {
	case saveResultMsg:
		m.saving = false
		m.done = true
		m.err = msg.err
		return m, nil

	case spinner.TickMsg:
		if m.saving {
			var cmd tea.Cmd
			m.spinner, cmd = m.spinner.Update(msg)
			return m, cmd
		}
		return m, nil

	case tea.KeyMsg:
		if m.done {
			switch msg.String() {
			case "enter", "q":
				return m, tea.Quit
			}
		}
	}
	return m, nil
}

func (m *SaveModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

func (m *SaveModel) SetConfig(cfg Config) {
	m.config = cfg
	m.saving = true
	m.done = false
	m.err = nil
}

func (m *SaveModel) SetConfigPath(path string) {
	m.configPath = path
}

func (m SaveModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}

	var content string
	if m.saving || (!m.done && m.err == nil) {
		content = strings.Join([]string{
			"",
			m.spinner.View() + " Saving configuration...",
		}, "\n")
	} else if m.err != nil {
		errIcon := lipgloss.NewStyle().Foreground(t.Danger).Bold(true).Render("✗")
		errMsg := t.RenderDanger(fmt.Sprintf("Failed to save: %v", m.err))
		hint := t.RenderDim("Press q to exit")
		content = strings.Join([]string{
			"",
			errIcon + " " + errMsg,
			"",
			hint,
		}, "\n")
	} else {
		check := lipgloss.NewStyle().Foreground(t.Success).Bold(true).Render("✓")
		saved := t.RenderBold("Configuration saved!")
		path := t.RenderDim(m.configPath)
		cmd := lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("doey remote <project>")
		hint := t.RenderDim("Press Enter or q to exit")

		content = strings.Join([]string{
			"",
			check + "  " + saved,
			"",
			"   Saved to: " + path,
			"",
			"   Run " + cmd + " to get started!",
			"",
			"",
			hint,
		}, "\n")
	}

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Padding(1, 3).
		Render(content)
}
