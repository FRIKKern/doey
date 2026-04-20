package discord

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// verifyRewriteTransport intercepts requests to discord.com and routes them
// to the httptest server, preserving path and method.
type verifyRewriteTransport struct {
	u     *url.URL
	inner http.RoundTripper
}

func (t *verifyRewriteTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r2 := r.Clone(r.Context())
	r2.URL.Scheme = t.u.Scheme
	r2.URL.Host = t.u.Host
	r2.Host = t.u.Host
	return t.inner.RoundTrip(r2)
}

func newVerifyTestClient(srv *httptest.Server) *http.Client {
	u, _ := url.Parse(srv.URL)
	return &http.Client{
		Timeout:   4 * time.Second,
		Transport: &verifyRewriteTransport{u: u, inner: http.DefaultTransport},
	}
}

// ---- TokenShapePrecheck ----

func TestTokenShapePrecheck_Empty(t *testing.T) {
	if err := TokenShapePrecheck(""); !errors.Is(err, ErrTokenShapeEmpty) {
		t.Fatalf("err = %v, want ErrTokenShapeEmpty", err)
	}
}

func TestTokenShapePrecheck_UserTokenLike(t *testing.T) {
	// MFA-prefixed user token — the only shape we can reliably identify.
	tok := "mfa." + strings.Repeat("a", 60)
	if err := TokenShapePrecheck(tok); !errors.Is(err, ErrTokenShapeUserToken) {
		t.Fatalf("err = %v, want ErrTokenShapeUserToken (len=%d)", err, len(tok))
	}
}

func TestTokenShapePrecheck_OAuthSecretLike(t *testing.T) {
	tok := "abcdefghijklmnopqrstuvwxyz012345" // 32 alphanum
	if len(tok) != 32 {
		t.Fatalf("setup: len=%d", len(tok))
	}
	if err := TokenShapePrecheck(tok); !errors.Is(err, ErrTokenShapeOAuthSecret) {
		t.Fatalf("err = %v, want ErrTokenShapeOAuthSecret", err)
	}
}

func TestTokenShapePrecheck_BotTokenShape(t *testing.T) {
	// 3-segment bot-shaped token, not mfa-prefixed, not 32-char alphanum.
	tok := "xxx.yyy.not-a-real-token-PLACEHOLDER-FOR-TESTS"
	if err := TokenShapePrecheck(tok); err != nil {
		t.Fatalf("err = %v, want nil (len=%d)", err, len(tok))
	}
}

// ---- BuildInviteURL ----

func TestBuildInviteURL(t *testing.T) {
	got := BuildInviteURL("1234")
	want := "https://discord.com/api/oauth2/authorize?client_id=1234&scope=bot&permissions=0"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// ---- VerifyBotToken ----

func TestVerifyBotToken_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/users/@me") {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		if auth := r.Header.Get("Authorization"); auth != "Bot valid-token" {
			t.Errorf("authorization = %q", auth)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"id": "APPID", "username": "MyBot", "bot": true,
		})
	}))
	defer srv.Close()

	appID, username, err := VerifyBotToken(context.Background(), newVerifyTestClient(srv), "valid-token")
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if appID != "APPID" || username != "MyBot" {
		t.Fatalf("appID=%q username=%q", appID, username)
	}
}

func TestVerifyBotToken_401(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
	}))
	defer srv.Close()

	_, _, err := VerifyBotToken(context.Background(), newVerifyTestClient(srv), "x")
	if !errors.Is(err, ErrTokenInvalid) {
		t.Fatalf("err = %v, want ErrTokenInvalid", err)
	}
}

func TestVerifyBotToken_403(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
	}))
	defer srv.Close()

	_, _, err := VerifyBotToken(context.Background(), newVerifyTestClient(srv), "x")
	if !errors.Is(err, ErrTokenBannedBot) {
		t.Fatalf("err = %v, want ErrTokenBannedBot", err)
	}
}

func TestVerifyBotToken_BotFalse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"id": "U1", "username": "realuser", "bot": false,
		})
	}))
	defer srv.Close()

	_, _, err := VerifyBotToken(context.Background(), newVerifyTestClient(srv), "x")
	if !errors.Is(err, ErrTokenNotABot) {
		t.Fatalf("err = %v, want ErrTokenNotABot", err)
	}
}

// ---- VerifyMutualGuild ----

