package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/doey-cli/doey/tui/internal/discord"
	"github.com/doey-cli/doey/tui/internal/discord/config"
	"github.com/doey-cli/doey/tui/internal/discord/sender"
)

// bindRewriteTransport rewrites outbound Discord requests to the test server.
type bindRewriteTransport struct {
	u     *url.URL
	inner http.RoundTripper
}

func (t *bindRewriteTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r2 := r.Clone(r.Context())
	r2.URL.Scheme = t.u.Scheme
	r2.URL.Host = t.u.Host
	r2.Host = t.u.Host
	return t.inner.RoundTrip(r2)
}

// swapHTTPClient points sender.HTTPClient at srv for the lifetime of t.
// Restores the original global on cleanup.
func swapHTTPClient(t *testing.T, srv *httptest.Server) {
	t.Helper()
	u, _ := url.Parse(srv.URL)
	orig := sender.HTTPClient
	sender.HTTPClient = &http.Client{
		Timeout:   4 * time.Second,
		Transport: &bindRewriteTransport{u: u, inner: http.DefaultTransport},
	}
	t.Cleanup(func() { sender.HTTPClient = orig })
}

func runBindCLI(args []string, stdin string) (int, string, string) {
	var out, errb bytes.Buffer
	code := runBind(args, strings.NewReader(stdin), &out, &errb)
	return code, out.String(), errb.String()
}

// ---- Flag handling ----

func TestRunBind_UnknownKind(t *testing.T) {
	_ = newTestEnv(t)
	code, _, stderr := runBindCLI([]string{"--kind", "foo"}, "")
	if code == 0 {
		t.Fatalf("exit = 0, want nonzero")
	}
	if !strings.Contains(stderr, "unknown") {
		t.Fatalf("stderr missing 'unknown': %q", stderr)
	}
}

func TestRunBind_MissingKind(t *testing.T) {
	_ = newTestEnv(t)
	code, _, stderr := runBindCLI([]string{}, "")
	if code == 0 {
		t.Fatalf("exit = 0, want nonzero")
	}
	if !strings.Contains(stderr, "--kind") {
		t.Fatalf("stderr missing '--kind': %q", stderr)
	}
}

// ---- Webhook bind happy path ----

func TestRunBind_Webhook_HappyPath(t *testing.T) {
	_ = newTestEnv(t)
	stdin := "https://discord.com/api/webhooks/123/abc_XYZ\n"
	code, _, stderr := runBindCLI([]string{"--kind", "webhook", "--label", "test"}, stdin)
	if code != 0 {
		t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
	}
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if cfg.Kind != config.KindWebhook {
		t.Fatalf("kind = %q", cfg.Kind)
	}
	if cfg.WebhookURL != "https://discord.com/api/webhooks/123/abc_XYZ" {
		t.Fatalf("webhook url = %q", cfg.WebhookURL)
	}
	if cfg.Label != "test" {
		t.Fatalf("label = %q", cfg.Label)
	}
}

// ---- Bot_dm token-shape failure: zero HTTP allowed ----

func TestRunBind_BotDM_TokenShapeFailure(t *testing.T) {
	_ = newTestEnv(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("HTTP should not be called for shape failure; got %s %s", r.Method, r.URL.Path)
	}))
	defer srv.Close()
	swapHTTPClient(t, srv)

	// 32-char alphanum = OAuth2 shape
	oauthShape := "abcdefghijklmnopqrstuvwxyz012345"
	stdin := "APPID\n" + oauthShape + "\n"
	code, _, stderr := runBindCLI([]string{"--kind", "bot_dm"}, stdin)
	if code == 0 {
		t.Fatalf("exit = 0, want nonzero; stderr=%q", stderr)
	}
	if !strings.Contains(stderr, "OAuth2") && !strings.Contains(stderr, "Bot Token") && !strings.Contains(stderr, "bot_token") {
		t.Fatalf("stderr missing OAuth2/bot_token remediation: %q", stderr)
	}
}

