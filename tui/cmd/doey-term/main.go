package main

import (
	"flag"
	"fmt"
	"os"

	tea "charm.land/bubbletea/v2"

	"github.com/doey-cli/doey/tui/internal/term"
)

func main() {
	shell := flag.String("shell", "", "shell to use (default: $SHELL or /bin/bash)")
	flag.Parse()

	sh := *shell
	if sh == "" {
		sh = os.Getenv("SHELL")
		if sh == "" {
			sh = "/bin/bash"
		}
	}

	m := term.New(sh)
	p := tea.NewProgram(m)
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
