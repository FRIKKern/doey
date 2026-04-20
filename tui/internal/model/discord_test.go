package model

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/doey-cli/doey/tui/internal/discord"
	"github.com/doey-cli/doey/tui/internal/discord/config"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// TestMain lives in violations_test.go; zone.NewGlobal() runs once for the
// whole package so this file does not need its own TestMain.

// runeKey is a convenience constructor for a tea.KeyMsg that carries a single
// printable rune. textinput.Model.Update accepts KeyRunes and folds the rune
// into the input buffer; DiscordModel.handleKey uses tea.KeyMsg.String() so
// the same encoding doubles as a single-character hotkey press.
func runeKey(r rune) tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}}
}

func typeString(t *testing.T, update func(tea.Msg), s string) {
	t.Helper()
	for _, r := range s {
		update(runeKey(r))
	}
}

// ---------------------------------------------------------------------------
// 1. Webhook bind wizard — state machine
// ---------------------------------------------------------------------------

func TestDiscordModel_WizardStateMachine_Webhook(t *testing.T) {
	w := newWebhookBindModel(styles.DefaultTheme())
	w.SetSize(100)

	// Drive textinput messages through the wizard's Update until the URL
	// field contains a matching value.
	url := "https://discord.com/api/webhooks/123456789012345678/abcDEF_ghij-KLmnOP"
	typeString(t, func(m tea.Msg) {
		var cmd tea.Cmd
		w, cmd = w.Update(m)
		_ = cmd
	}, url)
	if got := w.WebhookURL(); got != url {
		t.Fatalf("URL field not captured: got %q want %q", got, url)
	}
	if w.cursor != whFieldURL {
		t.Fatalf("cursor advanced before Tab: got %d", w.cursor)
	}

	// Tab → move to label field. Validation must accept the URL.
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyTab})
	if w.errMsg != "" {
		t.Fatalf("unexpected validation error after Tab: %q", w.errMsg)
	}
	if w.cursor != whFieldLabel {
		t.Fatalf("cursor not at label field: got %d", w.cursor)
	}

	typeString(t, func(m tea.Msg) {
		var cmd tea.Cmd
		w, cmd = w.Update(m)
		_ = cmd
	}, "mylabel")
	if got := w.Label(); got != "mylabel" {
		t.Fatalf("Label field not captured: got %q", got)
	}

	// Tab → move to save-confirm field.
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyTab})
	if w.cursor != whFieldSave {
		t.Fatalf("cursor not at save field: got %d", w.cursor)
	}

	// Answer "y" then press Enter to submit.
	w, _ = w.Update(runeKey('y'))
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if !w.Done() {
		t.Fatalf("wizard not done after Enter on final field")
	}
	if !w.Submitted() {
		t.Fatalf("wizard should be submitted when user answered 'y'")
	}
	if !w.Save() {
		t.Fatalf("Save() should report true for 'y' answer")
	}
}

// Verify that Enter on an invalid URL keeps the wizard open with an error.
func TestDiscordModel_WizardStateMachine_Webhook_ValidationBlocks(t *testing.T) {
	w := newWebhookBindModel(styles.DefaultTheme())
	w.SetSize(100)

	typeString(t, func(m tea.Msg) {
		var cmd tea.Cmd
		w, cmd = w.Update(m)
		_ = cmd
	}, "not-a-url")
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyTab})
	if w.errMsg == "" {
		t.Fatalf("expected validation error on bad URL")
	}
	if w.cursor != whFieldURL {
		t.Fatalf("cursor should stay on URL field after validation failure")
	}
	if w.Done() {
		t.Fatalf("wizard should not be done after validation failure")
	}
}

// ---------------------------------------------------------------------------
// 2. Bot-DM bind wizard — state machine
// ---------------------------------------------------------------------------

