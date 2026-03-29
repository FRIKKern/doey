package remote

import tea "github.com/charmbracelet/bubbletea"

// Step represents a page in the remote setup wizard.
type Step int

const (
	StepWelcome Step = iota
	StepProvider
	StepToken
	StepSSHKey
	StepDefaults
	StepAuth
	StepSummary
	StepSave
	StepDone
)

// StepName returns the human-readable name for a wizard step.
func StepName(s Step) string {
	names := []string{"Welcome", "Provider", "API Token", "SSH Key", "Server", "Auth", "Summary", "Save", "Done"}
	if s >= 0 && int(s) < len(names) {
		return names[s]
	}
	return "Unknown"
}

// StepCount returns the total number of wizard steps (excluding StepDone).
func StepCount() int { return int(StepDone) }

// Navigation messages for step transitions.
type NextStepMsg struct{}
type PrevStepMsg struct{}
type GoToStepMsg struct{ Step Step }

func NextStep() tea.Msg { return NextStepMsg{} }
func PrevStep() tea.Msg { return PrevStepMsg{} }