// ---- Bot_dm token invalid (401 from /users/@me) ----

func TestRunBind_BotDM_TokenInvalid_401(t *testing.T) {
	_ = newTestEnv(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/users/@me") {
			w.WriteHeader(401)
			return
		}
		t.Errorf("unexpected path: %s", r.URL.Path)
		w.WriteHeader(500)
	}))
	defer srv.Close()
	swapHTTPClient(t, srv)

	botLike := "xxx.yyy.not-a-real-token-PLACEHOLDER-FOR-TESTS"
	stdin := "APPID\n" + botLike + "\n1234567890\n"
	code, _, stderr := runBindCLI([]string{"--kind", "bot_dm"}, stdin)
	if code == 0 {
		t.Fatalf("exit = 0, want nonzero")
	}
	low := strings.ToLower(stderr)
	if !strings.Contains(low, "invalid") && !strings.Contains(low, "regenerate") {
		t.Fatalf("stderr missing 'invalid/regenerate': %q", stderr)
	}
}

// ---- Bot_dm "not a bot" ----

func TestRunBind_BotDM_NotABot(t *testing.T) {
	_ = newTestEnv(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/users/@me") {
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"id": "U1", "username": "realuser", "bot": false,
			})
			return
		}
		t.Errorf("unexpected path: %s", r.URL.Path)
	}))
	defer srv.Close()
	swapHTTPClient(t, srv)

	botLike := "xxx.yyy.not-a-real-token-PLACEHOLDER-FOR-TESTS"
	stdin := "APPID\n" + botLike + "\n1234567890\n"
	code, _, stderr := runBindCLI([]string{"--kind", "bot_dm"}, stdin)
	if code == 0 {
		t.Fatalf("exit = 0, want nonzero")
	}
	if !strings.Contains(strings.ToLower(stderr), "not a bot") {
		t.Fatalf("stderr missing 'not a bot': %q", stderr)
	}
}

// ---- Bot_dm no mutual guild ----

func TestRunBind_BotDM_NoMutualGuild(t *testing.T) {
	_ = newTestEnv(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/users/@me/guilds"):
			_, _ = io.WriteString(w, `[]`)
		case strings.HasSuffix(r.URL.Path, "/users/@me"):
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"id": "APPID", "username": "MyBot", "bot": true,
			})
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
	}))
	defer srv.Close()
	swapHTTPClient(t, srv)

	botLike := "xxx.yyy.not-a-real-token-PLACEHOLDER-FOR-TESTS"
	// Lines: appid, token, user_id, (Enter after invite URL)
	stdin := "APPID\n" + botLike + "\n1234567890\n\n"
	code, _, stderr := runBindCLI([]string{"--kind", "bot_dm"}, stdin)
	if code == 0 {
		t.Fatalf("exit = 0, want nonzero; stderr=%q", stderr)
	}
	low := strings.ToLower(stderr)
	if !strings.Contains(low, "guild") {
		t.Fatalf("stderr missing 'guild': %q", stderr)
	}
}

// ---- Bot_dm happy path — full wizard ----

