package model

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

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

// SpawnFreelancerResultMsg is returned after sending a spawn-freelancer command to Boss.
type SpawnFreelancerResultMsg struct {
	Err error
}

// CreateTeamResultMsg is returned after sending a create-team command to Boss.
type CreateTeamResultMsg struct {
	Err error
}

// SnapshotRefreshMsg requests a fresh snapshot read.
type SnapshotRefreshMsg struct{}

// --- Boss command result types ---

// GetStatusResultMsg is returned after sending a status request to Boss.
type GetStatusResultMsg struct{ Err error }

// CompactSMResultMsg is returned after sending a compact-SM command to Boss.
type CompactSMResultMsg struct{ Err error }

// BossNewTaskResultMsg is returned after sending a new-task command to Boss.
type BossNewTaskResultMsg struct{ Err error }

// BossMarkDoneResultMsg is returned after sending a mark-done command to Boss.
type BossMarkDoneResultMsg struct{ Err error }

// BossCancelTaskResultMsg is returned after sending a cancel-task command to Boss.
type BossCancelTaskResultMsg struct{ Err error }

// BossKillTeamResultMsg is returned after sending a kill-team command to Boss.
type BossKillTeamResultMsg struct{ Err error }

// BossRestartTeamResultMsg is returned after sending a restart-team command to Boss.
type BossRestartTeamResultMsg struct{ Err error }

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

// DispatchTeamMsg is emitted when the user wants to dispatch a task to a running team.
type DispatchTeamMsg struct {
	WindowIdx int
	Task      string
}

// DispatchTeamResultMsg is returned after writing the dispatch message.
type DispatchTeamResultMsg struct {
	WindowIdx int
	Err       error
}

// DispatchTeamCmd writes a .msg file to the Session Manager's message inbox.
func DispatchTeamCmd(runtimeDir string, sessionName string, windowIdx int, task string) tea.Cmd {
	return func() tea.Msg {
		// Target: Session Manager at pane 0.2
		smSafe := strings.NewReplacer("-", "_", ":", "_", ".", "_").Replace(sessionName) + "_0_2"
		msgDir := filepath.Join(runtimeDir, "messages")
		os.MkdirAll(msgDir, 0755)

		content := fmt.Sprintf("FROM: TUI\nSUBJECT: task\nTARGET_TEAM: %d\n%s\n", windowIdx, task)
		filename := fmt.Sprintf("%s_%d_%d.msg", smSafe, time.Now().Unix(), os.Getpid())
		path := filepath.Join(msgDir, filename)

		if err := os.WriteFile(path, []byte(content), 0644); err != nil {
			return DispatchTeamResultMsg{WindowIdx: windowIdx, Err: err}
		}

		// Touch trigger file to wake the Session Manager
		triggerDir := filepath.Join(runtimeDir, "triggers")
		os.MkdirAll(triggerDir, 0755)
		os.WriteFile(filepath.Join(triggerDir, smSafe+".trigger"), []byte{}, 0644)

		return DispatchTeamResultMsg{WindowIdx: windowIdx, Err: nil}
	}
}

// sendToBoss sends a text command to the Boss pane (0.1) via tmux send-keys.
func sendToBoss(text string) error {
	sessionName := os.Getenv("SESSION_NAME")
	if sessionName == "" {
		sessionName = "doey-doey"
	}
	cmd := exec.Command("tmux", "send-keys", "-t", sessionName+":0.1", text, "Enter")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, out)
	}
	return nil
}

// SpawnFreelancerCmd sends a "/doey-add-team freelancer" command to the Boss pane.
func SpawnFreelancerCmd() tea.Cmd {
	return func() tea.Msg {
		return SpawnFreelancerResultMsg{Err: sendToBoss("/doey-add-team freelancer")}
	}
}

// CreateTeamCmd sends a "create a new team" request to the Boss pane.
func CreateTeamCmd() tea.Cmd {
	return func() tea.Msg {
		return CreateTeamResultMsg{Err: sendToBoss("I want to create a new team")}
	}
}

// RefreshSnapshotCmd returns a message that triggers a fresh snapshot read.
func RefreshSnapshotCmd() tea.Msg {
	return SnapshotRefreshMsg{}
}

// --- Boss command functions ---

// GetStatusCmd sends a status request to Boss.
func GetStatusCmd() tea.Cmd {
	return func() tea.Msg {
		return GetStatusResultMsg{Err: sendToBoss("status?")}
	}
}

// CompactSMCmd sends a compact-SM command to Boss.
func CompactSMCmd() tea.Cmd {
	return func() tea.Msg {
		return CompactSMResultMsg{Err: sendToBoss("/doey-sm-compact")}
	}
}

// BossNewTaskCmd sends a new-task command to Boss.
func BossNewTaskCmd(title string) tea.Cmd {
	return func() tea.Msg {
		return BossNewTaskResultMsg{Err: sendToBoss("I have a new task: " + title)}
	}
}

// BossMarkDoneCmd sends a mark-done command to Boss.
func BossMarkDoneCmd(id string) tea.Cmd {
	return func() tea.Msg {
		return BossMarkDoneResultMsg{Err: sendToBoss("doey task done " + id)}
	}
}

// BossCancelTaskCmd sends a cancel-task command to Boss.
func BossCancelTaskCmd(id string) tea.Cmd {
	return func() tea.Msg {
		return BossCancelTaskResultMsg{Err: sendToBoss("Cancel task " + id)}
	}
}

