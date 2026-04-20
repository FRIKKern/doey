package discord

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/doey-cli/doey/tui/internal/discord/binding"
	"github.com/doey-cli/doey/tui/internal/discord/config"
)

// setupBindEnv pins both the XDG config dir (for credentials) and the
// runtime dir (for RL state) to per-test temp directories. Returns the
// project dir.
func setupBindEnv(t *testing.T) string {
	t.Helper()
	xdg := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", xdg)
	rt := t.TempDir()
	t.Setenv("RUNTIME_DIR", rt)
	proj := t.TempDir()
	return proj
}

func TestBind_CreatesCredsBindingAndFreshState(t *testing.T) {
	proj := setupBindEnv(t)
	cfg := &config.Config{
		Kind:       config.KindWebhook,
		WebhookURL: "https://discord.com/api/webhooks/111/aaa",
		Label:      "test",
	}
	if err := Bind(proj, cfg); err != nil {
		t.Fatalf("Bind: %v", err)
	}
	// Creds file exists and is 0600.
	cp, _ := config.Path()
	info, err := os.Stat(cp)
	if err != nil {
		t.Fatalf("creds file missing: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("creds mode=%#o, want 0600", info.Mode().Perm())
	}
	// Binding pointer exists and says "default".
	bp := binding.Path(proj)
	if _, err := os.Stat(bp); err != nil {
		t.Fatalf("binding file missing: %v", err)
	}
	stanza, err := binding.Read(proj)
	if err != nil || stanza != "default" {
		t.Errorf("binding stanza=%q err=%v, want default", stanza, err)
	}
	// State file has matching cred hash and zero caches.
	st, err := Load(proj)
	if err != nil {
		t.Fatalf("Load state: %v", err)
	}
	if st.CredHash != CredHash(cfg) {
		t.Errorf("CredHash=%q, want %q", st.CredHash, CredHash(cfg))
	}
	if st.PerRoute != nil || len(st.RecentTitles) != 0 ||
		st.BreakerOpenUntil != 0 || st.ConsecutiveFailures != 0 || st.GlobalPauseUntil != 0 {
		t.Errorf("fresh state not clean: %+v", st)
	}
}

func TestBind_RebindClearsCachesAndUpdatesHash(t *testing.T) {
	proj := setupBindEnv(t)
	cfg1 := &config.Config{Kind: config.KindWebhook, WebhookURL: "https://discord.com/api/webhooks/111/aaa"}
	if err := Bind(proj, cfg1); err != nil {
		t.Fatal(err)
	}
	// Seed some dirty state post-bind.
	if err := WithFlock(proj, func(_ int) error {
		st, _ := Load(proj)
		st.PerRoute = map[string]Route{"r": {Remaining: 3, ResetUnix: 100}}
		st.BreakerOpenUntil = 9999
		st.ConsecutiveFailures = 4
		st.GlobalPauseUntil = 888
		st.RecentTitles = []CoalesceEntry{{Hash: "x", Ts: 1, Count: 1}}
		return SaveAtomic(proj, st)
	}); err != nil {
		t.Fatal(err)
	}
	// Rebind with different webhook URL.
	cfg2 := &config.Config{Kind: config.KindWebhook, WebhookURL: "https://discord.com/api/webhooks/222/bbb"}
	if err := Bind(proj, cfg2); err != nil {
		t.Fatalf("rebind: %v", err)
	}
	st, err := Load(proj)
	if err != nil {
		t.Fatal(err)
	}
	if st.CredHash != CredHash(cfg2) {
		t.Errorf("cred hash not updated")
	}
	if st.PerRoute != nil || len(st.RecentTitles) != 0 ||
		st.BreakerOpenUntil != 0 || st.ConsecutiveFailures != 0 || st.GlobalPauseUntil != 0 {
		t.Errorf("state not cleared on rebind: %+v", st)
	}
}

func TestBind_NilConfigRejected(t *testing.T) {
	proj := setupBindEnv(t)
	if err := Bind(proj, nil); err == nil {
		t.Error("expected error for nil config")
	}
}

func TestBind_BindingFailureLeavesCredsOnDisk(t *testing.T) {
	// Binding.Write needs to create <projectDir>/.doey. If projectDir is a
	// read-only path, binding.Write fails but config.Save has already
	// persisted creds. We document this behavior (no strict rollback).
	xdg := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", xdg)
	t.Setenv("RUNTIME_DIR", t.TempDir())
	// Create a read-only project root.
	projParent := t.TempDir()
	proj := filepath.Join(projParent, "readonly-proj")
	if err := os.MkdirAll(proj, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(proj, 0o700) })

	cfg := &config.Config{Kind: config.KindWebhook, WebhookURL: "https://x/y"}
	err := Bind(proj, cfg)
	if err == nil {
		// If the OS allowed the mkdir despite 0500 (e.g. running as root in CI),
		// the assertion is moot — skip.
		t.Skip("read-only dir was writable (likely running as root)")
	}
	// Creds file should still exist — documented behavior.
	cp, _ := config.Path()
	if _, statErr := os.Stat(cp); statErr != nil {
		t.Errorf("creds file missing after partial bind: %v", statErr)
	}
}

func TestCredHash_StableAndDistinct(t *testing.T) {
	a := &config.Config{Kind: config.KindWebhook, WebhookURL: "u1"}
	b := &config.Config{Kind: config.KindWebhook, WebhookURL: "u2"}
	c := &config.Config{Kind: config.KindBotDM, BotToken: "t", BotAppID: "app", DMUserID: "uid"}
	if CredHash(a) == "" {
		t.Error("CredHash empty for valid cfg")
	}
	if CredHash(a) == CredHash(b) {
		t.Error("different webhooks hashed equal")
	}
	if CredHash(a) == CredHash(c) {
		t.Error("webhook and bot_dm hashed equal")
	}
	// Stable.
	if CredHash(a) != CredHash(a) {
		t.Error("hash not stable")
	}
	// Nil safe.
	if CredHash(nil) != "" {
		t.Error("CredHash(nil) should be empty")
	}
}
