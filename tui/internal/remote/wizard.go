package remote

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// WizardModel is the root model for the doey remote setup wizard.
type WizardModel struct {
	theme       styles.Theme
	width       int
	height      int
	currentStep Step
	config      Config
	configPath  string

	welcome  WelcomeModel
	provider ProviderModel
	summary  SummaryModel
	save     SaveModel
}

// NewWizardModel creates the wizard with default config and all sub-models.
func NewWizardModel(configPath string) WizardModel {
	return NewWizard(styles.DefaultTheme(), DefaultConfig(), configPath)
}

// NewWizard creates the wizard with the given theme, config, and config path.
func NewWizard(theme styles.Theme, cfg Config, configPath string) WizardModel {
	return WizardModel{
		theme:      theme,
		config:     cfg,
		configPath: configPath,
		welcome:    NewWelcomeModel(theme),
		provider:   NewProviderModel(theme),
		summary:    NewSummaryModel(theme),
		save:       NewSaveModel(theme),
	}
}

func (m WizardModel) Init() tea.Cmd {
	return nil
}

func (m WizardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.propagateSizes()
		return m, nil

	case NextStepMsg:
		return m.advance()

	case PrevStepMsg:
		return m.retreat()

	case GoToStepMsg:
		m.currentStep = msg.Step
		return m.enterStep()

	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			return m, tea.Quit
		}
	}

	// Delegate to active step
	var cmd tea.Cmd
	switch m.currentStep {
	case StepWelcome:
		m.welcome, cmd = m.welcome.Update(msg)
	case StepProvider:
		m.provider, cmd = m.provider.Update(msg)
	case StepSummary:
		m.summary, cmd = m.summary.Update(msg)
	case StepSave:
		m.save, cmd = m.save.Update(msg)
	}
	return m, cmd
}

func (m WizardModel) View() string {
	if m.width == 0 {
		return "\n  Loading..."
	}

	progress := m.renderProgress()
	body := m.renderActiveStep()
	hints := m.renderHints()

	return lipgloss.JoinVertical(lipgloss.Left, progress, body, hints)
}

// advance moves to the next step.
func (m WizardModel) advance() (tea.Model, tea.Cmd) {
	next := m.currentStep + 1
	// Skip steps that other workers will create (token, ssh, defaults, auth)
	// by jumping to the next step we handle.
	switch next {
	case StepToken, StepSSHKey, StepDefaults, StepAuth:
		// Skip to summary for now — these steps will be added later
		next = StepSummary
	}
	if next > StepSave {
		return m, tea.Quit
	}
	m.currentStep = next
	return m.enterStep()
}

// retreat moves to the previous step.
func (m WizardModel) retreat() (tea.Model, tea.Cmd) {
	prev := m.currentStep - 1
	// Skip unimplemented steps backwards too
	switch prev {
	case StepToken, StepSSHKey, StepDefaults, StepAuth:
		prev = StepProvider
	}
	if prev < StepWelcome {
		prev = StepWelcome
	}
	m.currentStep = prev
	return m.enterStep()
}

// enterStep initializes the current step.
func (m WizardModel) enterStep() (tea.Model, tea.Cmd) {
	m.propagateSizes()
	switch m.currentStep {
	case StepSummary:
		m.summary.SetConfig(m.config)
	case StepSave:
		m.save.SetConfig(m.config)
		m.save.SetConfigPath(m.configPath)
		return m, m.save.StartSave()
	}
	return m, nil
}

// propagateSizes distributes dimensions to sub-models.
func (m *WizardModel) propagateSizes() {
	progressH := 3 // progress bar height
	hintsH := 2    // bottom hints height
	bodyH := m.height - progressH - hintsH
	if bodyH < 5 {
		bodyH = 5
	}
	m.welcome.SetSize(m.width, bodyH)
	m.provider.SetSize(m.width, bodyH)
	m.summary.SetSize(m.width, bodyH)
	m.save.SetSize(m.width, bodyH)
}

// renderProgress draws the step indicator at the top.
func (m WizardModel) renderProgress() string {
	t := m.theme
	// Show only the steps we currently handle
	steps := []struct {
		step Step
		name string
	}{
		{StepWelcome, "Welcome"},
		{StepProvider, "Provider"},
		{StepToken, "Token"},
		{StepSSHKey, "SSH Key"},
		{StepDefaults, "Server"},
		{StepAuth, "Auth"},
		{StepSummary, "Summary"},
		{StepSave, "Save"},
	}

	activeStyle := lipgloss.NewStyle().Foreground(t.Primary).Bold(true)
	doneStyle := lipgloss.NewStyle().Foreground(t.Success)
	futureStyle := lipgloss.NewStyle().Foreground(t.Muted)
	dotStyle := lipgloss.NewStyle().Foreground(t.Muted).Faint(true)

	var parts []string
	for _, s := range steps {
		name := s.name
		if s.step == m.currentStep {
			parts = append(parts, activeStyle.Render(name))
		} else if s.step < m.currentStep {
			parts = append(parts, doneStyle.Render(name))
		} else {
			parts = append(parts, futureStyle.Render(name))
		}
	}

	bar := strings.Join(parts, dotStyle.Render(" . "))

	return lipgloss.NewStyle().
		Padding(1, 3, 0, 3).
		Width(m.width).
		Render(bar)
}

// renderActiveStep renders the body for the current step.
func (m WizardModel) renderActiveStep() string {
	switch m.currentStep {
	case StepWelcome:
		return m.welcome.View()
	case StepProvider:
		return m.provider.View()
	case StepSummary:
		return m.summary.View()
	case StepSave:
		return m.save.View()
	default:
		return lipgloss.NewStyle().
			Padding(2, 3).
			Foreground(m.theme.Muted).
			Render("(This step is not yet implemented)")
	}
}

// renderHints draws keybinding hints at the bottom.
func (m WizardModel) renderHints() string {
	t := m.theme
	hint := lipgloss.NewStyle().Foreground(t.Muted).Faint(true)
	return hint.Copy().
		Padding(0, 3).
		Width(m.width).
		Render("Ctrl+C: quit")
}
