package emulator

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/charmbracelet/x/vt"
	"github.com/creack/pty"
	"github.com/google/uuid"
)

// Emulator is a headless terminal emulator that maintains internal state
// and renders to a framebuffer instead of directly to screen
type Emulator struct {
	mu sync.RWMutex
	id string

	// Terminal emulator (using charm's x/vt)
	vt *vt.Emulator

	// PTY for process communication
	pty, tty *os.File

	// Pipe-based I/O (alternative to PTY)
	reader io.Reader
	writer io.WriteCloser
	isPipe bool

	// Process tracking
	cmd           *exec.Cmd
	processExited bool
	onExit        func(string) // Callback when process exits, receives emulator ID
	onData        func()       // Callback when new PTY data arrives

	// Framerate control
	frameRate time.Duration
	stopChan  chan struct{}

	// Damage tracking for change detection.
	// lastRows is the previous frame's rendered rows; nil before the first
	// render and after a resize, which both force a full-screen damage emit.
	// damaged is a fast-path flag set whenever new PTY data has been written
	// to the vt emulator since the last GetScreen call — when false we can
	// skip the (relatively expensive) Render+diff entirely.
	lastRows []string
	damaged  bool

	// Screen dimensions
	width, height int
}

// EmittedFrame represents a rendered frame from the terminal.
type EmittedFrame struct {
	Rows   []string     // Each row is a string with ANSI escape codes embedded
	Damage []LineDamage // Lines that changed since the last GetScreen call
}

// New creates a new headless terminal emulator
func New(cols, rows int) (*Emulator, error) {
	e := &Emulator{
		vt:        vt.NewEmulator(cols, rows),
		id:        uuid.New().String(),
		frameRate: time.Second / 30, // Default 30 FPS
		stopChan:  make(chan struct{}),
		width:     cols,
		height:    rows,
		damaged:   true, // Initial render needed
	}

	var err error
	e.pty, e.tty, err = pty.Open()
	if err != nil {
		return nil, err
	}

	// Set initial size
	err = e.resize(cols, rows)
	if err != nil {
		return nil, err
	}

	// Start the PTY read loop
	go e.ptyReadLoop()

	return e, nil
}

// NewFromPipes creates a headless terminal emulator that reads output from r
// and writes input to w, instead of using a PTY. This is useful when the
// process is already running and you have access to its stdin/stdout pipes.
// The caller is responsible for closing the reader when the process exits.
func NewFromPipes(cols, rows int, r io.Reader, w io.WriteCloser) (*Emulator, error) {
	e := &Emulator{
		vt:        vt.NewEmulator(cols, rows),
		id:        uuid.New().String(),
		frameRate: time.Second / 30,
		stopChan:  make(chan struct{}),
		reader:    r,
		writer:    w,
		isPipe:    true,
		width:     cols,
		height:    rows,
		damaged:   true,
	}

	// Start the read loop using the provided reader
	go e.ptyReadLoop()

	return e, nil
}

func (e *Emulator) ID() string {
	return e.id
}

// SetSize sets the terminal size (same as Resize for now)
func (e *Emulator) SetSize(cols, rows int) error {
	return e.Resize(cols, rows)
}

// Resize changes the terminal dimensions
func (e *Emulator) Resize(cols, rows int) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.resize(cols, rows)
}

func (e *Emulator) resize(cols, rows int) error {
	if !e.isPipe {
		err := pty.Setsize(e.pty, &pty.Winsize{
			Rows: uint16(rows),
			Cols: uint16(cols),
			X:    uint16(cols * 8),
			Y:    uint16(rows * 16),
		})
		if err != nil {
			return err
		}
	}

	e.vt.Resize(cols, rows)
	e.width = cols
	e.height = rows
	e.damaged = true
	// Drop the previous-frame snapshot so the next GetScreen call emits a
	// full-screen damage region for the new dimensions.
	e.lastRows = nil

	return nil
}

// SetFrameRate sets the internal render loop framerate
func (e *Emulator) SetFrameRate(fps int) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.frameRate = time.Second / time.Duration(fps)
}

