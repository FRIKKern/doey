package setup

import (
	"encoding/json"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
)

// Step represents wizard steps.
type Step int

const (
	StepPreset Step = iota
	StepCustom
	StepSummary
)

// WizardModel is the root setup wizard.
type WizardModel struct {
	step       Step
	result     SetupResult
	presetForm *huh.Form
	customForm *huh.Form
	confirmed  bool
	quitting   bool
	width      int
	height     int

	// form state
	presetChoice string
	customTypes  []string
}

// NewWizard creates a new setup wizard model.
func NewWizard() WizardModel {
	m := WizardModel{
		step: StepPreset,
	}
	m.presetForm = m.buildPresetForm()
	return m
}

// Init implements tea.Model.
func (m WizardModel) Init() tea.Cmd {
	return m.presetForm.Init()
}

// Update implements tea.Model.
func (m WizardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			m.result.Cancelled = true
			m.quitting = true
			return m, tea.Quit
		}
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	}

	switch m.step {
	case StepPreset:
		form, cmd := m.presetForm.Update(msg)
		if f, ok := form.(*huh.Form); ok {
			m.presetForm = f
		}
		if m.presetForm.State == huh.StateCompleted {
			return m.handlePresetDone()
		}
		return m, cmd

	case StepCustom:
		if m.customForm != nil {
			form, cmd := m.customForm.Update(msg)
			if f, ok := form.(*huh.Form); ok {
				m.customForm = f
			}
			if m.customForm.State == huh.StateCompleted {
				return m.handleCustomDone()
			}
			return m, cmd
		}

	case StepSummary:
		if msg, ok := msg.(tea.KeyMsg); ok {
			switch msg.String() {
			case "enter", "y":
				m.confirmed = true
				m.quitting = true
				return m, tea.Quit
			case "b", "backspace":
				m.step = StepPreset
				m.presetForm = m.buildPresetForm()
				return m, m.presetForm.Init()
			}
		}
	}

	return m, nil
}

// View implements tea.Model.
func (m WizardModel) View() string {
	if m.quitting {
		return ""
	}

	titleStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("99")).
		MarginBottom(1)

	title := titleStyle.Render("◆ Doey Setup Wizard")

	switch m.step {
	case StepPreset:
		return fmt.Sprintf("%s\n\n%s", title, m.presetForm.View())
	case StepCustom:
		if m.customForm != nil {
			return fmt.Sprintf("%s\n\n%s", title, m.customForm.View())
		}
	case StepSummary:
		return fmt.Sprintf("%s\n\n%s", title, m.renderSummary())
	}

	return title
}

func (m *WizardModel) buildPresetForm() *huh.Form {
	return huh.NewForm(
		huh.NewGroup(
			huh.NewSelect[string]().
				Title("Choose a setup:").
				Options(
					huh.NewOption("Regular Setup — 2 regular teams (default)", "regular"),
					huh.NewOption("Reserved Freelancers + Regular Team — 1 freelancer pool (3×2) + 1 team", "freelancer_regular"),
					huh.NewOption("Custom Combination — mix and match teams", "custom"),
				).
				Value(&m.presetChoice),
		),
	).WithTheme(huh.ThemeCharm())
}

func (m WizardModel) handlePresetDone() (tea.Model, tea.Cmd) {
	switch m.presetChoice {
	case "regular":
		m.result.Teams = Presets["regular"]
		m.step = StepSummary
		return m, nil
	case "freelancer_regular":
		m.result.Teams = Presets["freelancer_regular"]
		m.step = StepSummary
		return m, nil
	case "custom":
		m.step = StepCustom
		m.customForm = m.buildCustomForm()
		return m, m.customForm.Init()
	}
	return m, nil
}

func (m *WizardModel) buildCustomForm() *huh.Form {
	return huh.NewForm(
		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title("Select team types to add:").
				Options(
					huh.NewOption("Regular Team (4 workers)", "regular"),
					huh.NewOption("Reserved Freelancers (3×2 grid, born reserved)", "freelancer"),
				).
				Value(&m.customTypes),
		),
	).WithTheme(huh.ThemeCharm())
}

func (m WizardModel) handleCustomDone() (tea.Model, tea.Cmd) {
	m.result.Teams = nil
	for i, t := range m.customTypes {
		switch t {
		case "regular":
			m.result.Teams = append(m.result.Teams, TeamEntry{
				Type:    "regular",
				Name:    fmt.Sprintf("Team %d", i+1),
				Workers: 4,
			})
		case "freelancer":
			m.result.Teams = append(m.result.Teams, TeamEntry{
				Type:    "freelancer",
				Name:    "Reserved Freelancers",
				Workers: 6,
			})
		}
	}
	if len(m.result.Teams) == 0 {
		m.result.Teams = Presets["regular"]
	}
	m.step = StepSummary
	return m, nil
}

func (m WizardModel) renderSummary() string {
	style := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		Padding(1, 2).
		BorderForeground(lipgloss.Color("99"))

	s := "Teams to create:\n\n"
	for i, t := range m.result.Teams {
		icon := "◆"
		if t.Type == "freelancer" {
			icon = "•"
		}
		s += fmt.Sprintf("  %s %d. %s (%s, %d workers)\n", icon, i+1, t.Name, t.Type, t.Workers)
	}
	s += "\nPress Enter to launch, b to go back, q to cancel"

	return style.Render(s)
}

// OutputResult writes the setup result as JSON to stdout.
func (m WizardModel) OutputResult() error {
	if m.result.Cancelled {
		os.Exit(1)
	}
	return json.NewEncoder(os.Stdout).Encode(m.result)
}

// Run executes the wizard and returns the result.
func Run() (SetupResult, error) {
	m := NewWizard()
	p := tea.NewProgram(m, tea.WithAltScreen())
	finalModel, err := p.Run()
	if err != nil {
		return SetupResult{Cancelled: true}, err
	}
	wm := finalModel.(WizardModel)
	return wm.result, nil
}
