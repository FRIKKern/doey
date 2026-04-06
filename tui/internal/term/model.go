package term

import (
	"fmt"
	"os"
	"os/exec"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/doey-cli/doey/tui/internal/bubbleterm"
)

// tickMsg is sent by the centralized ticker as a fallback for resize/status updates.
type tickMsg struct{}

// ptyDataMsg signals that new data arrived from a PTY read loop.
type ptyDataMsg struct{}

// Tab represents a single terminal tab.
type Tab struct {
	Name string
	Term *bubbleterm.Model
}

// Model is the root model for the tabbed terminal container.
type Model struct {
	tabs           []Tab
	activeTab      int
	width          int
	height         int
	shell          string
	ready          bool
	tabCount       int
	tabLayout      tabBarLayout  // click zones from last render
	ptyNotify      chan struct{} // event-driven PTY data notifications
	viewportOffset int           // 0 = live bottom, >0 = scrolled back N lines
}

const tabBarHeight = 1

// New creates a new tabbed terminal model. The first tab is created once the
// terminal size is known (on the first WindowSizeMsg).
func New(shell string) *Model {
	return &Model{
		shell:     shell,
		ptyNotify: make(chan struct{}, 1),
	}
}

// Init satisfies tea.Model. We wait for WindowSizeMsg before spawning PTYs.
func (m *Model) Init() tea.Cmd {
	return nil
}

// createTab spawns a new shell tab at the current terminal dimensions.
func (m *Model) createTab() (*Tab, tea.Cmd) {
	m.tabCount++

	termHeight := m.height - tabBarHeight
	if termHeight < 1 {
		termHeight = 1
	}
	termWidth := m.width
	if termWidth < 2 {
		termWidth = 2
	}

	cmd := exec.Command(m.shell)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")

	terminal, err := bubbleterm.NewWithCommand(termWidth, termHeight, cmd)
	if err != nil {
		return nil, nil
	}
	terminal.SetAutoPoll(false)
	terminal.Focus()

	// Set up event-driven PTY notification (non-blocking write to channel).
	notify := m.ptyNotify
	terminal.GetEmulator().SetOnData(func() {
		select {
		case notify <- struct{}{}:
		default:
		}
	})

	tab := &Tab{
		Name: fmt.Sprintf("Tab %d", m.tabCount),
		Term: terminal,
	}

	return tab, terminal.Init()
}

