package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testEnv creates an isolated project dir + XDG_CONFIG_HOME + RUNTIME_DIR
// so tests can run without touching the developer's real ~/.config.
type testEnv struct {
	Project string
	XDG     string
	Conf    string
	Runtime string
}

func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	root := t.TempDir()
	proj := filepath.Join(root, "proj")
	xdg := filepath.Join(root, "xdg")
	run := filepath.Join(root, "runtime")
	if err := os.MkdirAll(filepath.Join(proj, ".doey"), 0o755); err != nil {
		t.Fatalf("mkdir proj/.doey: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(xdg, "doey"), 0o700); err != nil {
		t.Fatalf("mkdir xdg/doey: %v", err)
	}
	if err := os.MkdirAll(run, 0o700); err != nil {
		t.Fatalf("mkdir runtime: %v", err)
	}
	conf := filepath.Join(xdg, "doey", "discord.conf")
	t.Setenv("PROJECT_DIR", proj)
	t.Setenv("XDG_CONFIG_HOME", xdg)
	t.Setenv("RUNTIME_DIR", run)
	return &testEnv{Project: proj, XDG: xdg, Conf: conf, Runtime: run}
}

func (e *testEnv) writeBinding(t *testing.T, stanza string) {
	t.Helper()
	p := filepath.Join(e.Project, ".doey", "discord-binding")
	if err := os.WriteFile(p, []byte(stanza+"\n"), 0o644); err != nil {
		t.Fatalf("write binding: %v", err)
	}
}

func (e *testEnv) writeConf(t *testing.T, body string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(e.Conf, []byte(body), mode); err != nil {
		t.Fatalf("write conf: %v", err)
	}
	if err := os.Chmod(e.Conf, mode); err != nil {
		t.Fatalf("chmod conf: %v", err)
	}
}

func runCLI(args ...string) (int, string, string) {
	var out, errb bytes.Buffer
	code := Run(args, &out, &errb)
	return code, out.String(), errb.String()
}

// ── Send — no binding, no --if-bound → exit 1 "no binding" ────────────

