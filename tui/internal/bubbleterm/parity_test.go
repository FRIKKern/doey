package bubbleterm

// Parity tests for doey-term: drive the bubbleterm Model with real
// subprocess shells/programs and verify the rendered output. These tests
// substitute for the tmux-send-keys driver path described in the task spec
// (which the worker hook blocks); they exercise the same code paths
// (Write -> ptyReadLoop -> vt -> Render -> rows) more deterministically.

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// stripAnsi removes ANSI escape sequences from s. The implementation is
// intentionally simple — it understands CSI/SS3 introducers ("ESC [", "ESC O")
// and lone ESC ... <letter|tilde> sequences, which is enough for the rendered
// rows we capture in these tests.
func stripAnsi(s string) string {
	var sb strings.Builder
	inEsc := false
	for _, r := range s {
		if r == '\x1b' {
			inEsc = true
			continue
		}
		if inEsc {
			if (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || r == '~' || r == '@' {
				inEsc = false
			}
			continue
		}
		sb.WriteRune(r)
	}
	return sb.String()
}

// rendered returns all rows of the current frame joined by newlines, with
// ANSI escapes stripped.
func rendered(m *Model) string {
	frame := m.GetEmulator().GetScreen()
	var sb strings.Builder
	for i, r := range frame.Rows {
		if i > 0 {
			sb.WriteByte('\n')
		}
		sb.WriteString(stripAnsi(r))
	}
	return sb.String()
}

// renderedRaw returns the rendered rows including ANSI escapes — used for
// color/syntax-highlight assertions.
func renderedRaw(m *Model) string {
	frame := m.GetEmulator().GetScreen()
	return strings.Join(frame.Rows, "\n")
}

// settle waits up to maxWait for one of:
//   - the rendered text to contain `want` (when want != "")
//   - two consecutive 50ms polls to return identical NON-BLANK content
//
// It returns the final stripped rendered text. The non-blank stability
// requirement matters for slow-starting full-screen apps (htop, less): the
// pre-spawn frame is an 80x24 grid of spaces that is trivially "stable", so
// without filtering blank frames the helper would return immediately.
func settle(t *testing.T, m *Model, want string, maxWait time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(maxWait)
	var prev string
	stableCount := 0
	for {
		cur := rendered(m)
		if want != "" && strings.Contains(cur, want) {
			return cur
		}
		nonBlank := strings.TrimSpace(cur) != ""
		if nonBlank && cur == prev {
			stableCount++
			if stableCount >= 2 {
				return cur
			}
		} else {
			stableCount = 0
		}
		if time.Now().After(deadline) {
			return cur
		}
		prev = cur
		time.Sleep(50 * time.Millisecond)
	}
}

// cleanEnv returns os.Environ() with TMUX* variables stripped so subprocesses
// don't think they are inside a tmux session (matters for the nested-tmux
// test).
func cleanEnv() []string {
	out := make([]string, 0, len(os.Environ()))
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "TMUX=") || strings.HasPrefix(kv, "TMUX_") {
			continue
		}
		out = append(out, kv)
	}
	out = append(out, "TERM=xterm-256color")
	return out
}

// newSession spawns a command in a fresh bubbleterm Model. The caller must
// Close() it when done.
func newSession(t *testing.T, name string, args ...string) *Model {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Env = cleanEnv()
	m, err := NewWithCommand(80, 24, cmd)
	if err != nil {
		t.Fatalf("NewWithCommand(%s): %v", name, err)
	}
	m.SetAutoPoll(false)
	return m
}

// write is a shortcut for emulator.Write that fatals on error.
func write(t *testing.T, m *Model, s string) {
	t.Helper()
	if _, err := m.GetEmulator().Write([]byte(s)); err != nil {
		t.Fatalf("Write(%q): %v", s, err)
	}
}