// BossKillTeamCmd sends a kill-team command to Boss.
func BossKillTeamCmd(windowIdx int) tea.Cmd {
	return func() tea.Msg {
		return BossKillTeamResultMsg{Err: sendToBoss("/doey-kill-window " + strconv.Itoa(windowIdx))}
	}
}

// BossRestartTeamCmd sends a restart-team command to Boss.
func BossRestartTeamCmd(windowIdx int) tea.Cmd {
	return func() tea.Msg {
		return BossRestartTeamResultMsg{Err: sendToBoss("/doey-clear " + strconv.Itoa(windowIdx))}
	}
}

// --- Task management messages ---

// CreateTaskMsg is emitted when the user creates a new task.
type CreateTaskMsg struct {
	Title string
}

// CreateTaskResultMsg is returned after creating a task.
type CreateTaskResultMsg struct {
	ID  string
	Err error
}

// MoveTaskMsg is emitted when the user moves a task to a new status.
type MoveTaskMsg struct {
	ID     string
	Status string // canonical task status
}

// MoveTaskResultMsg is returned after moving a task.
type MoveTaskResultMsg struct {
	Err error
}

// CancelTaskMsg is emitted when the user cancels a task.
type CancelTaskMsg struct {
	ID string
}

// CancelTaskResultMsg is returned after cancelling a task.
type CancelTaskResultMsg struct {
	Err error
}

// SetStatusTaskMsg is emitted when the user sets a task's status directly.
type SetStatusTaskMsg struct {
	ID     string
	Status string
}

// SetStatusTaskResultMsg is returned after setting a task status.
type SetStatusTaskResultMsg struct {
	Err error
}

// SetStatusTaskCmd sets a task's status directly.
func SetStatusTaskCmd(id, status string) tea.Cmd {
	return func() tea.Msg {
		store, err := runtime.ReadTaskStore()
		if err != nil {
			return SetStatusTaskResultMsg{Err: err}
		}
		t := store.FindTask(id)
		if t != nil {
			t.Status = status
			t.Updated = time.Now().Unix()
		}
		if err := runtime.WriteTaskStore(store); err != nil {
			return SetStatusTaskResultMsg{Err: err}
		}
		return SetStatusTaskResultMsg{}
	}
}

// DispatchTaskMsg is emitted when the user dispatches a task to SM.
type DispatchTaskMsg struct {
	ID    string
	Title string
}

// DispatchTaskResultMsg is returned after dispatching a task.
type DispatchTaskResultMsg struct {
	Err error
}

// --- Task command functions ---

// CreateTaskCmd creates a new persistent task.
func CreateTaskCmd(title string) tea.Cmd {
	return func() tea.Msg {
		store, err := runtime.ReadTaskStore()
		if err != nil {
			return CreateTaskResultMsg{Err: err}
		}
		id := store.AddTask(title)
		if err := runtime.WriteTaskStore(store); err != nil {
			return CreateTaskResultMsg{Err: err}
		}
		return CreateTaskResultMsg{ID: id}
	}
}

// MoveTaskCmd moves a task to a new status.
func MoveTaskCmd(id, status string) tea.Cmd {
	return func() tea.Msg {
		store, err := runtime.ReadTaskStore()
		if err != nil {
			return MoveTaskResultMsg{Err: err}
		}
		store.MoveTask(id, status)
		if err := runtime.WriteTaskStore(store); err != nil {
			return MoveTaskResultMsg{Err: err}
		}
		return MoveTaskResultMsg{}
	}
}

// CancelTaskCmd cancels a task.
func CancelTaskCmd(id string) tea.Cmd {
	return func() tea.Msg {
		store, err := runtime.ReadTaskStore()
		if err != nil {
			return CancelTaskResultMsg{Err: err}
		}
		store.CancelTask(id)
		if err := runtime.WriteTaskStore(store); err != nil {
			return CancelTaskResultMsg{Err: err}
		}
		return CancelTaskResultMsg{}
	}
}

// DispatchTaskCmd dispatches a task to Session Manager via .msg file.
func DispatchTaskCmd(runtimeDir, sessionName, id, title string) tea.Cmd {
	return func() tea.Msg {
		smSafe := strings.NewReplacer("-", "_", ":", "_", ".", "_").Replace(sessionName) + "_0_2"
		msgDir := filepath.Join(runtimeDir, "messages")
		os.MkdirAll(msgDir, 0755)

		content := fmt.Sprintf("FROM: TUI\nSUBJECT: task\nTASK_ID: %s\n%s\n", id, title)
		filename := fmt.Sprintf("%s_%d_%d.msg", smSafe, time.Now().Unix(), os.Getpid())
		path := filepath.Join(msgDir, filename)

		if err := os.WriteFile(path, []byte(content), 0644); err != nil {
			return DispatchTaskResultMsg{Err: err}
		}

		// Touch trigger
		triggerDir := filepath.Join(runtimeDir, "triggers")
		os.MkdirAll(triggerDir, 0755)
		os.WriteFile(filepath.Join(triggerDir, smSafe+".trigger"), []byte{}, 0644)

		// Mark task as in_progress
		store, _ := runtime.ReadTaskStore()
		if t := store.FindTask(id); t != nil {
			t.Status = "in_progress"
			t.Updated = time.Now().Unix()
		}
		runtime.WriteTaskStore(store)

		return DispatchTaskResultMsg{}
	}
}
