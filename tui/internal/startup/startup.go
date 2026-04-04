package startup

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/styles"
)

// Config holds the flags passed to the startup subcommand.
type Config struct {
	Session      string
	Dir          string
	Runtime      string
	ProgressFile string
	Timeout      time.Duration
}

// stepMsg carries a new STEP line read from the progress file.
type stepMsg struct {
	text string
}

// timeoutMsg signals the timeout has elapsed.
type timeoutMsg struct{}

// model is the Bubble Tea model for the startup screen.
type model struct {
	theme        styles.Theme
	config       Config
	width        int
	height       int
	ready        bool // terminal size received
	spinner      spinner.Model
	steps        []string // completed step descriptions
	currentStep  string   // currently active step
	done         bool
	exitCode     int
	startTime    time.Time
	progressChan chan string // receives STEP lines from tailer goroutine
}

// tailProgress reads the progress file and sends STEP lines on the channel.
// It opens the file, seeks to end, and tails for new lines.
func tailProgress(path string, ch chan<- string, done <-chan struct{}) {
	// Wait for the file to exist (up to 30s)
	var f *os.File
	for i := 0; i < 300; i++ {
		var err error
		f, err = os.Open(path)
		if err == nil {
			break
		}
		select {
		case <-done:
			return
		case <-time.After(100 * time.Millisecond):
		}
	}
	if f == nil {
		return
	}
	defer f.Close()

	// Seek to end — we only care about new lines
	f.Seek(0, io.SeekEnd)

	reader := bufio.NewReader(f)
	for {
		select {
		case <-done:
			return
		default:
		}

		line, err := reader.ReadString('\n')
		if err != nil {
			// No new data yet — poll
			select {
			case <-done:
				return
			case <-time.After(100 * time.Millisecond):
				continue
			}
		}

		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "STEP:") || strings.HasPrefix(line, "STEP ") {
			text := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(line, "STEP:"), "STEP "))
			if text != "" {
				select {
				case ch <- text:
				case <-done:
					return
				}
			}
		}
	}
}

// waitForStep returns a command that blocks until the next step arrives.
func waitForStep(ch <-chan string) tea.Cmd {
	return func() tea.Msg {
		text, ok := <-ch
		if !ok {
			return nil
		}
		return stepMsg{text: text}
	}
}

func timeoutCmd(d time.Duration) tea.Cmd {
	return tea.Tick(d, func(_ time.Time) tea.Msg {
		return timeoutMsg{}
	})
}

func newModel(cfg Config) model {
	theme := styles.DefaultTheme()
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(theme.Accent)

	return model{
		theme:        theme,
		config:       cfg,
		spinner:      sp,
		startTime:    time.Now(),
		progressChan: make(chan string, 32),
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(
		m.spinner.Tick,
		timeoutCmd(m.config.Timeout),
		waitForStep(m.progressChan),
	)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.ready = true
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c", "esc":
			m.done = true
			m.exitCode = 1
			return m, tea.Quit
		}

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd

	case stepMsg:
		if strings.EqualFold(msg.text, "Ready") {
			// Move current step to completed if any
			if m.currentStep != "" {
				m.steps = append(m.steps, m.currentStep)
			}
			m.currentStep = ""
			m.done = true
			m.exitCode = 0
			return m, tea.Quit
		}
		// Rotate: current step becomes completed, new step is current
		if m.currentStep != "" {
			m.steps = append(m.steps, m.currentStep)
		}
		m.currentStep = msg.text
		return m, waitForStep(m.progressChan)

	case timeoutMsg:
		m.done = true
		m.exitCode = 2
		return m, tea.Quit
	}
	return m, nil
}

// ── View ──────────────────────────────────────────────────────────────

const splashArt = `   ██████╗  ██████╗ ███████╗██╗   ██╗
   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝
   ██║  ██║██║   ██║█████╗   ╚████╔╝
   ██║  ██║██║   ██║██╔══╝    ╚██╔╝
   ██████╔╝╚██████╔╝███████╗   ██║
   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝`

func (m model) View() string {
	if !m.ready {
		return ""
	}

	// Splash art in accent color
	splash := lipgloss.NewStyle().
		Foreground(m.theme.Accent).
		Bold(true).
		Render(splashArt)

	// Completed steps
	var stepLines []string
	checkStyle := lipgloss.NewStyle().Foreground(m.theme.Success)
	stepTextStyle := lipgloss.NewStyle().Foreground(m.theme.Text)
	mutedStyle := lipgloss.NewStyle().Foreground(m.theme.Muted)

	for _, s := range m.steps {
		stepLines = append(stepLines, fmt.Sprintf("  %s %s",
			checkStyle.Render("✓"),
			stepTextStyle.Render(s),
		))
	}

	// Current step with spinner
	if m.currentStep != "" {
		stepLines = append(stepLines, fmt.Sprintf("  %s %s",
			m.spinner.View(),
			stepTextStyle.Render(m.currentStep),
		))
	}

	// If no steps yet, show a waiting message
	if len(m.steps) == 0 && m.currentStep == "" {
		elapsed := time.Since(m.startTime).Round(time.Second)
		stepLines = append(stepLines, fmt.Sprintf("  %s %s",
			m.spinner.View(),
			mutedStyle.Render(fmt.Sprintf("Starting... %s", elapsed)),
		))
	}

	progress := strings.Join(stepLines, "\n")

	// Hint
	hint := lipgloss.NewStyle().
		Foreground(m.theme.Muted).
		Faint(true).
		Render("Press q to skip")

	// Compose
	content := lipgloss.JoinVertical(lipgloss.Center,
		"",
		splash,
		"",
		progress,
		"",
		hint,
	)

	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, content)
}

// Run launches the startup TUI. Returns the exit code.
func Run(cfg Config) int {
	m := newModel(cfg)

	// Start tailing the progress file in background
	doneCh := make(chan struct{})
	go tailProgress(cfg.ProgressFile, m.progressChan, doneCh)

	p := tea.NewProgram(m, tea.WithAltScreen())
	finalModel, err := p.Run()

	close(doneCh)

	if err != nil {
		fmt.Fprintf(os.Stderr, "startup error: %v\n", err)
		return 1
	}

	fm := finalModel.(model)
	if fm.exitCode == 2 {
		fmt.Fprintf(os.Stderr, "startup timed out after %s\n", cfg.Timeout)
	}
	return fm.exitCode
}