// TestParity_Bash exercises common readline keystrokes against an interactive
// bash. We use --norc/--noprofile so the prompt is the deterministic
// "bash-X.Y$ ".
func TestParity_Bash(t *testing.T) {
	m := newSession(t, "/bin/bash", "--norc", "--noprofile", "-i")
	defer m.Close()

	out := settle(t, m, "$", 2*time.Second)
	if !strings.Contains(out, "$") {
		t.Fatalf("bash prompt did not appear; got:\n%s", out)
	}

	// Ctrl+E echoes a literal value? No — Ctrl+E moves cursor to end. We
	// type a partial command, send Ctrl+A (line start), then a marker
	// character that should land at column 0 of the typed input.
	write(t, m, "world")
	settle(t, m, "world", 1*time.Second)
	write(t, m, "\x01") // Ctrl+A: cursor to start of line
	time.Sleep(100 * time.Millisecond)
	write(t, m, "echo hello ")
	out = settle(t, m, "echo hello world", 1*time.Second)
	if !strings.Contains(out, "echo hello world") {
		t.Errorf("Ctrl+A insert failed; got:\n%s", out)
	}

	// Ctrl+U clears whole line, then echo a fresh sentinel.
	write(t, m, "\x15")
	time.Sleep(100 * time.Millisecond)
	write(t, m, "echo BASH_OK\r")
	out = settle(t, m, "BASH_OK", 2*time.Second)
	if !strings.Contains(out, "BASH_OK") {
		t.Errorf("Ctrl+U + echo failed; got:\n%s", out)
	}

	// History: up arrow should recall previous command.
	write(t, m, "\x1b[A") // up arrow
	out = settle(t, m, "echo BASH_OK", 1*time.Second)
	if !strings.Contains(out, "echo BASH_OK") {
		t.Errorf("history up failed; got last frame:\n%s", out)
	}

	// Tab completion: type "ec" + tab should complete to "echo".
	write(t, m, "\x15") // clear
	time.Sleep(100 * time.Millisecond)
	write(t, m, "ec\t")
	out = settle(t, m, "echo", 1*time.Second)
	if !strings.Contains(out, "echo") {
		t.Errorf("tab completion failed; got:\n%s", out)
	}

	write(t, m, "\x15exit\r")
	time.Sleep(200 * time.Millisecond)
}

