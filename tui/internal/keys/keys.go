package keys

import "github.com/charmbracelet/bubbles/key"

// KeyMap defines all keybindings for the Doey TUI.
type KeyMap struct {
	NextPanel  key.Binding
	PrevPanel  key.Binding
	LeftPanel  key.Binding
	RightPanel key.Binding
	PanelOne   key.Binding
	PanelTwo   key.Binding
	PanelThree key.Binding
	PanelFour  key.Binding
	PanelFive  key.Binding
	PanelSix   key.Binding
	PanelSeven key.Binding
	PanelEight key.Binding
	PanelNine  key.Binding
	Up         key.Binding
	Down       key.Binding
	Select     key.Binding
	Back       key.Binding
	StatusCycle key.Binding
	Filter      key.Binding
	Quit        key.Binding
	ForceQuit  key.Binding
	Refresh    key.Binding
	Help       key.Binding
}

// DefaultKeyMap returns the standard keybindings.
func DefaultKeyMap() KeyMap {
	return KeyMap{
		NextPanel: key.NewBinding(
			key.WithKeys("tab"),
			key.WithHelp("tab", "switch"),
		),
		PrevPanel: key.NewBinding(
			key.WithKeys("shift+tab"),
			key.WithHelp("shift+tab", "prev"),
		),
		LeftPanel: key.NewBinding(
			key.WithKeys("left"),
			key.WithHelp("←", "prev panel"),
		),
		RightPanel: key.NewBinding(
			key.WithKeys("right"),
			key.WithHelp("→", "next panel"),
		),
		PanelOne: key.NewBinding(
			key.WithKeys("1"),
			key.WithHelp("1", "dashboard"),
		),
		PanelTwo: key.NewBinding(
			key.WithKeys("2"),
			key.WithHelp("2", "teams"),
		),
		PanelThree: key.NewBinding(
			key.WithKeys("3"),
			key.WithHelp("3", "tasks"),
		),
		PanelFour: key.NewBinding(
			key.WithKeys("4"),
			key.WithHelp("4", "plans"),
		),
		PanelFive: key.NewBinding(
			key.WithKeys("5"),
			key.WithHelp("5", "agents"),
		),
		PanelSix: key.NewBinding(
			key.WithKeys("6"),
			key.WithHelp("6", "logs"),
		),
		PanelSeven: key.NewBinding(
			key.WithKeys("7"),
			key.WithHelp("7", "connections"),
		),
		PanelEight: key.NewBinding(
			key.WithKeys("8"),
			key.WithHelp("8", "files"),
		),
		PanelNine: key.NewBinding(
			key.WithKeys("9"),
			key.WithHelp("9", "activity"),
		),
		Up: key.NewBinding(
			key.WithKeys("up", "k"),
			key.WithHelp("↑/k", "up"),
		),
		Down: key.NewBinding(
			key.WithKeys("down", "j"),
			key.WithHelp("↓/j", "down"),
		),
		Select: key.NewBinding(
			key.WithKeys("enter"),
			key.WithHelp("enter", "details"),
		),
		Back: key.NewBinding(
			key.WithKeys("esc"),
			key.WithHelp("esc", "back"),
		),
		StatusCycle: key.NewBinding(
			key.WithKeys("s"),
			key.WithHelp("s", "cycle status"),
		),
		Filter: key.NewBinding(
			key.WithKeys("/"),
			key.WithHelp("/", "filter"),
		),
		Quit: key.NewBinding(
			key.WithKeys("q"),
			key.WithHelp("q", "quit"),
		),
		ForceQuit: key.NewBinding(
			key.WithKeys("ctrl+c"),
			key.WithHelp("ctrl+c", "force quit"),
		),
		Refresh: key.NewBinding(
			key.WithKeys("r"),
			key.WithHelp("r", "refresh"),
		),
		Help: key.NewBinding(
			key.WithKeys("?"),
			key.WithHelp("?", "help"),
		),
	}
}

// ShortHelp returns minimal keybindings for the compact footer.
func (k KeyMap) ShortHelp() []key.Binding {
	return []key.Binding{k.NextPanel, k.Help, k.Quit}
}

// FullHelp returns the key bindings for the expanded help view.
func (k KeyMap) FullHelp() [][]key.Binding {
	return [][]key.Binding{
		{k.Up, k.Down, k.Select, k.Back},
		{k.NextPanel, k.PrevPanel, k.LeftPanel, k.RightPanel},
		{k.PanelOne, k.PanelTwo, k.PanelThree, k.PanelFour, k.PanelFive, k.PanelSix, k.PanelSeven, k.PanelEight, k.PanelNine, k.Filter},
		{k.Refresh, k.Help, k.Quit, k.ForceQuit},
	}
}
