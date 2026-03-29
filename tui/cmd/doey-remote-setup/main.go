package main

import (
	"flag"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/doey-cli/doey/tui/internal/remote"
	"github.com/doey-cli/doey/tui/internal/styles"
)

func main() {
	configPath := flag.String("config", remote.DefaultConfigPath(), "config file path")
	flag.Parse()

	theme := styles.DefaultTheme()
	cfg, err := remote.LoadConfig(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Warning: could not load config: %v\n", err)
		cfg = remote.DefaultConfig()
	}

	wizard := remote.NewWizard(theme, cfg, *configPath)
	p := tea.NewProgram(wizard, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
