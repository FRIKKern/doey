package model

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/doey-cli/doey/tui/internal/ctl"
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

// CreateSpecializedTeamResultMsg is returned after sending a create-specialized-team command to Boss.
type CreateSpecializedTeamResultMsg struct {
	Err error
}

// SnapshotRefreshMsg requests a fresh snapshot read.
type SnapshotRefreshMsg struct{}

// --- Boss command result types ---

// GetStatusResultMsg is returned after sending a status request to Boss.
type GetStatusResultMsg struct{ Err error }

// CompactTaskmasterResultMsg is returned after sending a compact-Taskmaster command to Boss.
type CompactTaskmasterResultMsg struct{ Err error }

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

// DispatchTeamCmd writes a .msg file to the Taskmaster's message inbox.
func DispatchTeamCmd(runtimeDir string, sessionName string, windowIdx int, task string) tea.Cmd {
	return func() tea.Msg {
		// Target: Taskmaster at pane 1.0 (Core Team window)
		smSafe := strings.NewReplacer("-", "_", ":", "_", ".", "_").Replace(sessionName) + "_1_0"
		msgDir := filepath.Join(runtimeDir, "messages")
		if err := os.MkdirAll(msgDir, 0755); err != nil {
			return DispatchTeamResultMsg{WindowIdx: windowIdx, Err: fmt.Errorf("create message dir: %w", err)}
		}

		content := fmt.Sprintf("FROM: TUI\nSUBJECT: task\nTARGET_TEAM: %d\n%s\n", windowIdx, task)
		filename := fmt.Sprintf("%s_%d_%d.msg", smSafe, time.Now().Unix(), os.Getpid())
		path := filepath.Join(msgDir, filename)

		if err := os.WriteFile(path, []byte(content), 0644); err != nil {
			return DispatchTeamResultMsg{WindowIdx: windowIdx, Err: err}
		}

		// Touch trigger file to wake the Taskmaster
		triggerDir := filepath.Join(runtimeDir, "triggers")
		if err := os.MkdirAll(triggerDir, 0755); err != nil {
			log.Printf("ipc: trigger mkdir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(triggerDir, smSafe+".trigger"), []byte{}, 0644); err != nil {
			log.Printf("ipc: trigger write: %v", err)
		}

		return DispatchTeamResultMsg{WindowIdx: windowIdx, Err: nil}
	}
}

// sendToBoss sends a text command to the Boss pane (0.1) via verified delivery.
func sendToBoss(text string) error {
	sessionName := os.Getenv("SESSION_NAME")
	if sessionName == "" {
		sessionName = "doey-doey"
	}
	c := ctl.NewTmuxClient(sessionName)
	return c.SendVerified("0.1", text)
}

// SpawnFreelancerCmd sends a "/doey-add-team freelancer" command to the Boss pane.
func SpawnFreelancerCmd() tea.Cmd {
	return func() tea.Msg {
		return SpawnFreelancerResultMsg{Err: sendToBoss("/doey-add-team freelancer")}
	}
}

// CreateTeamCmd runs "doey add-window" to spawn a reserved team with
// 1 Subtaskmaster (W.0) + 6 Workers (W.1..W.6). The team env file gets
// RESERVED="true" so the Taskmaster won't dispatch work to it until the
// user explicitly assigns a task.
//
// --type team keeps it a regular team (Subtaskmaster + Workers) — without
// it, the shell's "--reserved implies freelancer" shortcut would turn this
// into a managerless freelancer pool instead.
//
// Runs in a bubbletea Cmd goroutine so the dashboard UI stays responsive
// while the spawn is in progress.
func CreateTeamCmd() tea.Cmd {
	return func() tea.Msg {
		path, err := exec.LookPath("doey")
		if err != nil {
			return CreateTeamResultMsg{Err: fmt.Errorf("doey not found in PATH: %w", err)}
		}
		cmd := exec.Command(path, "add-window", "--workers", "6", "--reserved", "--type", "team")
		out, err := cmd.CombinedOutput()
		if err != nil {
			return CreateTeamResultMsg{Err: fmt.Errorf("%w: %s", err, out)}
		}
		return CreateTeamResultMsg{}
	}
}

// CreateSpecializedTeamCmd runs "doey add-team <name>" to spawn a team from a .team.md definition.
// If name is empty, returns an error prompting the user to select a team definition.
func CreateSpecializedTeamCmd(name string) tea.Cmd {
	return func() tea.Msg {
		if name == "" {
			return CreateSpecializedTeamResultMsg{Err: fmt.Errorf("no team definition specified — use doey teams to list available definitions")}
		}
		path, err := exec.LookPath("doey")
		if err != nil {
			return CreateSpecializedTeamResultMsg{Err: fmt.Errorf("doey not found in PATH: %w", err)}
		}
		cmd := exec.Command(path, "add-team", name)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return CreateSpecializedTeamResultMsg{Err: fmt.Errorf("%w: %s", err, out)}
		}
		return CreateSpecializedTeamResultMsg{}
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

// CompactTaskmasterCmd sends a compact-Taskmaster command to Boss.
func CompactTaskmasterCmd() tea.Cmd {
	return func() tea.Msg {
		return CompactTaskmasterResultMsg{Err: sendToBoss("/doey-taskmaster-compact")}
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

// ReviewVerdictMsg is emitted when the user accepts or denies a task review.
type ReviewVerdictMsg struct {
	ID      string
	Verdict string // "accepted" or "rejected"
}

// ReviewVerdictResultMsg is returned after setting the review verdict.
type ReviewVerdictResultMsg struct {
	Err error
}

// ReviewVerdictCmd updates the review_verdict field on a task in the DB store.
func ReviewVerdictCmd(id, verdict string) tea.Cmd {
	return func() tea.Msg {
		store, err := runtime.ReadTaskStore()
		if err != nil {
			return ReviewVerdictResultMsg{Err: err}
		}
		t := store.FindTask(id)
		if t != nil {
			t.ReviewVerdict = verdict
			t.Updated = time.Now().Unix()
		}
		if err := runtime.WriteTaskStore(store); err != nil {
			return ReviewVerdictResultMsg{Err: err}
		}
		return ReviewVerdictResultMsg{}
	}
}

// DispatchTaskMsg is emitted when the user dispatches a task to the Taskmaster.
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

// DispatchTaskCmd dispatches a task to Taskmaster via .msg file.
func DispatchTaskCmd(runtimeDir, sessionName, id, title string) tea.Cmd {
	return func() tea.Msg {
		smSafe := strings.NewReplacer("-", "_", ":", "_", ".", "_").Replace(sessionName) + "_1_0"
		msgDir := filepath.Join(runtimeDir, "messages")
		if err := os.MkdirAll(msgDir, 0755); err != nil {
			return DispatchTaskResultMsg{Err: fmt.Errorf("create message dir: %w", err)}
		}

		content := fmt.Sprintf("FROM: TUI\nSUBJECT: task\nTASK_ID: %s\n%s\n", id, title)
		filename := fmt.Sprintf("%s_%d_%d.msg", smSafe, time.Now().Unix(), os.Getpid())
		path := filepath.Join(msgDir, filename)

		if err := os.WriteFile(path, []byte(content), 0644); err != nil {
			return DispatchTaskResultMsg{Err: err}
		}

		// Touch trigger
		triggerDir := filepath.Join(runtimeDir, "triggers")
		if err := os.MkdirAll(triggerDir, 0755); err != nil {
			log.Printf("ipc: trigger mkdir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(triggerDir, smSafe+".trigger"), []byte{}, 0644); err != nil {
			log.Printf("ipc: trigger write: %v", err)
		}

		// Mark task as in_progress
		store, err := runtime.ReadTaskStore()
		if err != nil {
			log.Printf("ipc: read task store: %v", err)
		} else {
			if t := store.FindTask(id); t != nil {
				t.Status = "in_progress"
				t.Updated = time.Now().Unix()
			}
			if err := runtime.WriteTaskStore(store); err != nil {
				log.Printf("ipc: write task store: %v", err)
			}
		}

		return DispatchTaskResultMsg{}
	}
}
