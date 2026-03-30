package remote

import (
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/styles"
)

type authOption struct {
	method string // "oauth", "apikey", "env"
	label  string
	desc   string
	tag    string // e.g., "Recommended"
}

var authOptions = []authOption{
	{
		method: "oauth",
		label:  "OAuth (browser login)",
		desc:   "Claude will open a browser to authenticate.",
		tag:    "Recommended",
	},
	{
		method: "apikey",
		label:  "API Key",
		desc:   "Paste your Anthropic API key.",
		tag:    "",
	},
	{
		method: "env",
		label:  "Environment Variable",
		desc:   "Set $ANTHROPIC_API_KEY on the remote server.",
		tag:    "",
	},
}

// AuthModel handles Claude Code authentication method selection.
type AuthModel struct {
	theme  styles.Theme
	width  int
	height int

	cursor    int
	selected  bool
	input     textinput.Model
	showInput bool
	errMsg    string

	method string
	value  string
}

// NewAuthModel creates the auth method picker screen.
func NewAuthModel(theme styles.Theme, cfg Config) AuthModel {
	ti := textinput.New()
	ti.Placeholder = "sk-ant-..."
	ti.EchoMode = textinput.EchoPassword
	ti.EchoCharacter = '*'
	ti.CharLimit = 256

	// Pre-select from config
	cursor := 0
	for i, opt := range authOptions {
		if opt.method == cfg.AuthMethod {
			cursor = i
			break
		}
	}

	return AuthModel{
		theme:  theme,
		cursor: cursor,
		input:  ti,
		method: cfg.AuthMethod,
		value:  cfg.AuthValue,
	}
}

func (m AuthModel) Init() tea.Cmd { return nil }

func (m AuthModel) Update(msg tea.Msg) (AuthModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		// If text input is active, handle that first
		if m.showInput {
			switch msg.String() {
			case "esc":
				m.showInput = false
				m.selected = false
				m.input.Blur()
				return m, nil
			case "enter":
				val := strings.TrimSpace(m.input.Value())
				if val == "" {
					m.errMsg = "API key cannot be empty"
					return m, nil
				}
				m.errMsg = ""
				m.value = val
				m.method = "apikey"
				return m, func() tea.Msg { return NextStepMsg{} }
			}
			var cmd tea.Cmd
			m.input, cmd = m.input.Update(msg)
			return m, cmd
		}

		switch msg.String() {
		case "esc":
			return m, func() tea.Msg { return PrevStepMsg{} }
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(authOptions)-1 {
				m.cursor++
			}
		case "enter":
			opt := authOptions[m.cursor]
			m.method = opt.method
			if opt.method == "apikey" {
				m.showInput = true
				m.selected = true
				m.input.Focus()
				return m, textinput.Blink
			}
			// oauth or env — no extra input needed
			m.value = ""
			return m, func() tea.Msg { return NextStepMsg{} }
		}
	}
	return m, nil
}

// AuthMethod returns the selected auth method.
func (m AuthModel) AuthMethod() string { return m.method }

// AuthValue returns the auth value (API key, if applicable).
func (m AuthModel) AuthValue() string { return m.value }

func (m *AuthModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.input.Width = w - 10
}

func (m AuthModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}

	title := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		Render("Claude Code Authentication")

	hint := lipgloss.NewStyle().
		Foreground(t.Muted).
		Render("How should the remote server authenticate with Claude?")

	var optLines []string
	for i, opt := range authOptions {
		prefix := "  "
		labelStyle := lipgloss.NewStyle().Foreground(t.Text)
		if i == m.cursor {
			prefix = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("› ")
			labelStyle = labelStyle.Bold(true)
		}

		label := labelStyle.Render(opt.label)
		if opt.tag != "" {
			label += " " + lipgloss.NewStyle().
				Foreground(t.Success).
				Render("["+opt.tag+"]")
		}

		desc := lipgloss.NewStyle().
			Foreground(t.Muted).
			Render("    " + opt.desc)

		optLines = append(optLines, prefix+label)
		optLines = append(optLines, desc)
		optLines = append(optLines, "")
	}

	options := strings.Join(optLines, "\n")

	var extra string
	if m.showInput {
		extra = "\n" + lipgloss.NewStyle().Foreground(t.Text).Bold(true).Render("API Key:") +
			"\n" + m.input.View()
		if m.errMsg != "" {
			extra += "\n" + lipgloss.NewStyle().Foreground(t.Danger).Render("  "+m.errMsg)
		}
		extra += "\n" + lipgloss.NewStyle().Foreground(t.Muted).Render("Press Enter to confirm, Esc to cancel")
	}

	nav := lipgloss.NewStyle().Foreground(t.Muted).Render("j/k navigate  |  Enter select  |  Esc back")

	content := strings.Join([]string{
		"",
		title,
		"",
		hint,
		"",
		options,
		extra,
		"",
		nav,
	}, "\n")

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Padding(1, 3).
		Render(content)
}