// GetScreen returns the current rendered screen as ANSI strings together
// with per-line damage describing which rows (and, when possible, which
// cell range within those rows) changed since the previous GetScreen call.
//
// Damage detection is two-tiered:
//
//  1. The fast path: if no PTY data has arrived since the last call (the
//     damaged flag is false) and we already have a previous-frame snapshot,
//     we return the cached rows with empty damage and skip the renderer
//     entirely.
//  2. The slow path: render the current screen, split it into rows, and
//     diff each row against the previous-frame snapshot. Rows that differ
//     get a damage entry. The cell range (X1, X2) is refined using the
//     vt emulator's per-line Touched() data when its FirstCell/LastCell
//     range is sane; otherwise we fall back to the full row width.
//
// Note on the vt damage API: github.com/charmbracelet/x/vt exposes per-line
// damage via Emulator.Touched() (returning []*uv.LineData with FirstCell /
// LastCell cell indices) but does NOT expose ClearTouched() on the Emulator
// type — only on the inner Screen. Because of that we cannot reset touched
// state from outside the package, which means Touched() entries accumulate
// over time and cannot be used on their own as a reliable per-frame delta.
// We therefore use the previous-frame row snapshot as the authoritative
// "this row actually changed since last frame" signal and treat Touched()
// purely as a cell-range hint.
func (e *Emulator) GetScreen() EmittedFrame {
	e.mu.Lock()
	defer e.mu.Unlock()

	// Fast path: nothing has been written to the vt emulator since the
	// last GetScreen call, so the screen contents cannot have changed.
	// Return the cached snapshot with empty damage so the consumer can
	// skip its rerender.
	if !e.damaged && e.lastRows != nil {
		return EmittedFrame{Rows: e.lastRows, Damage: nil}
	}

	rendered := e.vt.Render()
	rows := splitIntoRows(rendered, e.height, e.width)

	var damage []LineDamage

	if e.lastRows == nil || len(e.lastRows) != len(rows) {
		// Initial render or post-resize: emit full-screen damage. We
		// can't trust per-line diffing yet because lastRows is either
		// missing or describes a different geometry.
		for y := 0; y < e.height; y++ {
			damage = append(damage, LineDamage{
				Row:    y,
				X1:     0,
				X2:     e.width,
				Reason: CRText,
			})
		}
	} else {
		// Per-line diff against the previous frame. Touched() supplies
		// optional cell-range hints; we still emit one damage entry per
		// changed row.
		touched := e.vt.Touched()
		for y := 0; y < len(rows); y++ {
			if rows[y] == e.lastRows[y] {
				continue
			}
			x1, x2 := 0, e.width
			if y < len(touched) && touched[y] != nil {
				first := touched[y].FirstCell
				last := touched[y].LastCell
				// Only trust the hint if it describes a valid,
				// non-empty range that fits within the row.
				if first >= 0 && last > first && last <= e.width {
					x1, x2 = first, last
				}
			}
			damage = append(damage, LineDamage{
				Row:    y,
				X1:     x1,
				X2:     x2,
				Reason: CRText,
			})
		}
	}

	e.lastRows = rows
	e.damaged = false

	return EmittedFrame{Rows: rows, Damage: damage}
}

// splitIntoRows splits the rendered output into individual rows and pads to width
func splitIntoRows(rendered string, height, width int) []string {
	rows := make([]string, height)

	// The vt.Render() returns a string with ANSI codes
	// We need to split it by newlines while preserving ANSI codes
	currentRow := 0
	var currentLine string

	for _, r := range rendered {
		if r == '\n' {
			if currentRow < height {
				rows[currentRow] = padRow(currentLine, width)
				currentRow++
			}
			currentLine = ""
		} else {
			currentLine += string(r)
		}
	}

	// Handle last line if no trailing newline
	if currentRow < height && currentLine != "" {
		rows[currentRow] = padRow(currentLine, width)
		currentRow++
	}

	// Fill remaining rows with spaces
	emptyRow := strings.Repeat(" ", width)
	for i := currentRow; i < height; i++ {
		if rows[i] == "" {
			rows[i] = emptyRow
		}
	}

	return rows
}

// padRow pads a row to the specified width, accounting for ANSI escape codes
func padRow(row string, width int) string {
	// Count visible characters (ignoring ANSI escape codes)
	visibleLen := 0
	inEscape := false
	for _, r := range row {
		if r == '\033' {
			inEscape = true
		} else if inEscape {
			if (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || r == '~' {
				inEscape = false
			}
		} else {
			visibleLen++
		}
	}

	// Pad with spaces if needed
	if visibleLen < width {
		return row + strings.Repeat(" ", width-visibleLen)
	}
	return row
}

// Cursor returns the current cursor position and whether the cursor is visible.
func (e *Emulator) Cursor() (Pos, bool) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	pos := e.vt.CursorPosition()
	// The vt package doesn't expose cursor visibility directly in a simple way
	// Default to visible
	return Pos{X: pos.X, Y: pos.Y}, true
}

// FeedInput processes raw ANSI input (typically from PTY)
func (e *Emulator) FeedInput(data []byte) {
	// This will be called by the PTY read loop
	// For now, we don't need to expose this publicly since PTY handles it
}

// SetOnExit sets a callback function that will be called when the process exits
func (e *Emulator) SetOnExit(callback func(string)) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.onExit = callback
}

// SetOnData sets a callback function that will be called when new PTY data arrives.
// The callback must be non-blocking.
func (e *Emulator) SetOnData(callback func()) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.onData = callback
}

// ScrollbackLen returns the number of lines currently in the main screen's
// scrollback buffer. Returns 0 if scrollback is unavailable.
func (e *Emulator) ScrollbackLen() int {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if e.vt == nil {
		return 0
	}
	return e.vt.ScrollbackLen()
}