func TestDiscordModel_WizardStateMachine_BotDM(t *testing.T) {
	w := newBotDMBindModel(styles.DefaultTheme())
	w.SetSize(100)

	drive := func(m tea.Msg) {
		var cmd tea.Cmd
		w, cmd = w.Update(m)
		_ = cmd
	}

	// bot token (anything that doesn't start with "mfa.")
	typeString(t, drive, "botxyz.ABCDEF.GhIjKlMn12345")
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyTab})
	if w.errMsg != "" {
		t.Fatalf("token validation failed: %q", w.errMsg)
	}
	if w.cursor != bdFieldAppID {
		t.Fatalf("cursor not at appID: got %d", w.cursor)
	}

	typeString(t, drive, "123456789012345678")
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyTab})
	if w.errMsg != "" || w.cursor != bdFieldUserID {
		t.Fatalf("advance from appID failed: err=%q cursor=%d", w.errMsg, w.cursor)
	}

	typeString(t, drive, "987654321098765432")
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyTab})
	if w.errMsg != "" || w.cursor != bdFieldLabel {
		t.Fatalf("advance from userID failed: err=%q cursor=%d", w.errMsg, w.cursor)
	}

	typeString(t, drive, "bot-label")
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyTab})
	if w.cursor != bdFieldGuildID {
		t.Fatalf("advance from label failed: cursor=%d", w.cursor)
	}

	// Leave guild blank (validator allows empty → auto-select).
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyTab})
	if w.cursor != bdFieldSave {
		t.Fatalf("advance from guildID failed: cursor=%d", w.cursor)
	}

	w, _ = w.Update(runeKey('y'))
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if !w.Done() {
		t.Fatalf("bot_dm wizard did not complete")
	}
	if !w.Submitted() {
		t.Fatalf("bot_dm wizard not marked submitted")
	}
	if w.BotAppID() != "123456789012345678" {
		t.Fatalf("bot_dm appID not captured: %q", w.BotAppID())
	}
	if w.DMUserID() != "987654321098765432" {
		t.Fatalf("bot_dm userID not captured: %q", w.DMUserID())
	}
	if w.Label() != "bot-label" {
		t.Fatalf("bot_dm label not captured: %q", w.Label())
	}
}

func TestDiscordModel_WizardStateMachine_BotDM_RejectsMFAToken(t *testing.T) {
	w := newBotDMBindModel(styles.DefaultTheme())
	w.SetSize(100)

	drive := func(m tea.Msg) {
		var cmd tea.Cmd
		w, cmd = w.Update(m)
		_ = cmd
	}
	typeString(t, drive, "mfa.looksLikeUserToken")
	w, _ = w.Update(tea.KeyMsg{Type: tea.KeyTab})
	if w.errMsg == "" {
		t.Fatalf("expected validation error on mfa.* token")
	}
	if w.cursor != bdFieldToken {
		t.Fatalf("cursor should stay on token field after mfa.* rejection")
	}
}

// ---------------------------------------------------------------------------
// 3. Activity dot — emitted when new failure appears
// ---------------------------------------------------------------------------

func TestDiscordModel_ActivityDot_OnFailureIncrease(t *testing.T) {
	m := NewDiscordModel(styles.DefaultTheme())

	// Seed baseline: no prior failures observed.
	m.prevFailureCount = 0
	m.prevBreakerOpen = false
	m.rl = &discord.RLState{}
	m.failures = []discord.FailureEntry{
		{ID: "a", Kind: "webhook", Title: "t1", Error: "oops"},
	}

	cmd := m.detectActivity()
	if cmd == nil {
		t.Fatalf("expected a DiscordActivityMsg Cmd when failure count grew")
	}
	msg := cmd()
	if _, ok := msg.(DiscordActivityMsg); !ok {
		t.Fatalf("expected DiscordActivityMsg, got %T", msg)
	}

	// Second call with unchanged count → no activity.
	cmd2 := m.detectActivity()
	if cmd2 != nil {
		if _, ok := cmd2().(DiscordActivityMsg); ok {
			t.Fatalf("expected no DiscordActivityMsg when failure count is stable")
		}
	}
}

