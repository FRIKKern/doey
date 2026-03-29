package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/model"
)

const version = "doey-tui v0.1.0"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--version" {
		fmt.Println(version)
		return
	}

	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "usage: doey-tui <runtime-dir>\n")
		os.Exit(1)
	}

	runtimeDir := os.Args[1]
	zone.NewGlobal()
	m := model.New(runtimeDir)

	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
