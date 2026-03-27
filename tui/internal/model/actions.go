package model

import (
	"fmt"
	"os/exec"
	"strconv"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/doey-cli/doey/tui/internal/runtime"
)

// --- Result message types ---

// LaunchTeamResultMsg is returned after a "doey add-team" command finishes.
type LaunchTeamResultMsg struct {
	Name string
	Err  error
}

// StopTeamResultMsg is returned after a "doey kill-window" command finishes.
type StopTeamResultMsg struct {
	Name string
	Err  error
}

// ToggleStarResultMsg is returned after toggling a team's starred state.
type ToggleStarResultMsg struct {
	Name    string
	Starred bool
	Err     error
}

// ToggleStartupResultMsg is returned after toggling a team's startup state.
type ToggleStartupResultMsg struct {
	Name    string
	Startup bool
	Err     error
}

// SnapshotRefreshMsg requests a fresh snapshot read.
type SnapshotRefreshMsg struct{}

// --- Command functions ---

// LaunchTeamCmd runs "doey add-team <name>" to spawn a new team window.
func LaunchTeamCmd(name string) tea.Cmd {
	return func() tea.Msg {
		path, err := exec.LookPath("doey")
		if err != nil {
			return LaunchTeamResultMsg{Name: name, Err: fmt.Errorf("doey not found in PATH: %w", err)}
		}
		cmd := exec.Command(path, "add-team", name)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return LaunchTeamResultMsg{Name: name, Err: fmt.Errorf("%w: %s", err, out)}
		}
		return LaunchTeamResultMsg{Name: name, Err: nil}
	}
}

// StopTeamCmd runs "doey kill-window <windowIdx>" to stop a running team.
func StopTeamCmd(name string, windowIdx int) tea.Cmd {
	return func() tea.Msg {
		path, err := exec.LookPath("doey")
		if err != nil {
			return StopTeamResultMsg{Name: name, Err: fmt.Errorf("doey not found in PATH: %w", err)}
		}
		cmd := exec.Command(path, "kill-window", strconv.Itoa(windowIdx))
		out, err := cmd.CombinedOutput()
		if err != nil {
			return StopTeamResultMsg{Name: name, Err: fmt.Errorf("%w: %s", err, out)}
		}
		return StopTeamResultMsg{Name: name, Err: nil}
	}
}

// ToggleStarCmd reads the team user config, toggles starred, and writes back.
func ToggleStarCmd(name string) tea.Cmd {
	return func() tea.Msg {
		cfg, err := runtime.ReadTeamUserConfig()
		if err != nil {
			return ToggleStarResultMsg{Name: name, Err: err}
		}
		cfg.ToggleStar(name)
		if err := runtime.WriteTeamUserConfig(cfg); err != nil {
			return ToggleStarResultMsg{Name: name, Err: err}
		}
		return ToggleStarResultMsg{Name: name, Starred: cfg.IsStarred(name), Err: nil}
	}
}

// ToggleStartupCmd reads the team user config, toggles startup, and writes back.
func ToggleStartupCmd(name string) tea.Cmd {
	return func() tea.Msg {
		cfg, err := runtime.ReadTeamUserConfig()
		if err != nil {
			return ToggleStartupResultMsg{Name: name, Err: err}
		}
		cfg.ToggleStartup(name)
		if err := runtime.WriteTeamUserConfig(cfg); err != nil {
			return ToggleStartupResultMsg{Name: name, Err: err}
		}
		return ToggleStartupResultMsg{Name: name, Startup: cfg.IsStartup(name), Err: nil}
	}
}

// RefreshSnapshotCmd returns a message that triggers a fresh snapshot read.
func RefreshSnapshotCmd() tea.Msg {
	return SnapshotRefreshMsg{}
}