// ---------------------------------------------------------------------------
// 4. Activity dot — emitted when breaker transitions to open
// ---------------------------------------------------------------------------

func TestDiscordModel_ActivityDot_OnBreakerOpen(t *testing.T) {
	m := NewDiscordModel(styles.DefaultTheme())
	m.prevBreakerOpen = false
	m.prevFailureCount = 0
	m.rl = &discord.RLState{
		BreakerOpenUntil: time.Now().Add(2 * time.Minute).Unix(),
	}

	cmd := m.detectActivity()
	if cmd == nil {
		t.Fatalf("expected a DiscordActivityMsg Cmd when breaker flips open")
	}
	msg := cmd()
	if _, ok := msg.(DiscordActivityMsg); !ok {
		t.Fatalf("expected DiscordActivityMsg, got %T", msg)
	}

	// Still open — no transition, no new activity.
	if cmd2 := m.detectActivity(); cmd2 != nil {
		if _, ok := cmd2().(DiscordActivityMsg); ok {
			t.Fatalf("expected no activity while breaker stays open")
		}
	}
}

// ---------------------------------------------------------------------------
// 5. Redaction in View() — webhook + bot_dm paths
// ---------------------------------------------------------------------------

func TestDiscordModel_RedactionInView(t *testing.T) {
	webhookSecret := "SECRETSECRETSECRETSECRET" // 24 chars; last-4 = "CRET"
	botSecret := "MTI3ODgwMjM0NTY3ODk.SECRETTOKENPART"
	botSecretTail := "PART"

	t.Run("webhook", func(t *testing.T) {
		m := NewDiscordModel(styles.DefaultTheme())
		m.SetSize(120, 40)
		m.stanza = "default"
		m.cfg = &config.Config{
			Kind:       config.KindWebhook,
			WebhookURL: "https://discord.com/api/webhooks/12345/" + webhookSecret,
			Label:      "prod",
		}
		out := m.View()
		if strings.Contains(out, webhookSecret) {
			t.Fatalf("webhook token leaked in View output:\n%s", out)
		}
		if !strings.Contains(out, "…CRET") {
			t.Fatalf("expected '…CRET' (ellipsis+last4) in View, got:\n%s", out)
		}
		if !strings.Contains(out, "discord.com") {
			t.Fatalf("expected host to remain visible, got:\n%s", out)
		}
	})

	t.Run("bot_dm", func(t *testing.T) {
		m := NewDiscordModel(styles.DefaultTheme())
		m.SetSize(120, 40)
		m.stanza = "default"
		m.cfg = &config.Config{
			Kind:     config.KindBotDM,
			BotToken: botSecret,
			BotAppID: "123456789012345678",
			DMUserID: "987654321098765432",
			Label:    "bot",
		}
		out := m.View()
		if strings.Contains(out, "SECRETTOKENPART") {
			t.Fatalf("bot token leaked in View output:\n%s", out)
		}
		if !strings.Contains(out, "…"+botSecretTail) {
			t.Fatalf("expected '…%s' (last-4 of bot token) in View, got:\n%s",
				botSecretTail, out)
		}
	})
}

// ---------------------------------------------------------------------------
// 6. Feature flag — bot_dm hidden when sender registry says it isn't wired
// ---------------------------------------------------------------------------

// stubBindWizard is a package-local fake that implements the bindWizard
// interface used by DiscordModel. It records the includeBotDM arg passed by
// startBindWizard so the feature-flag test can assert propagation.
type stubBindWizard struct{}

func (s *stubBindWizard) Init() tea.Cmd                           { return nil }
func (s *stubBindWizard) Update(tea.Msg) (bindWizard, tea.Cmd)    { return s, nil }
func (s *stubBindWizard) View() string                            { return "stub-wizard" }
func (s *stubBindWizard) SetSize(int, int)                        {}
func (s *stubBindWizard) Done() bool                              { return false }
func (s *stubBindWizard) Succeeded() bool                         { return false }
func (s *stubBindWizard) Label() string                           { return "" }

