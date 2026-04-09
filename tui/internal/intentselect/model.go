// Package intentselect implements an interactive TUI for intent fallback selection.
// It supports three modes: confirm (y/n), select (list picker), and info (display only).
// Input is JSON on stdin; output is JSON on stdout. The TUI renders to stderr.
package intentselect

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// --- JSON protocol types ---

// InputPayload is the JSON sent to stdin.
type InputPayload struct {
	Action      string   `json:"action"`                // "confirm", "select", "info"
	Command     string   `json:"command,omitempty"`      // confirm: the corrected command
	Explanation string   `json:"explanation,omitempty"`  // confirm: why this match
	Typed       string   `json:"typed,omitempty"`        // what the user originally typed
	Options     []Option `json:"options,omitempty"`      // select: list of candidates
	Prompt      string   `json:"prompt,omitempty"`       // select: heading text
	Message     string   `json:"message,omitempty"`      // info: message to display
	Suggestions []string `json:"suggestions,omitempty"`  // info: suggested commands
}

// Option is a single selectable item in select mode.
type Option struct {
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
}

// OutputPayload is the JSON written to stdout on selection.
type OutputPayload struct {
	Selected string `json:"selected"`
}

// --- Bubble Tea list item ---

type optionItem struct {
	label string
	desc  string
}

func (i optionItem) Title() string       { return i.label }
func (i optionItem) Description() string { return i.desc }
func (i optionItem) FilterValue() string { return i.label }

// --- Styles ---

var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#6D28D9", Dark: "#A78BFA"}).
			MarginBottom(1)

	commandStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#15803D", Dark: "#6EE7B7"})

	dimStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#9CA3AF", Dark: "#9CA3AF"})

	keyStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#475569", Dark: "#94A3B8"})

	suggestionStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#3B82F6", Dark: "#93C5FD"}).
			PaddingLeft(4)
)

// --- Model ---

type model struct {
	action      string
	command     string
	explanation string
	typed       string
	options     []Option
	prompt      string
	message     string
	suggestions []string
	list        list.Model
	selected    string
	quitting    bool
	confirmed   *bool // nil = undecided, true = yes, false = no
	width       int
	height      int
}

func newConfirmModel(input InputPayload) model {
	return model{
		action:      "confirm",
		command:     input.Command,
		explanation: input.Explanation,
		typed:       input.Typed,
	}
}

func newSelectModel(input InputPayload) model {
	items := make([]list.Item, len(input.Options))
	for i, opt := range input.Options {
		items[i] = optionItem{label: opt.Label, desc: opt.Description}
	}

	prompt := input.Prompt
	if prompt == "" {
		prompt = "Select a command:"
	}

	delegate := list.NewDefaultDelegate()
	delegate.ShowDescription = true

	l := list.New(items, delegate, 60, 14)
	l.Title = prompt
	l.SetShowStatusBar(false)
	l.SetShowHelp(true)
	l.SetFilteringEnabled(true)
	l.DisableQuitKeybindings()

	return model{
		action:  "select",
		typed:   input.Typed,
		options: input.Options,
		prompt:  prompt,
		list:    l,
	}
}

func newInfoModel(input InputPayload) model {
	return model{
		action:      "info",
		message:     input.Message,
		suggestions: input.Suggestions,
	}
}

func (m model) Init() tea.Cmd {
	return nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		if m.action == "select" {
			// Reserve space for the "You typed:" header line
			m.list.SetSize(msg.Width-4, msg.Height-4)
		}
		return m, nil

	case tea.KeyMsg:
		switch m.action {
		case "confirm":
			return m.updateConfirm(msg)
		case "select":
			return m.updateSelect(msg)
		case "info":
			return m.updateInfo(msg)
		}
	}

	return m, nil
}

func (m model) updateConfirm(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "y", "Y", "enter":
		t := true
		m.confirmed = &t
		m.selected = m.command
		m.quitting = true
		return m, tea.Quit
	case "n", "N", "esc", "q":
		f := false
		m.confirmed = &f
		m.quitting = true
		return m, tea.Quit
	case "ctrl+c":
		m.quitting = true
		return m, tea.Quit
	}
	return m, nil
}

