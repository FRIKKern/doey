package bubbleterm

import (
	"io"
	"os/exec"
	"strings"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"
	"github.com/doey-cli/doey/tui/internal/bubbleterm/emulator"
)

// translatedMouseMsg wraps mouse events with translated coordinates
type translatedMouseMsg struct {
	OriginalMsg tea.Msg
	EmulatorID  string // ID of the emulator this message is for
	X, Y        int
}

// Model represents the terminal bubble state
type Model struct {
	emulator   *emulator.Emulator
	width      int
	height     int
	focused    bool
	err        error
	frame      emulator.EmittedFrame
	cachedView string // Cache the rendered view string
	autoPoll   bool   // Whether to automatically poll for updates
}

// New creates a new terminal bubble with the specified dimensions
func New(width, height int) (*Model, error) {
	emu, err := emulator.New(width, height)
	if err != nil {
		return nil, err
	}

	return &Model{
		emulator:   emu,
		width:      width,
		height:     height,
		focused:    true,
		frame:      emulator.EmittedFrame{Rows: make([]string, height)},
		cachedView: strings.Repeat("\n", height-1), // Initialize with empty lines
		autoPoll:   true,
	}, nil
}

func (m *Model) SetAutoPoll(autoPoll bool) {
	m.autoPoll = autoPoll
}

// NewWithPipes creates a new terminal bubble that reads process output from r
// and writes user input to w. This allows embedding a terminal view for an
// already-running process where you have access to its stdin/stdout pipes
// (e.g., when the process was started by a third-party library).
//
// Example:
//
//	cmd := exec.Command("bash")
//	stdin, _ := cmd.StdinPipe()
//	stdout, _ := cmd.StdoutPipe()
//	cmd.Start()
//	model, _ := bubbleterm.NewWithPipes(80, 24, stdout, stdin)
func NewWithPipes(width, height int, r io.Reader, w io.WriteCloser) (*Model, error) {
	emu, err := emulator.NewFromPipes(width, height, r, w)
	if err != nil {
		return nil, err
	}

	return &Model{
		emulator:   emu,
		width:      width,
		height:     height,
		focused:    true,
		frame:      emulator.EmittedFrame{Rows: make([]string, height)},
		cachedView: strings.Repeat("\n", height-1),
		autoPoll:   true,
	}, nil
}

// NewWithCommand creates a new terminal bubble and starts the specified command
func NewWithCommand(width, height int, cmd *exec.Cmd) (*Model, error) {
	// we need at least 2 columns for
	model, err := New(width, height)
	if err != nil {
		return nil, err
	}

	err = model.emulator.StartCommand(cmd)
	if err != nil {
		model.emulator.Close()
		return nil, err
	}

	return model, nil
}

// Init initializes the bubble (no automatic ticking)
func (m *Model) Init() tea.Cmd {
	// Only do initial poll, no automatic ticking
	return pollTerminal(m.emulator)
}

