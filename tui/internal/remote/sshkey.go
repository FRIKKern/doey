package remote

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/remote/hetzner"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// SSHKeyInfo describes a discovered SSH public key.
type SSHKeyInfo struct {
	Path        string
	Name        string
	Fingerprint string
}

// SSH key messages.
type (
	SSHKeysFoundMsg    struct{ Keys []SSHKeyInfo }
	SSHKeyGeneratedMsg struct{ Key SSHKeyInfo }
	SSHKeyUploadedMsg  struct{}
	SSHKeyErrorMsg     struct{ Err error }
)

// SSHKeyModel handles SSH key detection, selection, generation, and upload.
type SSHKeyModel struct {
	theme    styles.Theme
	provider hetzner.Provider
	token    string
	width    int
	height   int

	keys     []SSHKeyInfo
	cursor   int
	loaded   bool
	spinner  spinner.Model
	loading  bool // scanning or generating
	errMsg   string
	selected SSHKeyInfo
	done     bool
}

// NewSSHKeyModel creates an SSH key picker screen.
func NewSSHKeyModel(theme styles.Theme, provider hetzner.Provider, token string, cfg Config) SSHKeyModel {
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(theme.Primary)

	return SSHKeyModel{
		theme:    theme,
		provider: provider,
		token:    token,
		spinner:  sp,
	}
}

func (m SSHKeyModel) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, scanSSHKeys)
}

func (m SSHKeyModel) Update(msg tea.Msg) (SSHKeyModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if m.loading || m.done {
			return m, nil
		}
		switch msg.String() {
		case "esc":
			return m, func() tea.Msg { return PrevStepMsg{} }
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			total := len(m.keys) + 1 // +1 for generate option
			if m.cursor < total-1 {
				m.cursor++
			}
		case "enter":
			if m.cursor < len(m.keys) {
				// Selected existing key
				m.selected = m.keys[m.cursor]
				m.loading = true
				m.errMsg = ""
				return m, tea.Batch(m.spinner.Tick, m.uploadKey(m.selected))
			}
			// Generate new key
			m.loading = true
			m.errMsg = ""
			return m, tea.Batch(m.spinner.Tick, generateSSHKey)
		}

	case SSHKeysFoundMsg:
		m.keys = msg.Keys
		m.loaded = true
		m.loading = false
		return m, nil

	case SSHKeyGeneratedMsg:
		m.selected = msg.Key
		return m, m.uploadKey(msg.Key)

	case SSHKeyUploadedMsg:
		m.loading = false
		m.done = true
		return m, tea.Tick(500*time.Millisecond, func(time.Time) tea.Msg {
			return NextStepMsg{}
		})

	case SSHKeyErrorMsg:
		m.loading = false
		errStr := msg.Err.Error()
		// Key already exists on provider — treat as success
		if strings.Contains(errStr, "already") || strings.Contains(errStr, "uniqueness_error") {
			m.done = true
			return m, tea.Tick(500*time.Millisecond, func(time.Time) tea.Msg {
				return NextStepMsg{}
			})
		}
		m.errMsg = errStr
		return m, nil

	case spinner.TickMsg:
		if m.loading {
			var cmd tea.Cmd
			m.spinner, cmd = m.spinner.Update(msg)
			return m, cmd
		}
		return m, nil
	}
	return m, nil
}

// SelectedKey returns the chosen SSH key info.
func (m SSHKeyModel) SelectedKey() SSHKeyInfo { return m.selected }

func (m *SSHKeyModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetToken updates the API token (called when advancing from token step).
func (m *SSHKeyModel) SetToken(token string) {
	m.token = token
}

func (m SSHKeyModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}

	title := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		Render("SSH Key")

	hint := lipgloss.NewStyle().
		Foreground(t.Muted).
		Render("Select an SSH key for server access, or generate a new one.")

	var body string
	if !m.loaded && !m.loading {
		body = m.spinner.View() + " Scanning SSH keys..."
	} else if m.loading {
		if m.selected.Path != "" {
			body = m.spinner.View() + " Uploading key to Hetzner..."
		} else {
			body = m.spinner.View() + " Generating SSH key..."
		}
	} else if m.done {
		body = lipgloss.NewStyle().Foreground(t.Success).Bold(true).
			Render("  Key configured")
	} else {
		body = m.renderKeyList()
	}

	var status string
	if m.errMsg != "" {
		status = lipgloss.NewStyle().Foreground(t.Danger).Render("  " + m.errMsg)
	}

	nav := lipgloss.NewStyle().Foreground(t.Muted).Render("j/k navigate  |  Enter select  |  Esc back")

	content := strings.Join([]string{
		"",
		title,
		"",
		hint,
		"",
		body,
		"",
		status,
		"",
		nav,
	}, "\n")

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Padding(1, 3).
		Render(content)
}