func TestDiscordModel_FeatureFlagHidesBotDM(t *testing.T) {
	origSender := senderRegistered
	origWizard := newBindWizard
	t.Cleanup(func() {
		senderRegistered = origSender
		newBindWizard = origWizard
	})

	var captured bool
	var called bool
	newBindWizard = func(theme styles.Theme, projectDir string, includeBotDM bool) bindWizard {
		captured = includeBotDM
		called = true
		return &stubBindWizard{}
	}

	cases := []struct {
		name       string
		registered func(string) bool
		wantInclude bool
	}{
		{
			name: "bot_dm_not_registered",
			registered: func(kind string) bool {
				return kind == "webhook"
			},
			wantInclude: false,
		},
		{
			name: "bot_dm_registered",
			registered: func(kind string) bool {
				return kind == "webhook" || kind == "bot_dm"
			},
			wantInclude: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			called = false
			captured = false
			senderRegistered = tc.registered
			m := NewDiscordModel(styles.DefaultTheme())
			m.SetSize(100, 40)
			m.SetFocused(true)
			_, _ = m.Update(runeKey('b'))
			if !called {
				t.Fatalf("newBindWizard was not invoked after pressing 'b'")
			}
			if captured != tc.wantInclude {
				t.Fatalf("includeBotDM: got %v want %v", captured, tc.wantInclude)
			}
			if m.wizard == nil {
				t.Fatalf("expected m.wizard to be set after 'b'")
			}
		})
	}
}

// ---------------------------------------------------------------------------
// 7. Retry — pressing R surfaces the "may duplicate" warning
// ---------------------------------------------------------------------------

func TestDiscordModel_RetryWarning(t *testing.T) {
	orig := runDoeyTui
	t.Cleanup(func() { runDoeyTui = orig })
	runDoeyTui = func(args ...string) ([]byte, error) {
		return []byte("ok"), nil
	}

	m := NewDiscordModel(styles.DefaultTheme())
	m.SetSize(120, 40)
	m.SetFocused(true)
	m.failures = []discord.FailureEntry{
		{
			ID:    "fail-1",
			Ts:    "2026-04-20T00:00:00Z",
			Kind:  "webhook",
			Title: "boom",
			Error: "503 upstream",
		},
	}

	_, _ = m.Update(runeKey('R'))
	if m.confirmAction != "retry" {
		t.Fatalf("pressing R should set confirmAction=retry, got %q", m.confirmAction)
	}

	out := m.View()
	if !strings.Contains(strings.ToLower(out), "may duplicate") {
		t.Fatalf("expected 'may duplicate' warning in View, got:\n%s", out)
	}

	// Confirming the prompt dispatches the retry command through our stub.
	_, cmd := m.Update(runeKey('y'))
	if m.confirmAction != "" {
		t.Fatalf("confirmAction should clear after 'y': got %q", m.confirmAction)
	}
	if cmd == nil {
		t.Fatalf("expected a retry Cmd after confirming")
	}
	// Resolve the Cmd; it should produce a discordRetryResultMsg that the
	// next Update turn folds into feedback.
	msg := cmd()
	if _, ok := msg.(discordRetryResultMsg); !ok {
		t.Fatalf("expected discordRetryResultMsg from retry Cmd, got %T", msg)
	}
	_, _ = m.Update(msg)
	if !strings.Contains(m.feedback, "may duplicate") {
		t.Fatalf("feedback should mention 'may duplicate': %q", m.feedback)
	}
}

func TestDiscordModel_RetryBlockedWhenNoFailures(t *testing.T) {
	m := NewDiscordModel(styles.DefaultTheme())
	m.SetSize(100, 30)
	m.SetFocused(true)
	m.failures = nil

	_, _ = m.Update(runeKey('R'))
	if m.confirmAction != "" {
		t.Fatalf("R with no failures must not open a retry confirm")
	}
	if !strings.Contains(m.feedback, "no failure") {
		t.Fatalf("expected 'no failure' feedback, got %q", m.feedback)
	}
}
