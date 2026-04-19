package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testEnv creates an isolated project dir + XDG_CONFIG_HOME so tests can
// run in parallel without touching the developer's real ~/.config.
type testEnv struct {
	Project string
	XDG     string
	Conf    string
}

func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	root := t.TempDir()
	proj := filepath.Join(root, "proj")
	xdg := filepath.Join(root, "xdg")
	if err := os.MkdirAll(filepath.Join(proj, ".doey"), 0o755); err != nil {
		t.Fatalf("mkdir proj/.doey: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(xdg, "doey"), 0o700); err != nil {
		t.Fatalf("mkdir xdg/doey: %v", err)
	}
	conf := filepath.Join(xdg, "doey", "discord.conf")
	t.Setenv("PROJECT_DIR", proj)
	t.Setenv("XDG_CONFIG_HOME", xdg)
	return &testEnv{Project: proj, XDG: xdg, Conf: conf}
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

// runCLI invokes Run and returns (code, stdout, stderr). Keeps tests
// from having to plumb io.Writers repeatedly.
func runCLI(args ...string) (int, string, string) {
	var out, errb bytes.Buffer
	code := Run(args, &out, &errb)
	return code, out.String(), errb.String()
}

// ── Send — Branch (a): no binding ────────────────────────────────────

func TestSend_NoBinding_Phase2Message(t *testing.T) {
	_ = newTestEnv(t)
	code, _, stderr := runCLI("send", "--title", "T", "--event", "stop")
	if code != 1 {
		t.Fatalf("exit=%d, want 1; stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, "send CLI lands in Phase 2") {
		t.Fatalf("stderr missing Phase 2 message: %q", stderr)
	}
	if strings.Contains(stderr, "Phase 3") {
		t.Fatalf("stderr must NOT mention Phase 3 in branch (a): %q", stderr)
	}
}

// ── Send — Branch (b): bot_dm binding ─────────────────────────────────

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
	if !strings.Contains(stderr, "bot_dm support lands in Phase 3") {
		t.Fatalf("stderr missing Phase 3 message: %q", stderr)
	}
	if strings.Contains(stderr, "lands in Phase 2") {
		t.Fatalf("stderr must NOT mention Phase 2 in branch (b): %q", stderr)
	}
}

// ── Send — Webhook creds present: still Branch (a) ───────────────────

func TestSend_Webhook_StillRefuses(t *testing.T) {
	e := newTestEnv(t)
	e.writeBinding(t, "default")
	e.writeConf(t, `[default]
kind=webhook
webhook_url=https://discord.com/api/webhooks/1/abc1
`, 0o600)
	code, _, stderr := runCLI("send", "--title", "T", "--event", "stop")
	if code != 1 {
		t.Fatalf("exit=%d, want 1; stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, "send CLI lands in Phase 2") {
		t.Fatalf("webhook branch (a) message missing: %q", stderr)
	}
}

// ── Send — bad creds (missing perms): creds-problem path ─────────────

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

// ── Status — webhook bound, exposes last-4 redaction ─────────────────

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

// ── Status --json — bot_dm kind ──────────────────────────────────────

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

// ── Status — bad perms, still exits 0 ────────────────────────────────

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

// ── Stub subcommands — exit 1 with phase tag ─────────────────────────

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

func TestStub_Failures(t *testing.T) {
	_ = newTestEnv(t)
	code, _, stderr := runCLI("failures")
	if code != 1 {
		t.Fatalf("exit=%d, want 1", code)
	}
	if !strings.Contains(stderr, "Phase 2") {
		t.Fatalf("stderr missing Phase 2 tag: %q", stderr)
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