// ScrollbackLine returns the rendered ANSI string for the scrollback line at
// the given index (0 = oldest line). Returns "" if the index is out of bounds
// or scrollback is unavailable.
func (e *Emulator) ScrollbackLine(idx int) string {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if e.vt == nil {
		return ""
	}
	sb := e.vt.Scrollback()
	if sb == nil {
		return ""
	}
	line := sb.Line(idx)
	if line == nil {
		return ""
	}
	return line.Render()
}

// IsProcessExited returns true if the process has exited
func (e *Emulator) IsProcessExited() bool {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.processExited
}

// StartCommand starts a command in the terminal.
// This is not supported for pipe-based emulators; use NewFromPipes instead.
func (e *Emulator) StartCommand(cmd *exec.Cmd) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.isPipe {
		return fmt.Errorf("StartCommand is not supported on pipe-based emulators")
	}

	if e.pty == nil {
		return ErrPTYNotInitialized
	}

	// Set up environment
	if cmd.Env == nil {
		cmd.Env = os.Environ()
	}

	// Ensure TERM is set correctly
	termSet := false
	for i, env := range cmd.Env {
		if len(env) >= 5 && env[:5] == "TERM=" {
			cmd.Env[i] = "TERM=xterm-256color"
			termSet = true
			break
		}
	}
	if !termSet {
		cmd.Env = append(cmd.Env, "TERM=xterm-256color")
	}

	// Connect to PTY
	cmd.Stdout = e.tty
	cmd.Stdin = e.tty
	cmd.Stderr = e.tty

	// Set up process group for proper signal handling
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setctty = true
	cmd.SysProcAttr.Setsid = true
	// Don't set Ctty explicitly - let the system handle it

	// Store the command reference
	e.cmd = cmd
	e.processExited = false

	err := cmd.Start()
	if err != nil {
		return err
	}

	// Start monitoring the process in a goroutine
	go e.monitorProcess()

	return nil
}

// monitorProcess waits for the process to exit and calls the exit callback
func (e *Emulator) monitorProcess() {
	if e.cmd == nil {
		return
	}

	// Wait for the process to exit
	_ = e.cmd.Wait()

	e.mu.Lock()
	e.processExited = true
	onExit := e.onExit
	id := e.id
	e.mu.Unlock()

	// Call the exit callback if set
	if onExit != nil {
		onExit(id)
	}
}

// Write sends data to the PTY or pipe (keyboard input)
func (e *Emulator) Write(data []byte) (int, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()

	if e.isPipe {
		if e.writer == nil {
			return 0, ErrPTYNotInitialized
		}
		return e.writer.Write(data)
	}

	if e.pty == nil {
		return 0, ErrPTYNotInitialized
	}

	return e.pty.Write(data)
}

// SendKey sends a key event to the terminal
func (e *Emulator) SendKey(key string) error {
	_, err := e.Write([]byte(key))
	return err
}

// SendMouse sends a mouse event to the terminal in SGR format
func (e *Emulator) SendMouse(button int, x, y int, pressed bool) error {
	// Convert to the vt package's mouse event format
	var vtButton vt.MouseButton
	switch button {
	case 0:
		vtButton = vt.MouseLeft
	case 1:
		vtButton = vt.MouseMiddle
	case 2:
		vtButton = vt.MouseRight
	case -1:
		vtButton = vt.MouseNone // Motion
	default:
		vtButton = vt.MouseButton(button)
	}

	e.mu.Lock()
	defer e.mu.Unlock()

	if pressed {
		e.vt.SendMouse(vt.MouseClick{
			Button: vtButton,
			X:      x,
			Y:      y,
		})
	} else if button == -1 {
		e.vt.SendMouse(vt.MouseMotion{
			Button: vtButton,
			X:      x,
			Y:      y,
		})
	} else {
		e.vt.SendMouse(vt.MouseRelease{
			Button: vtButton,
			X:      x,
			Y:      y,
		})
	}

	return nil
}

// Close shuts down the emulator
func (e *Emulator) Close() error {
	close(e.stopChan)

	if e.isPipe {
		if e.writer != nil {
			e.writer.Close()
		}
		return nil
	}

	if e.tty != nil {
		e.tty.Close()
	}
	if e.pty != nil {
		e.pty.Close()
	}

	return e.vt.Close()
}

// ptyReadLoop reads from PTY/pipe and writes to the vt emulator
func (e *Emulator) ptyReadLoop() {
	var source io.Reader
	if e.isPipe {
		source = e.reader
	} else {
		source = e.pty
	}

	buf := make([]byte, 4096)
	for {
		select {
		case <-e.stopChan:
			return
		default:
		}

		n, err := source.Read(buf)
		if err != nil {
			return
		}

		if n > 0 {
			e.mu.Lock()
			e.vt.Write(buf[:n])
			e.damaged = true
			onData := e.onData
			e.mu.Unlock()

			if onData != nil {
				onData()
			}
		}
	}
}