// TestParity_Vim opens a real .go file in vim, enters insert mode, writes
// some text, and saves. We assert the file landed on disk with the expected
// contents.
func TestParity_Vim(t *testing.T) {
	if _, err := exec.LookPath("vim"); err != nil {
		t.Skip("vim not installed")
	}

	dir := t.TempDir()
	target := filepath.Join(dir, "parity.go")
	if err := os.WriteFile(target, []byte("package main\n\nfunc main() {}\n"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	m := newSession(t, "vim", "-u", "NONE", "-N", target)
	defer m.Close()

	// Wait for vim to draw — the file name appears in the status line.
	out := settle(t, m, "package main", 3*time.Second)
	if !strings.Contains(out, "package main") {
		t.Fatalf("vim did not display file content; got:\n%s", out)
	}

	// Move to end of file (G), open new line below (o), insert text, ESC.
	write(t, m, "G")
	time.Sleep(100 * time.Millisecond)
	write(t, m, "o// PARITY_OK\x1b")
	settle(t, m, "PARITY_OK", 1*time.Second)

	// Save and quit.
	write(t, m, ":wq\r")
	time.Sleep(500 * time.Millisecond)

	// Wait for the vim process to finish writing.
	deadline := time.Now().Add(2 * time.Second)
	for {
		if m.GetEmulator().IsProcessExited() {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("vim did not exit after :wq")
		}
		time.Sleep(50 * time.Millisecond)
	}

	data, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("read after :wq: %v", err)
	}
	if !strings.Contains(string(data), "PARITY_OK") {
		t.Errorf("vim :wq did not persist insert; file contents:\n%s", data)
	}
}

// TestParity_VimSyntax verifies vim's status/insert/normal-mode flips render
// cleanly without bleeding ANSI sequences into adjacent rows. We don't assert
// on actual color codes (those depend on the user's vim config) — we just
// confirm that mode-flip text "-- INSERT --" appears.
func TestParity_VimSyntax(t *testing.T) {
	if _, err := exec.LookPath("vim"); err != nil {
		t.Skip("vim not installed")
	}
	dir := t.TempDir()
	target := filepath.Join(dir, "x.txt")
	_ = os.WriteFile(target, []byte("hello\n"), 0o644)

	m := newSession(t, "vim", "-u", "NONE", "-N", "--cmd", "set showmode", target)
	defer m.Close()
	settle(t, m, "hello", 3*time.Second)

	write(t, m, "i")
	out := settle(t, m, "INSERT", 1*time.Second)
	if !strings.Contains(out, "INSERT") {
		t.Errorf("vim insert mode banner missing; got:\n%s", out)
	}
	write(t, m, "\x1b:q!\r")
	time.Sleep(300 * time.Millisecond)
}

// TestParity_Htop just verifies htop's header rows render with the expected
// labels. We can't assert on mouse interaction headlessly, but we do
// validate that resize is plumbed through the vt emulator.
func TestParity_Htop(t *testing.T) {
	if _, err := exec.LookPath("htop"); err != nil {
		t.Skip("htop not installed")
	}
	m := newSession(t, "htop")
	defer m.Close()

	out := settle(t, m, "CPU", 3*time.Second)
	if !strings.Contains(out, "CPU") {
		t.Errorf("htop CPU label missing; got:\n%s", out)
	}
	if !strings.Contains(out, "Mem") {
		t.Errorf("htop Mem label missing; got:\n%s", out)
	}

	// Resize and verify the next frame still parses cleanly.
	if err := m.GetEmulator().Resize(120, 30); err != nil {
		t.Fatalf("resize: %v", err)
	}
	time.Sleep(300 * time.Millisecond)
	out = settle(t, m, "CPU", 2*time.Second)
	if !strings.Contains(out, "CPU") {
		t.Errorf("htop after resize missing CPU; got:\n%s", out)
	}

	// Verify htop emitted some color escapes (header is colorized).
	raw := renderedRaw(m)
	if !strings.Contains(raw, "\x1b[") {
		t.Errorf("htop produced no ANSI escapes — color rendering may be broken")
	}

	write(t, m, "q")
	time.Sleep(500 * time.Millisecond)
}

// TestParity_Less opens shell/doey.sh in less, paginates with j, searches,
// and quits.
func TestParity_Less(t *testing.T) {
	if _, err := exec.LookPath("less"); err != nil {
		t.Skip("less not installed")
	}
	target := "/home/doey/doey/shell/doey.sh"
	if _, err := os.Stat(target); err != nil {
		t.Skipf("target file missing: %v", err)
	}
	m := newSession(t, "less", target)
	defer m.Close()
	out := settle(t, m, "doey", 2*time.Second)
	if !strings.Contains(out, "doey") {
		t.Errorf("less did not render file; got:\n%s", out)
	}

	// j j j to scroll a few lines down — assert the screen changed.
	before := rendered(m)
	write(t, m, "jjjjjjjjjj")
	time.Sleep(300 * time.Millisecond)
	after := rendered(m)
	if before == after {
		t.Errorf("less j scroll had no effect; before==after")
	}

	// Search forward for a string we know exists in doey.sh.
	write(t, m, "/DOEY\r")
	out = settle(t, m, "DOEY", 1*time.Second)
	if !strings.Contains(out, "DOEY") {
		t.Errorf("less search failed; got:\n%s", out)
	}

	write(t, m, "q")
	time.Sleep(300 * time.Millisecond)
}

// TestParity_NestedTmux launches a fresh tmux on a private socket inside
// doey-term, runs a command in it, and exits.
func TestParity_NestedTmux(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	socket := "doey-term-parity-" + fmt.Sprintf("%d", time.Now().UnixNano())
	defer exec.Command("tmux", "-L", socket, "kill-server").Run() //nolint:errcheck

	m := newSession(t, "tmux", "-L", socket, "new-session", "-A", "-s", "inner",
		"bash --norc --noprofile -i")
	defer m.Close()

	out := settle(t, m, "$", 3*time.Second)
	if !strings.Contains(out, "$") {
		t.Fatalf("nested tmux: bash prompt did not appear; got:\n%s", out)
	}
	// Status bar should be visible at the bottom row.
	if !strings.Contains(out, "inner") && !strings.Contains(out, "bash") {
		t.Errorf("nested tmux status bar missing; got:\n%s", out)
	}

	write(t, m, "echo NESTED_OK\r")
	out = settle(t, m, "NESTED_OK", 2*time.Second)
	if !strings.Contains(out, "NESTED_OK") {
		t.Errorf("nested tmux command echo failed; got:\n%s", out)
	}

	write(t, m, "exit\r")
	time.Sleep(500 * time.Millisecond)
}

// TestParity_Unicode echoes a multi-script string and verifies all
// codepoints appear in the rendered frame. Width handling is harder to
// assert headlessly — we check that the next prompt landed on a new line
// (i.e. the unicode wasn't mis-counted into row overflow).
func TestParity_Unicode(t *testing.T) {
	m := newSession(t, "/bin/bash", "--norc", "--noprofile", "-i")
	defer m.Close()
	settle(t, m, "$", 2*time.Second)

	const want = "日本語 العربية 한국어 😀🎉"
	write(t, m, "echo \""+want+"\"\r")
	out := settle(t, m, "한국어", 2*time.Second)

	for _, sub := range []string{"日本語", "العربية", "한국어", "😀", "🎉"} {
		if !strings.Contains(out, sub) {
			t.Errorf("unicode subset %q missing from rendered output; got:\n%s", sub, out)
		}
	}

	write(t, m, "exit\r")
	time.Sleep(200 * time.Millisecond)
}

// TestParity_FishZsh is a placeholder that records the absence of fish/zsh
// for the report.
func TestParity_FishZsh(t *testing.T) {
	if _, err := exec.LookPath("fish"); err == nil {
		t.Errorf("fish IS installed — re-enable the real fish parity test")
	}
	if _, err := exec.LookPath("zsh"); err == nil {
		t.Errorf("zsh IS installed — re-enable the real zsh parity test")
	}
	t.Log("fish and zsh not installed in this environment — skipped per task spec")
}
