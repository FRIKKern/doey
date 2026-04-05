package ctl

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// activityPattern matches Claude activity indicators in captured pane output.
var activityPattern = regexp.MustCompile(`(?:⏳|thinking|Thinking|╭─|● |Reading|Writing|Editing|Searching|Running|Bash|Glob|Grep|Agent)`)

// SendVerified sends a message to a Claude pane with verification and retry.
// Pre-clears (Escape, C-u), sends content, verifies delivery via activity detection.
// Retries up to 3 times with exponential backoff (500ms, 1s, 2s).
func (t *TmuxClient) SendVerified(pane string, message string) error {
	const maxRetries = 3
	backoffs := []time.Duration{500 * time.Millisecond, 1 * time.Second, 2 * time.Second}

	// Readiness gate: wait for the Claude prompt to appear before sending
	promptReady := false
	for i := 0; i < 60; i++ { // 60 × 500ms = 30s
		captured, _ := t.CapturePane(pane, 3)
		if strings.Contains(captured, "\u276f") || strings.Contains(captured, ">") {
			promptReady = true
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if !promptReady {
		return fmt.Errorf("ctl: SendVerified: prompt not ready after 30s in pane %s", pane)
	}

	for attempt := 0; attempt < maxRetries; attempt++ {
		// --- Pre-clear: ensure clean input state ---
		t.runQuiet("copy-mode", "-q", "-t", t.paneTarget(pane))
		t.SendKeys(pane, "Escape")
		time.Sleep(100 * time.Millisecond)
		t.SendKeys(pane, "C-u")
		time.Sleep(100 * time.Millisecond)

		// On retries, cancel any stuck operation first
		if attempt > 0 {
			t.SendKeys(pane, "C-c")
			time.Sleep(300 * time.Millisecond)
			t.SendKeys(pane, "Escape")
			time.Sleep(100 * time.Millisecond)
			t.SendKeys(pane, "C-u")
			time.Sleep(100 * time.Millisecond)
		}

		// --- Send the message ---
		hasNewline := strings.Contains(message, "\n")
		if !hasNewline && len(message) < 500 {
			// Short single-line: type text, settle, then Enter
			t.SendKeys(pane, "--", message)
			time.Sleep(300 * time.Millisecond)
			t.SendKeys(pane, "Enter")
		} else {
			// Long/multi-line: tmpfile → load-buffer → paste-buffer
			tmpfile, err := os.CreateTemp("", "doey_send_*.txt")
			if err != nil {
				continue
			}
			tmpPath := tmpfile.Name()
			_, writeErr := tmpfile.WriteString(message)
			tmpfile.Close()
			if writeErr != nil {
				os.Remove(tmpPath)
				continue
			}

			if _, err := t.Run("load-buffer", tmpPath); err != nil {
				os.Remove(tmpPath)
				continue
			}
			if _, err := t.Run("paste-buffer", "-t", t.paneTarget(pane)); err != nil {
				os.Remove(tmpPath)
				continue
			}
			os.Remove(tmpPath)

			time.Sleep(300 * time.Millisecond)
			t.SendKeys(pane, "Enter")
		}

		// --- Verify delivery ---
		time.Sleep(backoffs[attempt])

		captured, _ := t.CapturePane(pane, 5)

		// Check 1: pane shows Claude activity
		if activityPattern.MatchString(captured) {
			return nil
		}

		// Check 2: message snippet visible in pane output
		snippet := message
		if len(snippet) > 40 {
			snippet = snippet[:40]
		}
		snippet = strings.ReplaceAll(snippet, "\n", " ")
		if snippet != "" && strings.Contains(captured, snippet) {
			return nil
		}

		// Check 3: BUSY status file
		if t.checkBusyStatus(pane) {
			return nil
		}

		// --- Stuck-text recovery ---
		t.runQuiet("copy-mode", "-q", "-t", t.paneTarget(pane))
		t.SendKeys(pane, "Escape")
		time.Sleep(150 * time.Millisecond)
		t.SendKeys(pane, "Enter")
		time.Sleep(500 * time.Millisecond)

		// Re-verify after recovery
		captured, _ = t.CapturePane(pane, 5)
		if activityPattern.MatchString(captured) {
			return nil
		}
		if t.checkBusyStatus(pane) {
			return nil
		}
	}

	return fmt.Errorf("ctl: SendVerified: delivery failed after %d attempts to %s", maxRetries, pane)
}

// SendCommand sends a shell command to a pane (fire-and-forget).
// Exits copy-mode, sends command + Enter. No verification needed.
func (t *TmuxClient) SendCommand(pane string, command string) error {
	t.runQuiet("copy-mode", "-q", "-t", t.paneTarget(pane))
	return t.SendKeys(pane, command, "Enter")
}

// paneTarget returns the full tmux target string for a pane (session:pane).
func (t *TmuxClient) paneTarget(pane string) string {
	return t.sessionName + ":" + pane
}

// runQuiet executes a tmux command, ignoring errors (for best-effort operations).
func (t *TmuxClient) runQuiet(args ...string) {
	t.Run(args...)
}

// checkBusyStatus checks whether the target pane's status file shows BUSY.
func (t *TmuxClient) checkBusyStatus(pane string) bool {
	runtimeDir := os.Getenv("DOEY_RUNTIME")
	if runtimeDir == "" {
		// Try to read it from tmux environment
		if val, err := t.ShowEnv("DOEY_RUNTIME"); err == nil {
			runtimeDir = val
		}
	}
	if runtimeDir == "" {
		return false
	}

	// Convert pane target to safe filename: "2.1" → "SESSION_2_1"
	target := t.paneTarget(pane)
	safe := strings.NewReplacer(":", "_", ".", "_", "-", "_").Replace(target)
	statusFile := filepath.Join(runtimeDir, "status", safe+".status")

	data, err := os.ReadFile(statusFile)
	if err != nil {
		return false
	}

	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "STATUS:") {
			val := strings.TrimSpace(strings.TrimPrefix(line, "STATUS:"))
			return val == "BUSY"
		}
		if strings.HasPrefix(line, "STATUS=") {
			val := strings.TrimSpace(strings.TrimPrefix(line, "STATUS="))
			return val == "BUSY"
		}
	}
	return false
}
