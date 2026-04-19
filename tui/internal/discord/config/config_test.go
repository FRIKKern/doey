package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withXDG points Path() at a freshly created config home.
func withXDG(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	return dir
}

func TestPathHonorsXDG(t *testing.T) {
	xdg := withXDG(t)
	got, err := Path()
	if err != nil {
		t.Fatalf("Path: %v", err)
	}
	want := filepath.Join(xdg, "doey", "discord.conf")
	if got != want {
		t.Fatalf("Path = %q, want %q", got, want)
	}
}

func TestSaveLoadRoundTripWebhook(t *testing.T) {
	withXDG(t)
	cfg := &Config{
		Kind:       KindWebhook,
		WebhookURL: "https://discord.com/api/webhooks/1/abc",
		Label:      "team",
		Created:    "2026-04-19T20:56:30Z",
	}
	if err := Save(cfg); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if *got != *cfg {
		t.Fatalf("round-trip mismatch:\n got: %+v\nwant: %+v", got, cfg)
	}
}

func TestSaveLoadRoundTripBotDM(t *testing.T) {
	withXDG(t)
	cfg := &Config{
		Kind:        KindBotDM,
		BotToken:    "bot.token.value",
		BotAppID:    "11111111",
		DMUserID:    "22222222",
		DMChannelID: "33333333",
		GuildID:     "44444444",
		Label:       "solo",
	}
	if err := Save(cfg); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if *got != *cfg {
		t.Fatalf("round-trip mismatch:\n got: %+v\nwant: %+v", got, cfg)
	}
}

func TestSaveEnforces0600(t *testing.T) {
	withXDG(t)
	cfg := &Config{Kind: KindWebhook, WebhookURL: "https://example.invalid/h"}
	if err := Save(cfg); err != nil {
		t.Fatalf("Save: %v", err)
	}
	p, _ := Path()
	info, err := os.Stat(p)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %#o, want 0600", info.Mode().Perm())
	}
}

func TestLoadNotFound(t *testing.T) {
	withXDG(t)
	_, err := Load()
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestLoadBadPerms(t *testing.T) {
	withXDG(t)
	p, _ := Path()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	body := "[default]\nkind=webhook\nwebhook_url=https://example.invalid/h\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Load()
	if !errors.Is(err, ErrBadPerms) {
		t.Fatalf("err = %v, want ErrBadPerms", err)
	}
}

func TestLoadUnknownStanza(t *testing.T) {
	withXDG(t)
	p, _ := Path()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	body := "[production]\nkind=webhook\nwebhook_url=https://example.invalid/h\n"
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := Load()
	if !errors.Is(err, ErrUnknownStanza) {
		t.Fatalf("err = %v, want ErrUnknownStanza", err)
	}
}

func TestLoadParseErrorMalformed(t *testing.T) {
	withXDG(t)
	p, _ := Path()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	body := "[default\nkind=webhook\n"
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := Load()
	if !errors.Is(err, ErrParseError) {
		t.Fatalf("err = %v, want ErrParseError", err)
	}
}

func TestLoadParseErrorUnknownKey(t *testing.T) {
	withXDG(t)
	p, _ := Path()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	body := "[default]\nkind=webhook\nwebhook_url=https://example.invalid/h\nmystery=1\n"
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := Load()
	if !errors.Is(err, ErrParseError) {
		t.Fatalf("err = %v, want ErrParseError", err)
	}
}

func TestLoadParseErrorUnknownKind(t *testing.T) {
	withXDG(t)
	p, _ := Path()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	body := "[default]\nkind=carrier_pigeon\n"
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := Load()
	if !errors.Is(err, ErrParseError) {
		t.Fatalf("err = %v, want ErrParseError", err)
	}
}

func TestSaveRejectsInvalidKind(t *testing.T) {
	withXDG(t)
	err := Save(&Config{Kind: "pigeon"})
	if !errors.Is(err, ErrParseError) {
		t.Fatalf("err = %v, want ErrParseError", err)
	}
}

func TestSaveAtomicLeavesNoTmp(t *testing.T) {
	withXDG(t)
	cfg := &Config{Kind: KindWebhook, WebhookURL: "https://example.invalid/h"}
	if err := Save(cfg); err != nil {
		t.Fatal(err)
	}
	p, _ := Path()
	dir := filepath.Dir(p)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".discord.conf") && strings.HasSuffix(name, ".tmp") {
			t.Fatalf("leftover tempfile after Save: %s", name)
		}
	}
}

func TestSaveOverwritePreservesMode(t *testing.T) {
	withXDG(t)
	first := &Config{Kind: KindWebhook, WebhookURL: "https://example.invalid/1"}
	if err := Save(first); err != nil {
		t.Fatal(err)
	}
	second := &Config{Kind: KindWebhook, WebhookURL: "https://example.invalid/2", Label: "new"}
	if err := Save(second); err != nil {
		t.Fatal(err)
	}
	p, _ := Path()
	info, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %#o, want 0600", info.Mode().Perm())
	}
	got, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.WebhookURL != second.WebhookURL || got.Label != "new" {
		t.Fatalf("overwrite mismatch: %+v", got)
	}
}

func TestParseIgnoresCommentsAndBlanks(t *testing.T) {
	body := strings.NewReader(`
# leading comment
; also a comment

[default]
# inside comment
kind=webhook
webhook_url=https://example.invalid/h  # trailing comment
label=team
`)
	cfg, err := parse(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if cfg.Kind != KindWebhook {
		t.Fatalf("kind = %q", cfg.Kind)
	}
	if cfg.WebhookURL != "https://example.invalid/h" {
		t.Fatalf("webhook_url = %q", cfg.WebhookURL)
	}
	if cfg.Label != "team" {
		t.Fatalf("label = %q", cfg.Label)
	}
}
