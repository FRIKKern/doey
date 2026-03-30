package main

import (
	"encoding/json"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/model"
	"github.com/doey-cli/doey/tui/internal/setup"
)

const version = "doey-tui v0.1.0"

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--version":
			fmt.Println(version)
			return
		case "setup":
			result, err := setup.Run()
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: %v\n", err)
				os.Exit(1)
			}
			if result.Cancelled {
				os.Exit(1)
			}
			json.NewEncoder(os.Stdout).Encode(result)
			return
		}
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