// Update handles messages and updates the model state
func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if !m.focused {
			return m, nil
		}

		// Convert bubbletea key events to terminal input
		input := keyToTerminalInput(msg)
		if input != "" {
			return m, sendInput(m.emulator, input)
		}

	case tea.MouseClickMsg:
		if !m.focused {
			return m, nil
		}
		// Send mouse click to terminal
		return m, sendMouseEvent(m.emulator, msg.Mouse().X, msg.Mouse().Y, int(msg.Mouse().Button), true)

	case tea.MouseReleaseMsg:
		if !m.focused {
			return m, nil
		}
		// Send mouse release to terminal
		return m, sendMouseEvent(m.emulator, msg.Mouse().X, msg.Mouse().Y, int(msg.Mouse().Button), false)

	case tea.MouseMotionMsg:
		if !m.focused {
			return m, nil
		}
		// Send mouse motion to terminal (button -1 indicates motion without button)
		return m, sendMouseEvent(m.emulator, msg.Mouse().X, msg.Mouse().Y, -1, false)

	case translatedMouseMsg:
		if !m.focused {
			return m, nil
		}
		if msg.EmulatorID != m.emulator.ID() {
			return m, nil // Ignore messages from other emulators
		}
		// Handle translated mouse events with proper coordinates
		switch originalMsg := msg.OriginalMsg.(type) {
		case tea.MouseClickMsg:
			return m, sendMouseEvent(m.emulator, msg.X, msg.Y, int(originalMsg.Mouse().Button), true)
		case tea.MouseReleaseMsg:
			return m, sendMouseEvent(m.emulator, msg.X, msg.Y, int(originalMsg.Mouse().Button), false)
		case tea.MouseMotionMsg:
			return m, sendMouseEvent(m.emulator, msg.X, msg.Y, -1, false)
		}

	case tea.WindowSizeMsg:
		// Handle terminal resize
		if msg.Width != m.width || msg.Height != m.height {
			m.width = msg.Width
			m.height = msg.Height
			return m, resizeTerminal(m.emulator, msg.Width, msg.Height)
		}

	case terminalOutputMsg:
		if msg.EmulatorID != m.emulator.ID() {
			return m, nil // Ignore messages from other emulators
		}
		// Skip rerender if nothing changed
		if len(msg.Frame.Damage) == 0 {
			if m.autoPoll {
				return m, pollTerminal(m.emulator)
			}
			return m, nil
		}
		// Update the frame with new terminal output
		m.frame = msg.Frame
		// Cache the rendered view for fast access
		m.cachedView = strings.Join(m.frame.Rows, "\n")
		// Don't immediately poll again - let the tick handle regular polling
		if m.autoPoll {
			return m, pollTerminal(m.emulator)
		}
		return m, nil

	case terminalErrorMsg:
		if msg.EmulatorID != m.emulator.ID() {
			return m, nil // Ignore messages from other emulators
		}
		m.err = msg.Err
		return m, nil

	case startCommandMsg:
		if msg.EmulatorID != m.emulator.ID() {
			return m, nil // Ignore messages from other emulators
		}
		err := m.emulator.StartCommand(msg.Cmd)
		if err != nil {
			m.err = err
		}
		return m, nil
	}

	return m, nil
}

// UpdateTerminal manually polls the terminal for updates (called by external ticker)
func (m *Model) UpdateTerminal() tea.Cmd {
	return pollTerminal(m.emulator)
}

// View renders the terminal output.
func (m *Model) View() tea.View {
	if m.err != nil {
		return tea.NewView("Terminal error: " + m.err.Error())
	}

	// Overlay cursor on cached view
	pos, visible := m.emulator.Cursor()
	if !visible || pos.Y < 0 || pos.Y >= len(m.frame.Rows) {
		return tea.NewView(m.cachedView)
	}

	rows := m.frame.Rows
	row := rows[pos.Y]
	cursorRow := insertCursor(row, pos.X)

	var b strings.Builder
	for i, r := range rows {
		if i > 0 {
			b.WriteByte('\n')
		}
		if i == pos.Y {
			b.WriteString(cursorRow)
		} else {
			b.WriteString(r)
		}
	}
	return tea.NewView(b.String())
}

// ScrollbackLen returns the number of lines currently held in the underlying
// emulator's scrollback buffer.
func (m *Model) ScrollbackLen() int {
	return m.emulator.ScrollbackLen()
}

