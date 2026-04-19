package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	zone "github.com/lrstanley/bubblezone"

	discordcli "github.com/doey-cli/doey/tui/internal/discord/cli"
	"github.com/doey-cli/doey/tui/internal/intentselect"
	"github.com/doey-cli/doey/tui/internal/model"
	"github.com/doey-cli/doey/tui/internal/picker"
	"github.com/doey-cli/doey/tui/internal/setup"
	"github.com/doey-cli/doey/tui/internal/startup"
)

const version = "doey-tui v0.1.0"

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "discord":
			// Phase-1 cold-start note (masterplan line 244): this dispatch
			// runs before the TUI Program/Model is constructed, but the
			// bubbletea/sqlite/lipgloss imports above still resolve at
			// process start. Phase 2 may split discord into its own binary
			// if cold-start exceeds budget. The `discord` code path does
			// NOT import tui/internal/model or any tea package.
			os.Exit(discordcli.Run(os.Args[2:], os.Stdout, os.Stderr))
		case "--version":
			fmt.Println(version)
			return
		case "--help", "-h":
			fmt.Fprintf(os.Stderr, "Usage: doey-tui <runtime-dir>\n       doey-tui setup\n       doey-tui menu --projects-file <path> [--cwd <dir>] [--grid <layout>]\n       doey-tui startup --progress-file <path> [flags]\n       doey-tui --version\n")
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
			if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
				fmt.Fprintf(os.Stderr, "Error writing result: %v\n", err)
				os.Exit(1)
			}
			return
		case "menu":
			fs := flag.NewFlagSet("menu", flag.ExitOnError)
			projectsFile := fs.String("projects-file", "", "path to projects registry file")
			cwd := fs.String("cwd", "", "current working directory")
			grid := fs.String("grid", "", "grid layout to pass through")
			fs.Parse(os.Args[2:])

			if *projectsFile == "" {
				fmt.Fprintf(os.Stderr, "Usage: doey-tui menu --projects-file <path> [--cwd <dir>] [--grid <layout>]\n")
				os.Exit(1)
			}
			if *cwd == "" {
				*cwd, _ = os.Getwd()
			}

			result, err := picker.Run(*projectsFile, *cwd, *grid)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: %v\n", err)
				os.Exit(1)
			}
			if result.Action == "quit" {
				os.Exit(0)
			}
			if err := picker.PrintJSON(result); err != nil {
				fmt.Fprintf(os.Stderr, "Error writing result: %v\n", err)
				os.Exit(1)
			}
			return
		case "intent-select":
			os.Exit(intentselect.Run())
		case "startup":
			fs := flag.NewFlagSet("startup", flag.ExitOnError)
			session := fs.String("session", "", "tmux session name")
			dir := fs.String("dir", "", "project directory")
			runtime := fs.String("runtime", "", "runtime directory")
			progressFile := fs.String("progress-file", "", "path to progress file to tail for STEP lines")
			timeout := fs.Int("timeout", 60, "max wait time in seconds")
			fs.Parse(os.Args[2:])

			if *progressFile == "" {
				fmt.Fprintf(os.Stderr, "Usage: doey-tui startup --progress-file <path> [--session <name>] [--dir <path>] [--runtime <dir>] [--timeout <seconds>]\n")
				os.Exit(1)
			}

			cfg := startup.Config{
				Session:      *session,
				Dir:          *dir,
				Runtime:      *runtime,
				ProgressFile: *progressFile,
				Timeout:      time.Duration(*timeout) * time.Second,
			}
			os.Exit(startup.Run(cfg))
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
