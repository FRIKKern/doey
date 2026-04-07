// Package picker implements the interactive project picker for doey startup.
// Outputs JSON to stdout so the shell caller can act on the selection.
package picker

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
)

// Project represents a registered doey project.
type Project struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Running bool   `json:"running"`
}

// Result is the JSON output from the picker.
type Result struct {
	Action  string `json:"action"`  // open, restart, kill, init, quit
	Name    string `json:"name"`    // project name (empty for init/quit)
	Path    string `json:"path"`    // project path
	Grid    string `json:"grid"`    // grid layout passthrough
}

// sessionExists checks if a tmux session exists.
func sessionExists(name string) bool {
	cmd := exec.Command("tmux", "has-session", "-t", name)
	return cmd.Run() == nil
}

// LoadProjects reads the projects file and returns a list of projects.
func LoadProjects(projectsFile string) []Project {
	data, err := os.ReadFile(projectsFile)
	if err != nil {
		return nil
	}

	var projects []Project
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		name, path := parts[0], parts[1]
		running := sessionExists("doey-" + name)
		projects = append(projects, Project{Name: name, Path: path, Running: running})
	}
	return projects
}

// Run shows the project picker and returns the result.
func Run(projectsFile, cwd, grid string) (Result, error) {
	projects := LoadProjects(projectsFile)

	titleStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("99")).
		MarginBottom(1)

	dimStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("240"))

	// No projects — offer to init
	if len(projects) == 0 {
		fmt.Fprintln(os.Stderr, titleStyle.Render("◆ Doey"))
		fmt.Fprintln(os.Stderr, dimStyle.Render("  No projects registered."))
		fmt.Fprintln(os.Stderr)

		var choice string
		err := huh.NewForm(
			huh.NewGroup(
				huh.NewSelect[string]().
					Title("What would you like to do?").
					Options(
						huh.NewOption("Initialize current directory as project", "init"),
						huh.NewOption("Quit", "quit"),
					).
					Value(&choice),
			),
		).WithTheme(huh.ThemeCharm()).Run()
		if err != nil {
			return Result{Action: "quit"}, nil
		}
		return Result{Action: choice, Path: cwd, Grid: grid}, nil
	}

	// Build project options
	options := make([]huh.Option[string], 0, len(projects)+1)
	for _, p := range projects {
		icon := "○"
		status := "stopped"
		if p.Running {
			icon = "●"
			status = "running"
		}
		shortPath := p.Path
		if home, err := os.UserHomeDir(); err == nil {
			shortPath = strings.Replace(p.Path, home, "~", 1)
		}
		label := fmt.Sprintf("%s %-18s %s  %s", icon, p.Name, dimStyle.Render(shortPath), dimStyle.Render(status))
		options = append(options, huh.NewOption(label, p.Name))
	}
	options = append(options, huh.NewOption("+ Initialize current directory", "__init__"))

	fmt.Fprintln(os.Stderr, titleStyle.Render("◆ Doey — Project Picker"))
	fmt.Fprintln(os.Stderr, dimStyle.Render(fmt.Sprintf("  Current directory: %s", cwd)))
	fmt.Fprintln(os.Stderr)

	// Step 1: Pick a project
	var selected string
	err := huh.NewForm(
		huh.NewGroup(
			huh.NewSelect[string]().
				Title("Select a project:").
				Options(options...).
				Value(&selected),
		),
	).WithTheme(huh.ThemeCharm()).Run()
	if err != nil {
		return Result{Action: "quit", Grid: grid}, nil
	}

	if selected == "__init__" {
		return Result{Action: "init", Path: cwd, Grid: grid}, nil
	}

	// Find the selected project
	var proj Project
	for _, p := range projects {
		if p.Name == selected {
			proj = p
			break
		}
	}

	// Step 2: Pick an action
	actionOptions := []huh.Option[string]{
		huh.NewOption("Open", "open"),
	}
	if proj.Running {
		actionOptions = append(actionOptions,
			huh.NewOption("Restart", "restart"),
			huh.NewOption("Kill", "kill"),
		)
	}
	actionOptions = append(actionOptions, huh.NewOption("Back", "back"))

	var action string
	err = huh.NewForm(
		huh.NewGroup(
			huh.NewSelect[string]().
				Title(fmt.Sprintf("Action for %s:", proj.Name)).
				Options(actionOptions...).
				Value(&action),
		),
	).WithTheme(huh.ThemeCharm()).Run()
	if err != nil || action == "back" {
		// Recurse to show picker again
		return Run(projectsFile, cwd, grid)
	}

	return Result{
		Action: action,
		Name:   proj.Name,
		Path:   proj.Path,
		Grid:   grid,
	}, nil
}

// PrintJSON writes the result as JSON to stdout.
func PrintJSON(r Result) error {
	return json.NewEncoder(os.Stdout).Encode(r)
}