// Update handles messages and routes them to the active terminal or tab management.
func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

		if !m.ready {
			m.ready = true
			tab, initCmd := m.createTab()
			if tab != nil {
				m.tabs = append(m.tabs, *tab)
				if initCmd != nil {
					cmds = append(cmds, initCmd)
				}
			}
			cmds = append(cmds, m.scheduleTick())
			cmds = append(cmds, m.waitForPtyData())
			return m, tea.Batch(cmds...)
		}

		termHeight := m.height - tabBarHeight
		if termHeight < 1 {
			termHeight = 1
		}
		for i := range m.tabs {
			cmd := m.tabs[i].Term.Resize(m.width, termHeight)
			if cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		return m, tea.Batch(cmds...)

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+t":
			tab, initCmd := m.createTab()
			if tab != nil {
				if len(m.tabs) > 0 {
					m.tabs[m.activeTab].Term.Blur()
				}
				m.tabs = append(m.tabs, *tab)
				m.activeTab = len(m.tabs) - 1
				if initCmd != nil {
					cmds = append(cmds, initCmd)
				}
			}
			return m, tea.Batch(cmds...)

		case "ctrl+w":
			if len(m.tabs) > 1 {
				m.closeTab(m.activeTab)
			}
			return m, nil

		case "alt+1", "alt+2", "alt+3", "alt+4", "alt+5",
			"alt+6", "alt+7", "alt+8", "alt+9":
			idx := int(msg.String()[4] - '1')
			if idx >= 0 && idx < len(m.tabs) {
				m.switchTab(idx)
			}
			return m, nil

		case "alt+]":
			if len(m.tabs) > 1 {
				m.switchTab((m.activeTab + 1) % len(m.tabs))
			}
			return m, nil

		case "alt+[":
			if len(m.tabs) > 1 {
				m.switchTab((m.activeTab - 1 + len(m.tabs)) % len(m.tabs))
			}
			return m, nil

		case "shift+pgup":
			if len(m.tabs) > 0 && m.activeTab < len(m.tabs) {
				page := m.pageSize()
				maxOffset := m.tabs[m.activeTab].Term.ScrollbackLen()
				m.viewportOffset += page
				if m.viewportOffset > maxOffset {
					m.viewportOffset = maxOffset
				}
			}
			return m, nil

		case "shift+pgdown":
			page := m.pageSize()
			m.viewportOffset -= page
			if m.viewportOffset < 0 {
				m.viewportOffset = 0
			}
			return m, nil
		}

		// Forward all other keys to the active tab. Any key that reaches the
		// terminal snaps the viewport back to the live bottom.
		if len(m.tabs) > 0 && m.activeTab < len(m.tabs) {
			m.viewportOffset = 0
			termModel, cmd := m.tabs[m.activeTab].Term.Update(msg)
			m.tabs[m.activeTab].Term = termModel.(*bubbleterm.Model)
			if cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		return m, tea.Batch(cmds...)

	case ptyDataMsg:
		// New PTY data arrived — poll all terminals for updated frames.
		for i := range m.tabs {
			cmd := m.tabs[i].Term.UpdateTerminal()
			if cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		cmds = append(cmds, m.waitForPtyData())
		return m, tea.Batch(cmds...)

	case tickMsg:
		// Fallback tick for resize events, status bar, and process exit checks.
		for i := range m.tabs {
			cmd := m.tabs[i].Term.UpdateTerminal()
			if cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		// Remove tabs whose processes have exited (reverse order).
		for i := len(m.tabs) - 1; i >= 0; i-- {
			if m.tabs[i].Term.GetEmulator().IsProcessExited() {
				m.tabs[i].Term.Close()
				m.tabs = append(m.tabs[:i], m.tabs[i+1:]...)
				if m.activeTab >= len(m.tabs) && len(m.tabs) > 0 {
					m.activeTab = len(m.tabs) - 1
				}
			}
		}
		if len(m.tabs) == 0 {
			return m, tea.Quit
		}
		if m.activeTab < len(m.tabs) {
			m.tabs[m.activeTab].Term.Focus()
		}
		cmds = append(cmds, m.scheduleTick())
		return m, tea.Batch(cmds...)

	case tea.MouseClickMsg:
		if msg.Y == 0 {
			// Click on the tab bar row — check plus button, then close, then tab switch.
			if msg.X >= m.tabLayout.plusBtn.startX && msg.X < m.tabLayout.plusBtn.endX {
				tab, initCmd := m.createTab()
				if tab != nil {
					if len(m.tabs) > 0 {
						m.tabs[m.activeTab].Term.Blur()
					}
					m.tabs = append(m.tabs, *tab)
					m.activeTab = len(m.tabs) - 1
					if initCmd != nil {
						cmds = append(cmds, initCmd)
					}
				}
				return m, tea.Batch(cmds...)
			}
			for i, zone := range m.tabLayout.closeBtns {
				if zone.endX > zone.startX && msg.X >= zone.startX && msg.X < zone.endX {
					if len(m.tabs) > 1 {
						m.closeTab(i)
					}
					return m, nil
				}
			}
			for i, zone := range m.tabLayout.tabs {
				if msg.X >= zone.startX && msg.X < zone.endX {
					m.switchTab(i)
					return m, nil
				}
			}
			// Click landed on the tab bar but outside any interactive zone —
			// swallow it rather than forwarding to the terminal.
			return m, nil
		}
		// Forward non-tab-bar mouse clicks to the active terminal. The tab
		// bar occupies row 0, so subtract it from Y so the terminal sees
		// content-relative coordinates (0-based from the top of its content).
		msg.Y--
		if len(m.tabs) > 0 && m.activeTab < len(m.tabs) {
			termModel, cmd := m.tabs[m.activeTab].Term.Update(msg)
			m.tabs[m.activeTab].Term = termModel.(*bubbleterm.Model)
			if cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		return m, tea.Batch(cmds...)

	case tea.MouseReleaseMsg:
		// Release events on the tab bar row (Y==0) are swallowed to mirror
		// the click handling. All other releases are forwarded with Y
		// translated to terminal content coordinates.
		if msg.Y == 0 {
			return m, nil
		}
		msg.Y--
		if len(m.tabs) > 0 && m.activeTab < len(m.tabs) {
			termModel, cmd := m.tabs[m.activeTab].Term.Update(msg)
			m.tabs[m.activeTab].Term = termModel.(*bubbleterm.Model)
			if cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		return m, tea.Batch(cmds...)

	case tea.MouseMotionMsg:
		// Forward mouse motion to the active terminal so guest apps that
		// track hover (htop, mc, …) see continuous updates. Motion on the
		// tab bar row is ignored.
		if msg.Y == 0 {
			return m, nil
		}
		msg.Y--
		if len(m.tabs) > 0 && m.activeTab < len(m.tabs) {
			termModel, cmd := m.tabs[m.activeTab].Term.Update(msg)
			m.tabs[m.activeTab].Term = termModel.(*bubbleterm.Model)
			if cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		return m, tea.Batch(cmds...)

	case tea.MouseWheelMsg:
		// Forward wheel events to the active terminal. The vt emulator only
		// writes the SGR sequence if the guest app has mouse tracking
		// enabled, so this is a no-op when the app doesn't care.
		if msg.Y == 0 {
			return m, nil
		}
		msg.Y--
		if len(m.tabs) > 0 && m.activeTab < len(m.tabs) {
			termModel, cmd := m.tabs[m.activeTab].Term.Update(msg)
			m.tabs[m.activeTab].Term = termModel.(*bubbleterm.Model)
			if cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		return m, tea.Batch(cmds...)

	case tea.PasteMsg:
		// Forward pasted content to the active terminal as a single bracketed
		// paste sequence. Apps with bracketed paste mode enabled (vim, fish,
		// etc.) will recognize the markers and treat it as one paste; apps
		// without it ignore or strip the markers.
		if len(m.tabs) > 0 && m.activeTab < len(m.tabs) {
			seq := "\x1b[200~" + msg.Content + "\x1b[201~"
			if cmd := m.tabs[m.activeTab].Term.SendInput(seq); cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		return m, tea.Batch(cmds...)

	default:
		// Forward other messages to all terminals.
		for i := range m.tabs {
			termModel, cmd := m.tabs[i].Term.Update(msg)
			m.tabs[i].Term = termModel.(*bubbleterm.Model)
			if cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		return m, tea.Batch(cmds...)
	}
}

// closeTab removes the tab at idx, cleans up its process, and adjusts activeTab.
func (m *Model) closeTab(idx int) {
	if idx < 0 || idx >= len(m.tabs) || len(m.tabs) <= 1 {
		return
	}
	m.tabs[idx].Term.Close()
	m.tabs = append(m.tabs[:idx], m.tabs[idx+1:]...)
	if m.activeTab >= len(m.tabs) {
		m.activeTab = len(m.tabs) - 1
	} else if m.activeTab > idx {
		m.activeTab--
	}
	m.tabs[m.activeTab].Term.Focus()
}

func (m *Model) switchTab(idx int) {
	if idx == m.activeTab || idx < 0 || idx >= len(m.tabs) {
		return
	}
	m.tabs[m.activeTab].Term.Blur()
	m.activeTab = idx
	m.tabs[m.activeTab].Term.Focus()
}

func (m *Model) scheduleTick() tea.Cmd {
	return tea.Tick(500*time.Millisecond, func(time.Time) tea.Msg {
		return tickMsg{}
	})
}

// waitForPtyData returns a command that blocks until PTY data arrives.
func (m *Model) waitForPtyData() tea.Cmd {
	ch := m.ptyNotify
	return func() tea.Msg {
		<-ch
		return ptyDataMsg{}
	}
}

// View renders the tab bar and the active terminal.
func (m *Model) View() tea.View {
	if !m.ready || len(m.tabs) == 0 {
		return tea.NewView("Starting...")
	}

	bar, layout := renderTabBar(m.tabs, m.activeTab, m.width)
	m.tabLayout = layout
	content := m.tabs[m.activeTab].Term.ViewAt(m.viewportOffset)

	var v tea.View
	v.SetContent(bar + "\n" + content.Content)
	v.AltScreen = true
	v.MouseMode = tea.MouseModeAllMotion
	return v
}

// pageSize returns the number of lines a single Shift+PageUp/Down step
// scrolls — one less than the visible terminal height so the user keeps a
// row of context across pages.
func (m *Model) pageSize() int {
	page := m.height - tabBarHeight - 1
	if page < 1 {
		page = 1
	}
	return page
}

// SetSize updates the stored dimensions.
func (m *Model) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetFocused is a no-op included for interface compatibility with existing
// Doey model conventions.
func (m *Model) SetFocused(focused bool) {}