func TestVerifyMutualGuild_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/users/@me/guilds"):
			_, _ = w.Write([]byte(`[{"id":"G1"}]`))
		case strings.HasSuffix(r.URL.Path, "/guilds/G1/members/USER1"):
			_, _ = w.Write([]byte(`{"user":{"id":"USER1"}}`))
		default:
			t.Errorf("unexpected path %q", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()

	gid, err := VerifyMutualGuild(context.Background(), newVerifyTestClient(srv), "bot-token", "USER1")
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if gid != "G1" {
		t.Fatalf("gid = %q, want G1", gid)
	}
}

func TestVerifyMutualGuild_NoGuilds(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/users/@me/guilds") {
			_, _ = w.Write([]byte(`[]`))
			return
		}
		t.Errorf("unexpected path %q", r.URL.Path)
	}))
	defer srv.Close()

	_, err := VerifyMutualGuild(context.Background(), newVerifyTestClient(srv), "bot-token", "USER1")
	if !errors.Is(err, ErrNoMutualGuild) {
		t.Fatalf("err = %v, want ErrNoMutualGuild", err)
	}
}

func TestVerifyMutualGuild_UserNotInBotGuilds(t *testing.T) {
	var guildsCall int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/users/@me/guilds") {
			n := atomic.AddInt32(&guildsCall, 1)
			if n == 1 {
				_, _ = w.Write([]byte(`[{"id":"G1"},{"id":"G2"},{"id":"G3"}]`))
				return
			}
			_, _ = w.Write([]byte(`[]`))
			return
		}
		// All member checks 404
		w.WriteHeader(404)
	}))
	defer srv.Close()

	_, err := VerifyMutualGuild(context.Background(), newVerifyTestClient(srv), "bot-token", "USER1")
	if !errors.Is(err, ErrUserNotInBotGuilds) {
		t.Fatalf("err = %v, want ErrUserNotInBotGuilds", err)
	}
}

func TestVerifyMutualGuild_Pagination(t *testing.T) {
	// Target guild is on page 3. Pages 1 and 2 each return 3 guilds with
	// no member match. Page 3 returns 2 guilds; user is a member of the
	// first one on page 3.
	var pagesServed int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/users/@me/guilds") {
			atomic.AddInt32(&pagesServed, 1)
			before := r.URL.Query().Get("before")
			switch before {
			case "":
				_, _ = w.Write([]byte(`[{"id":"G1"},{"id":"G2"},{"id":"G3"}]`))
			case "G3":
				_, _ = w.Write([]byte(`[{"id":"G4"},{"id":"G5"},{"id":"G6"}]`))
			case "G6":
				_, _ = w.Write([]byte(`[{"id":"G7"},{"id":"G8"}]`))
			case "G8":
				_, _ = w.Write([]byte(`[]`))
			default:
				t.Errorf("unexpected before cursor: %q", before)
				_, _ = w.Write([]byte(`[]`))
			}
			return
		}
		if strings.HasSuffix(r.URL.Path, "/guilds/G7/members/USER1") {
			_, _ = w.Write([]byte(`{"user":{"id":"USER1"}}`))
			return
		}
		// Everyone else 404
		w.WriteHeader(404)
	}))
	defer srv.Close()

	gid, err := VerifyMutualGuild(context.Background(), newVerifyTestClient(srv), "bot-token", "USER1")
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if gid != "G7" {
		t.Fatalf("gid = %q, want G7", gid)
	}
	if n := atomic.LoadInt32(&pagesServed); n < 3 {
		t.Fatalf("pages served = %d, want >=3 (pagination not exercised)", n)
	}
}

func TestVerifyMutualGuild_403OnMember_SkipsGuild(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/users/@me/guilds") {
			_, _ = w.Write([]byte(`[{"id":"G1"},{"id":"G2"}]`))
			return
		}
		if strings.HasSuffix(r.URL.Path, "/guilds/G1/members/USER1") {
			w.WriteHeader(403)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/guilds/G2/members/USER1") {
			_, _ = w.Write([]byte(`{"user":{"id":"USER1"}}`))
			return
		}
		t.Errorf("unexpected path %q", r.URL.Path)
		w.WriteHeader(500)
	}))
	defer srv.Close()

	gid, err := VerifyMutualGuild(context.Background(), newVerifyTestClient(srv), "bot-token", "USER1")
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if gid != "G2" {
		t.Fatalf("gid = %q, want G2", gid)
	}
}