func TestRunBind_BotDM_HappyPath(t *testing.T) {
	e := newTestEnv(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/users/@me/guilds"):
			_, _ = io.WriteString(w, `[{"id":"G1"}]`)
		case strings.HasSuffix(r.URL.Path, "/users/@me"):
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"id": "APPID", "username": "MyBot", "bot": true,
			})
		case strings.HasSuffix(r.URL.Path, "/guilds/G1/members/1234567890"):
			_, _ = io.WriteString(w, `{"user":{"id":"1234567890"}}`)
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
	}))
	defer srv.Close()
	swapHTTPClient(t, srv)

	botLike := "xxx.yyy.not-a-real-token-PLACEHOLDER-FOR-TESTS"
	stdin := "APPID\n" + botLike + "\n1234567890\n\n"
	code, stdout, stderr := runBindCLI([]string{"--kind", "bot_dm", "--label", "mybind"}, stdin)
	if code != 0 {
		t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
	}

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if cfg.Kind != config.KindBotDM {
		t.Fatalf("kind = %q", cfg.Kind)
	}
	if cfg.BotToken != botLike {
		t.Fatalf("bot_token on disk differs: got %q", cfg.BotToken)
	}
	if cfg.GuildID != "G1" {
		t.Fatalf("guild_id = %q, want G1", cfg.GuildID)
	}
	if cfg.DMUserID != "1234567890" {
		t.Fatalf("dm_user_id = %q", cfg.DMUserID)
	}
	if cfg.Label != "mybind" {
		t.Fatalf("label = %q", cfg.Label)
	}
	// Stdout must NOT contain the raw bot token.
	if strings.Contains(stdout, botLike) {
		t.Fatalf("stdout leaked full bot token: %q", stdout)
	}
	// Binding pointer is written.
	if _, err := os.Stat(filepath.Join(e.Project, ".doey", "discord-binding")); err != nil {
		t.Fatalf("binding file: %v", err)
	}
}

// ---- Rebind purges / changes cred hash ----

func TestRunBind_BotDM_RebindPurges(t *testing.T) {
	e := newTestEnv(t)

	mkSrv := func() *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch {
			case strings.HasSuffix(r.URL.Path, "/users/@me/guilds"):
				_, _ = io.WriteString(w, `[{"id":"G1"}]`)
			case strings.HasSuffix(r.URL.Path, "/users/@me"):
				_ = json.NewEncoder(w).Encode(map[string]interface{}{
					"id": "APPID", "username": "MyBot", "bot": true,
				})
			case strings.HasSuffix(r.URL.Path, "/guilds/G1/members/1234567890"):
				_, _ = io.WriteString(w, `{"user":{"id":"1234567890"}}`)
			default:
				t.Errorf("unexpected path: %s", r.URL.Path)
			}
		}))
	}

	tok1 := "xxx.FIRST.not-a-real-token-PLACEHOLDER-1"
	tok2 := "xxx.SECOND.not-a-real-token-PLACEHOLDER-2"

	srv1 := mkSrv()
	swapHTTPClient(t, srv1)
	stdin1 := "APPID\n" + tok1 + "\n1234567890\n\n"
	if code, _, se := runBindCLI([]string{"--kind", "bot_dm"}, stdin1); code != 0 {
		srv1.Close()
		t.Fatalf("1st bind exit=%d stderr=%q", code, se)
	}
	cfg1, err := config.Load()
	if err != nil {
		srv1.Close()
		t.Fatalf("load cfg1: %v", err)
	}
	hash1 := discord.CredHash(cfg1)
	srv1.Close()

	srv2 := mkSrv()
	defer srv2.Close()
	swapHTTPClient(t, srv2)
	stdin2 := "APPID\n" + tok2 + "\n1234567890\n\n"
	if code, _, se := runBindCLI([]string{"--kind", "bot_dm"}, stdin2); code != 0 {
		t.Fatalf("2nd bind exit=%d stderr=%q", code, se)
	}
	cfg2, err := config.Load()
	if err != nil {
		t.Fatalf("load cfg2: %v", err)
	}
	hash2 := discord.CredHash(cfg2)
	if hash1 == hash2 {
		t.Fatalf("cred hash unchanged across rebind: %s", hash1)
	}

	// After rebind, on-disk state file must reflect new cred hash and
	// zeroed per-route map (ADR-7 rebind semantics).
	st, err := discord.Load(e.Project)
	if err != nil {
		t.Fatalf("load state: %v", err)
	}
	if st.CredHash != hash2 {
		t.Fatalf("state.CredHash = %q, want %q", st.CredHash, hash2)
	}
	if len(st.PerRoute) != 0 {
		t.Fatalf("state.PerRoute = %v, want empty", st.PerRoute)
	}
}
