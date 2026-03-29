package remote

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// SummaryModel displays all config choices for review before saving.
type SummaryModel struct {
	theme  styles.Theme
	config Config
	width  int
	height int
}

func NewSummaryModel(theme styles.Theme) SummaryModel {
	return SummaryModel{theme: theme}
}

func (m SummaryModel) Init() tea.Cmd { return nil }

func (m SummaryModel) Update(msg tea.Msg) (SummaryModel, tea.Cmd) {
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

func (m *SummaryModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

func (m *SummaryModel) SetConfig(cfg Config) {
	m.config = cfg
}

func (m SummaryModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}

	title := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		Render("Review Configuration")

	labelStyle := lipgloss.NewStyle().Foreground(t.Text).Bold(true).Width(16)
	valStyle := lipgloss.NewStyle().Foreground(t.Text)

	rows := []struct{ label, value string }{
		{"Provider", m.config.Provider},
		{"API Token", maskToken(m.config.APIToken)},
		{"SSH Key", m.config.SSHKeyPath},
		{"SSH Key Name", m.config.SSHKeyName},
		{"Region", m.config.Region},
		{"Server Type", m.config.ServerType},
		{"Auth Method", m.config.AuthMethod},
	}

	var table []string
	for _, r := range rows {
		if r.value == "" {
			r.value = lipgloss.NewStyle().Foreground(t.Muted).Render("(not set)")
		} else {
			r.value = valStyle.Render(r.value)
		}
		table = append(table, labelStyle.Render(r.label+":")+"  "+r.value)
	}

	cost := estimateMonthlyCost(m.config.ServerType)
	costLine := labelStyle.Render("Est. Cost:") + "  " +
		lipgloss.NewStyle().Foreground(t.Warning).Render(cost)
	table = append(table, "")
	table = append(table, costLine)

	configBox := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Muted).
		Padding(1, 2).
		Width(w - 10).
		Render(strings.Join(table, "\n"))

	hint := lipgloss.NewStyle().
		Foreground(t.Muted).
		Render("Enter: save  Esc: back")

	content := strings.Join([]string{
		"",
		title,
		"",
		configBox,
		"",
		hint,
	}, "\n")

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Padding(1, 3).
		Render(content)
}

// maskToken shows first 4 chars then asterisks.
func maskToken(token string) string {
	if len(token) <= 4 {
		return token
	}
	return token[:4] + strings.Repeat("*", len(token)-4)
}

// estimateMonthlyCost returns a rough monthly cost string for a server type.
func estimateMonthlyCost(serverType string) string {
	costs := map[string]string{
		"cx22":  "~$4.35/mo (2 vCPU, 4 GB)",
		"cx32":  "~$7.45/mo (4 vCPU, 8 GB)",
		"cx42":  "~$14.60/mo (8 vCPU, 16 GB)",
		"cx52":  "~$28.90/mo (16 vCPU, 32 GB)",
		"ccx13": "~$5.85/mo (2 vCPU, 8 GB, dedicated)",
		"ccx23": "~$11.45/mo (4 vCPU, 16 GB, dedicated)",
		"ccx33": "~$22.60/mo (8 vCPU, 32 GB, dedicated)",
		"cax11": "~$3.85/mo (2 vCPU, 4 GB, ARM)",
		"cax21": "~$6.40/mo (4 vCPU, 8 GB, ARM)",
		"cax31": "~$12.50/mo (8 vCPU, 16 GB, ARM)",
	}
	if c, ok := costs[serverType]; ok {
		return c
	}
	return fmt.Sprintf("(unknown for %q)", serverType)
}
