// Package ctl provides tmux interaction for the doey-ctl CLI.
package ctl

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"sync"
)

// PaneInfo holds metadata about a single tmux pane.
type PaneInfo struct {
	ID        string // Compound ID, e.g. "3.1" (window.pane).
	Title     string // Pane title set via select-pane -T.
	PID       int    // Shell PID inside the pane.
	WindowIdx int    // Zero-based window index.
	PaneIdx   int    // Zero-based pane index within the window.
}

// TmuxClient wraps tmux CLI commands for a specific session.
type TmuxClient struct {
	sessionName string

	cacheMu    sync.Mutex
	cacheReady bool
	cacheMap   map[int][]PaneInfo // windowIdx → panes
}

// NewTmuxClient creates a TmuxClient bound to the given tmux session.
func NewTmuxClient(sessionName string) *TmuxClient {
	return &TmuxClient{sessionName: sessionName}
}

// Run executes an arbitrary tmux command and returns its stdout.
func (t *TmuxClient) Run(args ...string) (string, error) {
	cmd := exec.Command("tmux", args...)
	out, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return "", fmt.Errorf("ctl: tmux %s: %s", strings.Join(args, " "), strings.TrimSpace(string(ee.Stderr)))
		}
		return "", fmt.Errorf("ctl: tmux %s: %w", strings.Join(args, " "), err)
	}
	return strings.TrimRight(string(out), "\n"), nil
}

// ListPanes returns pane info for every pane in the given window.
func (t *TmuxClient) ListPanes(windowIdx int) ([]PaneInfo, error) {
	target := fmt.Sprintf("%s:%d", t.sessionName, windowIdx)
	out, err := t.Run("list-panes", "-t", target, "-F", "#{pane_index}\t#{pane_title}\t#{pane_pid}")
	if err != nil {
		return nil, fmt.Errorf("ctl: list-panes window %d: %w", windowIdx, err)
	}
	if out == "" {
		return nil, nil
	}

	var panes []PaneInfo
	for _, line := range strings.Split(out, "\n") {
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) < 3 {
			continue
		}
		idx, err := strconv.Atoi(parts[0])
		if err != nil {
			continue
		}
		pid, _ := strconv.Atoi(parts[2])
		panes = append(panes, PaneInfo{
			ID:        fmt.Sprintf("%d.%d", windowIdx, idx),
			Title:     parts[1],
			PID:       pid,
			WindowIdx: windowIdx,
			PaneIdx:   idx,
		})
	}
	return panes, nil
}

// SendKeys sends keystrokes to the specified pane (e.g. "3.1").
func (t *TmuxClient) SendKeys(pane string, keys ...string) error {
	args := []string{"send-keys", "-t", t.sessionName + ":" + pane}
	args = append(args, keys...)
	_, err := t.Run(args...)
	if err != nil {
		return fmt.Errorf("ctl: send-keys %s: %w", pane, err)
	}
	return nil
}

// CapturePane captures the last N lines of visible output from a pane.
func (t *TmuxClient) CapturePane(pane string, lines int) (string, error) {
	out, err := t.Run("capture-pane", "-t", t.sessionName+":"+pane, "-p", "-S", fmt.Sprintf("-%d", lines))
	if err != nil {
		return "", fmt.Errorf("ctl: capture-pane %s: %w", pane, err)
	}
	return out, nil
}

// ShowEnv reads a tmux environment variable from the session.
func (t *TmuxClient) ShowEnv(name string) (string, error) {
	out, err := t.Run("show-environment", "-t", t.sessionName, name)
	if err != nil {
		return "", fmt.Errorf("ctl: show-environment %s: %w", name, err)
	}
	// Output format: NAME=VALUE
	if idx := strings.IndexByte(out, '='); idx >= 0 {
		return out[idx+1:], nil
	}
	return "", fmt.Errorf("ctl: show-environment %s: unexpected format %q", name, out)
}

// ClearCache resets the cached pane list so the next ListPanes call re-queries tmux.
func (t *TmuxClient) ClearCache() {
	t.cacheMu.Lock()
	t.cacheReady = false
	t.cacheMap = nil
	t.cacheMu.Unlock()
}