func (m SSHKeyModel) renderKeyList() string {
	t := m.theme
	var lines []string

	if len(m.keys) == 0 {
		lines = append(lines, lipgloss.NewStyle().Foreground(t.Warning).
			Render("  No SSH keys found in ~/.ssh/"))
		lines = append(lines, "")
	}

	for i, key := range m.keys {
		prefix := "  "
		style := lipgloss.NewStyle().Foreground(t.Text)
		if i == m.cursor {
			prefix = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("> ")
			style = style.Bold(true)
		}
		name := style.Render(key.Name)
		fp := lipgloss.NewStyle().Foreground(t.Muted).Render("  " + key.Fingerprint)
		lines = append(lines, prefix+name+fp)
	}

	// Generate option
	genIdx := len(m.keys)
	prefix := "  "
	style := lipgloss.NewStyle().Foreground(t.Accent)
	if m.cursor == genIdx {
		prefix = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("> ")
		style = style.Bold(true)
	}
	lines = append(lines, "")
	lines = append(lines, prefix+style.Render("Generate new SSH key"))

	return strings.Join(lines, "\n")
}

func (m SSHKeyModel) uploadKey(key SSHKeyInfo) tea.Cmd {
	return func() tea.Msg {
		pubData, err := os.ReadFile(key.Path)
		if err != nil {
			return SSHKeyErrorMsg{Err: fmt.Errorf("read public key: %w", err)}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := m.provider.UploadSSHKey(ctx, m.token, key.Name, strings.TrimSpace(string(pubData))); err != nil {
			return SSHKeyErrorMsg{Err: err}
		}
		return SSHKeyUploadedMsg{}
	}
}

func scanSSHKeys() tea.Msg {
	home, err := os.UserHomeDir()
	if err != nil {
		return SSHKeysFoundMsg{}
	}
	sshDir := filepath.Join(home, ".ssh")
	matches, err := filepath.Glob(filepath.Join(sshDir, "*.pub"))
	if err != nil || len(matches) == 0 {
		return SSHKeysFoundMsg{}
	}

	var keys []SSHKeyInfo
	for _, pub := range matches {
		name := strings.TrimSuffix(filepath.Base(pub), ".pub")
		fp := fingerprintKey(pub)
		keys = append(keys, SSHKeyInfo{
			Path:        pub,
			Name:        name,
			Fingerprint: fp,
		})
	}
	return SSHKeysFoundMsg{Keys: keys}
}

func fingerprintKey(pubPath string) string {
	out, err := exec.Command("ssh-keygen", "-lf", pubPath).Output()
	if err != nil {
		return "(unknown fingerprint)"
	}
	parts := strings.Fields(string(out))
	if len(parts) >= 2 {
		return parts[1]
	}
	return strings.TrimSpace(string(out))
}

func generateSSHKey() tea.Msg {
	home, err := os.UserHomeDir()
	if err != nil {
		return SSHKeyErrorMsg{Err: fmt.Errorf("home dir: %w", err)}
	}
	keyPath := filepath.Join(home, ".ssh", "doey_remote_ed25519")
	pubPath := keyPath + ".pub"

	// Check if already exists
	if _, err := os.Stat(pubPath); err == nil {
		fp := fingerprintKey(pubPath)
		return SSHKeyGeneratedMsg{Key: SSHKeyInfo{
			Path:        pubPath,
			Name:        "doey_remote_ed25519",
			Fingerprint: fp,
		}}
	}

	cmd := exec.Command("ssh-keygen", "-t", "ed25519", "-f", keyPath, "-N", "", "-C", "doey-remote")
	if err := cmd.Run(); err != nil {
		return SSHKeyErrorMsg{Err: fmt.Errorf("ssh-keygen: %w", err)}
	}

	fp := fingerprintKey(pubPath)
	return SSHKeyGeneratedMsg{Key: SSHKeyInfo{
		Path:        pubPath,
		Name:        "doey_remote_ed25519",
		Fingerprint: fp,
	}}
}