func TestSend_NoBinding_Exit1(t *testing.T) {
	_ = newTestEnv(t)
	code, _, stderr := runCLI("send", "--title", "T", "--event", "stop")
	if code != 1 {
		t.Fatalf("exit=%d, want 1; stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, "no binding") {
		t.Fatalf("stderr missing 'no binding': %q", stderr)
	}
}

// ── Send — no binding, --if-bound → exit 0 silently ───────────────────

func TestSend_IfBound_NoBinding_Exit0(t *testing.T) {
	_ = newTestEnv(t)
	code, out, stderr := runCLI("send", "--if-bound", "--title", "T", "--event", "stop")
	if code != 0 {
		t.Fatalf("exit=%d, want 0; stderr=%q", code, stderr)
	}
	if out != "" || stderr != "" {
		t.Fatalf("expected silent; out=%q stderr=%q", out, stderr)
	}
}

// ── Send — bot_dm binding → exit 1 Phase 3 message ────────────────────

func TestSend_BotDM_Phase3Message(t *testing.T) {
	e := newTestEnv(t)
	e.writeBinding(t, "default")
	e.writeConf(t, `[default]
kind=bot_dm
bot_token=Bot.test.token
bot_app_id=1234567890
dm_user_id=1111111111
dm_channel_id=2222222222
`, 0o600)
	code, _, stderr := runCLI("send", "--title", "T", "--event", "stop")
	if code != 1 {
		t.Fatalf("exit=%d, want 1; stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, msgPhase3BotDMPending) {
		t.Fatalf("stderr missing Phase 3 message: %q", stderr)
	}
}

// ── Send — bad creds perms → exit 1 perm complaint ────────────────────

func TestSend_BadPerms_ReportsPerm(t *testing.T) {
	e := newTestEnv(t)
	e.writeBinding(t, "default")
	e.writeConf(t, `[default]
kind=webhook
webhook_url=https://discord.com/api/webhooks/1/abc1
`, 0o644)
	code, _, stderr := runCLI("send", "--title", "T", "--event", "stop")
	if code != 1 {
		t.Fatalf("exit=%d, want 1; stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, "mode 0600") {
		t.Fatalf("expected creds perm complaint; got %q", stderr)
	}
}

// ── Send — rejects --body on argv (body is stdin-only) ─────────────────

func TestSend_RejectsBodyArg(t *testing.T) {
	_ = newTestEnv(t)
	code, _, _ := runCLI("send", "--body", "SECRET")
	if code != 2 {
		t.Fatalf("exit=%d, want 2 (flag parse error)", code)
	}
}

// ── Status — no binding ──────────────────────────────────────────────

func TestStatus_NoBinding(t *testing.T) {
	_ = newTestEnv(t)
	code, out, _ := runCLI("status")
	if code != 0 {
		t.Fatalf("exit=%d, want 0", code)
	}
	if !strings.Contains(out, "not bound") {
		t.Fatalf("expected 'not bound' in stdout: %q", out)
	}
}

func TestStatus_WebhookRedactedLast4(t *testing.T) {
	e := newTestEnv(t)
	e.writeBinding(t, "default")
	e.writeConf(t, `[default]
kind=webhook
webhook_url=https://discord.com/api/webhooks/1/SUPER_SECRETabc1
`, 0o600)
	code, out, _ := runCLI("status")
	if code != 0 {
		t.Fatalf("exit=%d, want 0", code)
	}
	if !strings.Contains(out, "...abc1") {
		t.Fatalf("expected last-4 redaction '...abc1' in stdout: %q", out)
	}
	if strings.Contains(out, "SUPER_SECRET") {
		t.Fatalf("stdout leaked webhook secret: %q", out)
	}
}

func TestStatus_JSON_BotDM(t *testing.T) {
	e := newTestEnv(t)
	e.writeBinding(t, "default")
	e.writeConf(t, `[default]
kind=bot_dm
bot_token=Bot.hidden
bot_app_id=1234567890
dm_user_id=1111111111
dm_channel_id=2222222222
`, 0o600)
	code, out, _ := runCLI("status", "--json")
	if code != 0 {
		t.Fatalf("exit=%d, want 0", code)
	}
	var parsed statusResult
	if err := json.Unmarshal([]byte(out), &parsed); err != nil {
		t.Fatalf("invalid JSON %q: %v", out, err)
	}
	if parsed.Kind != "bot_dm" {
		t.Fatalf("kind=%q, want bot_dm", parsed.Kind)
	}
	if !parsed.Bound || !parsed.CredsOK {
		t.Fatalf("expected bound+creds_ok; got %+v", parsed)
	}
	if strings.Contains(out, "Bot.hidden") {
		t.Fatalf("JSON leaked bot_token: %q", out)
	}
}

func TestStatus_BadPerms_ExitZero(t *testing.T) {
	e := newTestEnv(t)
	e.writeBinding(t, "default")
	e.writeConf(t, `[default]
kind=webhook
webhook_url=https://discord.com/api/webhooks/1/abc1
`, 0o644)
	code, out, _ := runCLI("status")
	if code != 0 {
		t.Fatalf("status must exit 0 regardless; got %d", code)
	}
	if !strings.Contains(out, "creds file mode") {
		t.Fatalf("expected perms note in stdout: %q", out)
	}
}

// ── Remaining stub: bind ─────────────────────────────────────────────

func TestStub_Bind(t *testing.T) {
	_ = newTestEnv(t)
	code, _, stderr := runCLI("bind")
	if code != 1 {
		t.Fatalf("exit=%d, want 1", code)
	}
	if !strings.Contains(stderr, "Phase 3") {
		t.Fatalf("stderr missing Phase 3 tag: %q", stderr)
	}
}

// ── Unbind — no binding: exit 0 still prints "removed" ───────────────

func TestUnbind_NoBinding(t *testing.T) {
	_ = newTestEnv(t)
	code, out, stderr := runCLI("unbind")
	if code != 0 {
		t.Fatalf("exit=%d, want 0; stderr=%q", code, stderr)
	}
	if !strings.Contains(out, "Discord binding removed") {
		t.Fatalf("expected removed message; got %q", out)
	}
}

// ── Reset-breaker — empty state: creates clean state file ────────────

func TestResetBreaker_EmptyState(t *testing.T) {
	e := newTestEnv(t)
	code, out, stderr := runCLI("reset-breaker")
	if code != 0 {
		t.Fatalf("exit=%d, want 0; stderr=%q", code, stderr)
	}
	if !strings.Contains(out, "circuit breaker reset") {
		t.Fatalf("expected reset confirmation; got %q", out)
	}
	if _, err := os.Stat(filepath.Join(e.Runtime, "discord-rl.state")); err != nil {
		t.Fatalf("state file not created: %v", err)
	}
}

// ── Failures — no file, default tail: silent exit 0 ──────────────────

func TestFailures_NoFile(t *testing.T) {
	_ = newTestEnv(t)
	code, out, stderr := runCLI("failures")
	if code != 0 {
		t.Fatalf("exit=%d, want 0; stderr=%q", code, stderr)
	}
	if out != "" {
		t.Fatalf("expected empty stdout; got %q", out)
	}
}

// ── Failures --prune — no file: exit 0, "pruned 0 entries" ───────────

func TestFailures_PruneEmpty(t *testing.T) {
	_ = newTestEnv(t)
	code, out, stderr := runCLI("failures", "--prune")
	if code != 0 {
		t.Fatalf("exit=%d, want 0; stderr=%q", code, stderr)
	}
	if !strings.Contains(out, "pruned 0 entries") {
		t.Fatalf("expected pruned-0 message; got %q", out)
	}
}

// ── Unknown subcommand ───────────────────────────────────────────────

func TestUnknownSubcommand(t *testing.T) {
	_ = newTestEnv(t)
	code, _, stderr := runCLI("wibble")
	if code != 2 {
		t.Fatalf("exit=%d, want 2", code)
	}
	if !strings.Contains(stderr, "unknown subcommand") {
		t.Fatalf("stderr missing diagnostic: %q", stderr)
	}
}