func (m model) updateSelect(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "enter":
		if item, ok := m.list.SelectedItem().(optionItem); ok {
			m.selected = item.label
			m.quitting = true
			return m, tea.Quit
		}
	case "esc":
		// If filtering, let bubbles handle esc to cancel filter
		if m.list.FilterState() == list.Filtering {
			var cmd tea.Cmd
			m.list, cmd = m.list.Update(msg)
			return m, cmd
		}
		m.quitting = true
		return m, tea.Quit
	case "q":
		// Only quit if not filtering
		if m.list.FilterState() != list.Filtering {
			m.quitting = true
			return m, tea.Quit
		}
	case "ctrl+c":
		m.quitting = true
		return m, tea.Quit
	}

	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	return m, cmd
}

func (m model) updateInfo(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		m.quitting = true
		return m, tea.Quit
	default:
		// Any key dismisses info mode
		m.quitting = true
		return m, tea.Quit
	}
}

func (m model) View() string {
	if m.quitting {
		return ""
	}

	switch m.action {
	case "confirm":
		return m.viewConfirm()
	case "select":
		return m.viewSelect()
	case "info":
		return m.viewInfo()
	}
	return ""
}

func (m model) viewConfirm() string {
	var b strings.Builder

	b.WriteString("\n")
	b.WriteString(titleStyle.Render("  Did you mean:"))
	b.WriteString("\n")
	b.WriteString("  " + commandStyle.Render(m.command))
	b.WriteString("\n\n")

	if m.explanation != "" {
		b.WriteString("  " + dimStyle.Render(m.explanation))
		b.WriteString("\n\n")
	}

	b.WriteString("  " + keyStyle.Render("[Y]") + dimStyle.Render("es") + "  " + keyStyle.Render("[N]") + dimStyle.Render("o"))
	b.WriteString("\n")

	return b.String()
}

func (m model) viewSelect() string {
	var b strings.Builder

	if m.typed != "" {
		b.WriteString("\n")
		b.WriteString("  " + dimStyle.Render("You typed: ") + commandStyle.Render(m.typed))
		b.WriteString("\n")
	}

	b.WriteString(m.list.View())

	return b.String()
}

func (m model) viewInfo() string {
	var b strings.Builder

	b.WriteString("\n")
	if m.message != "" {
		b.WriteString("  " + titleStyle.Render(m.message))
		b.WriteString("\n")
	}

	if len(m.suggestions) > 0 {
		b.WriteString("  " + dimStyle.Render("Did you mean one of these?"))
		b.WriteString("\n\n")
		for _, s := range m.suggestions {
			b.WriteString(suggestionStyle.Render("• " + s))
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("  " + dimStyle.Render("Press any key to dismiss"))
	b.WriteString("\n")

	return b.String()
}

// Run reads an InputPayload from stdin, runs the interactive TUI on stderr,
// and writes the OutputPayload to stdout. Returns the exit code.
func Run() int {
	// Read input payload from stdin
	var input InputPayload
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading stdin: %v\n", err)
		return 1
	}
	if err := json.Unmarshal(data, &input); err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing JSON input: %v\n", err)
		return 1
	}

	// Validate action
	switch input.Action {
	case "confirm", "select", "info":
		// ok
	default:
		fmt.Fprintf(os.Stderr, "Unknown action: %q\n", input.Action)
		return 1
	}

	// Non-TTY fast path: if stderr is not a terminal, skip the TUI
	if fi, err := os.Stderr.Stat(); err == nil {
		if fi.Mode()&os.ModeCharDevice == 0 {
			// Not a terminal — output first option directly
			switch input.Action {
			case "confirm":
				out := OutputPayload{Selected: input.Command}
				json.NewEncoder(os.Stdout).Encode(out)
				return 0
			case "select":
				if len(input.Options) > 0 {
					out := OutputPayload{Selected: input.Options[0].Label}
					json.NewEncoder(os.Stdout).Encode(out)
					return 0
				}
				return 1
			case "info":
				return 0
			}
		}
	}

	// Build model based on action
	var m model
	switch input.Action {
	case "confirm":
		m = newConfirmModel(input)
	case "select":
		m = newSelectModel(input)
	case "info":
		m = newInfoModel(input)
	}

	// Run TUI — render to stderr, keep stdout clean for JSON output
	p := tea.NewProgram(m, tea.WithOutput(os.Stderr))
	finalModel, err := p.Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "TUI error: %v\n", err)
		return 1
	}

	result := finalModel.(model)

	// Handle output based on result
	if result.selected != "" {
		out := OutputPayload{Selected: result.selected}
		json.NewEncoder(os.Stdout).Encode(out)
		return 0
	}

	// No selection — cancelled
	if result.action == "info" {
		return 0
	}
	return 1
}