// ViewAt renders the terminal scrolled back by `offset` lines from the live
// bottom. offset == 0 returns the live view (identical to View). When the
// offset moves the viewport into scrollback, the cursor is hidden and lines
// above the live screen are pulled from the emulator's scrollback buffer.
// The offset is silently clamped to the available scrollback length.
func (m *Model) ViewAt(offset int) tea.View {
	if offset <= 0 {
		return m.View()
	}
	if m.err != nil {
		return tea.NewView("Terminal error: " + m.err.Error())
	}

	sbLen := m.emulator.ScrollbackLen()
	if offset > sbLen {
		offset = sbLen
	}
	if offset == 0 {
		return m.View()
	}

	rows := m.frame.Rows
	h := m.height
	if h <= 0 {
		return m.View()
	}

	// Combined stream: scrollback[0..sbLen) followed by live rows[0..h).
	// With offset == 0 the viewport top is at index sbLen (first live row).
	// As offset grows the top moves up by `offset` lines.
	top := sbLen - offset

	var b strings.Builder
	for i := 0; i < h; i++ {
		if i > 0 {
			b.WriteByte('\n')
		}
		idx := top + i
		if idx < 0 {
			b.WriteString(strings.Repeat(" ", m.width))
			continue
		}
		if idx < sbLen {
			b.WriteString(padVisibleWidth(m.emulator.ScrollbackLine(idx), m.width))
			continue
		}
		r := idx - sbLen
		if r >= 0 && r < len(rows) {
			b.WriteString(rows[r])
		} else {
			b.WriteString(strings.Repeat(" ", m.width))
		}
	}
	return tea.NewView(b.String())
}

// padVisibleWidth pads s with spaces so its visible width (ignoring ANSI
// escape sequences) is at least width.
func padVisibleWidth(s string, width int) string {
	visible := 0
	inEscape := false
	for _, r := range s {
		if r == '\033' {
			inEscape = true
			continue
		}
		if inEscape {
			if (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || r == '~' {
				inEscape = false
			}
			continue
		}
		visible++
	}
	if visible < width {
		return s + strings.Repeat(" ", width-visible)
	}
	return s
}

// insertCursor inserts reverse-video around the character at visible column col,
// skipping over ANSI escape sequences when counting columns.
func insertCursor(row string, col int) string {
	if col < 0 {
		return row
	}
	visibleCol := 0
	inEscape := false
	byteIdx := -1

	for i, r := range row {
		if r == '\033' {
			inEscape = true
			continue
		}
		if inEscape {
			if (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || r == '~' {
				inEscape = false
			}
			continue
		}
		if visibleCol == col {
			byteIdx = i
			break
		}
		visibleCol++
	}

	if byteIdx < 0 {
		// Cursor is past the end of the row content — append a block cursor on a space
		return row + "\x1b[7m \x1b[27m"
	}

	// Find the byte length of the rune at byteIdx
	_, size := utf8.DecodeRuneInString(row[byteIdx:])
	return row[:byteIdx] + "\x1b[7m" + row[byteIdx:byteIdx+size] + "\x1b[27m" + row[byteIdx+size:]
}

// Focus sets the bubble as focused (receives keyboard input)
func (m *Model) Focus() {
	m.focused = true
}

// Blur removes focus from the bubble
func (m *Model) Blur() {
	m.focused = false
}

// Focused returns whether the bubble is currently focused
func (m *Model) Focused() bool {
	return m.focused
}

// StartCommand starts a new command in the terminal
func (m *Model) StartCommand(cmd *exec.Cmd) tea.Cmd {
	return func() tea.Msg {
		return startCommandMsg{Cmd: cmd, EmulatorID: m.emulator.ID()}
	}
}

// SendInput sends input to the terminal
func (m *Model) SendInput(input string) tea.Cmd {
	return sendInput(m.emulator, input)
}

// Resize changes the terminal dimensions
func (m *Model) Resize(width, height int) tea.Cmd {
	m.width = width
	m.height = height
	return resizeTerminal(m.emulator, width, height)
}

// GetEmulator returns the underlying emulator (for process monitoring)
func (m *Model) GetEmulator() *emulator.Emulator {
	return m.emulator
}

// Close shuts down the terminal emulator
func (m *Model) Close() error {
	if m.emulator != nil {
		return m.emulator.Close()
	}
	return nil
}
