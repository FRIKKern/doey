package remote

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/remote/hetzner"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// Token validation messages.
type (
	ValidateTokenMsg struct{}
	TokenValidMsg    struct{}
	TokenErrorMsg    struct{ Err error }
	tokenAutoAdvance struct{}
)

// TokenModel handles API token input with live validation.
type TokenModel struct {
	theme      styles.Theme
	provider   hetzner.Provider
	width      int
	height     int
	input      textinput.Model
	spinner    spinner.Model
	validating bool
	validated  bool
	errMsg     string
	token      string
}

// NewTokenModel creates a token input screen.
func NewTokenModel(theme styles.Theme, provider hetzner.Provider, cfg Config) TokenModel {
	ti := textinput.New()
	ti.Placeholder = "Paste your Hetzner API token here"
	ti.EchoMode = textinput.EchoPassword
	ti.EchoCharacter = '*'
	ti.CharLimit = 128
	ti.Focus()
	if cfg.APIToken != "" {
		ti.SetValue(cfg.APIToken)
	}

	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(theme.Primary)

	return TokenModel{
		theme:    theme,
		provider: provider,
		input:    ti,
		spinner:  sp,
	}
}

func (m TokenModel) Init() tea.Cmd {
	return textinput.Blink
}

func (m TokenModel) Update(msg tea.Msg) (TokenModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if m.validating {
			return m, nil
		}
		switch msg.String() {
		case "esc":
			return m, func() tea.Msg { return PrevStepMsg{} }
		case "enter":
			val := strings.TrimSpace(m.input.Value())
			if val == "" {
				m.errMsg = "Token cannot be empty"
				return m, nil
			}
			m.validating = true
			m.errMsg = ""
			m.validated = false
			token := val
			return m, tea.Batch(m.spinner.Tick, m.validateToken(token))
		}

	case TokenValidMsg:
		m.validating = false
		m.validated = true
		m.token = strings.TrimSpace(m.input.Value())
		return m, tea.Tick(time.Second, func(time.Time) tea.Msg {
			return tokenAutoAdvance{}
		})

	case TokenErrorMsg:
		m.validating = false
		m.validated = false
		m.errMsg = msg.Err.Error()
		m.input.Focus()
		return m, textinput.Blink

	case tokenAutoAdvance:
		if m.validated {
			return m, func() tea.Msg { return NextStepMsg{} }
		}
		return m, nil

	case spinner.TickMsg:
		if m.validating {
			var cmd tea.Cmd
			m.spinner, cmd = m.spinner.Update(msg)
			return m, cmd
		}
		return m, nil
	}

	if !m.validating && !m.validated {
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m TokenModel) validateToken(token string) tea.Cmd {
	return func() tea.Msg {
		if m.provider == nil {
			return TokenErrorMsg{Err: fmt.Errorf("no cloud provider configured")}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := m.provider.ValidateToken(ctx, token); err != nil {
			return TokenErrorMsg{Err: err}
		}
		return TokenValidMsg{}
	}
}

// Token returns the validated token value.
func (m TokenModel) Token() string { return m.token }

func (m *TokenModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.input.Width = w - 10
}

func (m TokenModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}

	title := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		Render("API Token")

	hint := lipgloss.NewStyle().
		Foreground(t.Muted).
		Render("Create a token at console.hetzner.cloud -> Security -> API Tokens\nThe token needs Read & Write permissions.")

	var status string
	if m.validating {
		status = m.spinner.View() + lipgloss.NewStyle().Foreground(t.Primary).Render(" Validating token...")
	} else if m.validated {
		status = lipgloss.NewStyle().Foreground(t.Success).Bold(true).Render("  Token valid")
	} else if m.errMsg != "" {
		status = t.RenderDanger("  " + m.errMsg)
	}

	nav := t.RenderDim("Enter to validate  |  Esc to go back")

	content := strings.Join([]string{
		"",
		title,
		"",
		hint,
		"",
		m.input.View(),
		"",
		status,
		"",
		"",
		nav,
	}, "\n")

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Padding(1, 3).
		Render(content)
}
