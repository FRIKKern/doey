package sender

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/doey-cli/doey/tui/internal/discord/config"
)

// hostRewriteTransport rewrites the request scheme+host so the hard-coded
// Discord base URL inside botdm.go hits our test server instead.
type hostRewriteTransport struct {
	u     *url.URL
	inner http.RoundTripper
}

func (t *hostRewriteTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r2 := r.Clone(r.Context())
	r2.URL.Scheme = t.u.Scheme
	r2.URL.Host = t.u.Host
	r2.Host = t.u.Host
	return t.inner.RoundTrip(r2)
}

func newBotDMTestClient(srv *httptest.Server, timeout time.Duration) *http.Client {
	u, _ := url.Parse(srv.URL)
	return &http.Client{
		Timeout:   timeout,
		Transport: &hostRewriteTransport{u: u, inner: http.DefaultTransport},
	}
}

func newTestBotDMSender(cfg *config.Config, client *http.Client) *botDMSender {
	if cfg == nil {
		cfg = &config.Config{Kind: config.KindBotDM, BotToken: "test-token", BotAppID: "APPID", DMUserID: "USER1"}
	}
	return newBotDMSenderWithClient(cfg, client)
}

// writeOpenDM writes a successful open-DM response with the given channel id.
func writeOpenDM(w http.ResponseWriter, channelID string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(200)
	_ = json.NewEncoder(w).Encode(map[string]string{"id": channelID})
}

// ---- Case 1: happy path + channel cache reuse ----

func TestBotDMSender_Send_HappyPath(t *testing.T) {
	var openCalls, msgCalls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/users/@me/channels"):
			atomic.AddInt32(&openCalls, 1)
			if got := r.Header.Get("Authorization"); got != "Bot test-token" {
				t.Errorf("authorization = %q, want 'Bot test-token'", got)
			}
			writeOpenDM(w, "CHAN1")
		case strings.HasSuffix(r.URL.Path, "/channels/CHAN1/messages"):
			atomic.AddInt32(&msgCalls, 1)
			b, _ := io.ReadAll(r.Body)
			var body map[string]string
			if err := json.Unmarshal(b, &body); err != nil {
				t.Errorf("unmarshal: %v", err)
			}
			if body["content"] == "" {
				t.Errorf("empty content")
			}
			w.WriteHeader(204)
		default:
			t.Errorf("unexpected path %q", r.URL.Path)
			w.WriteHeader(500)
		}
	}))
	defer srv.Close()

	s := newTestBotDMSender(nil, newBotDMTestClient(srv, 4*time.Second))
	res1 := s.Send(context.Background(), Message{Content: "hi"})
	if res1.Outcome != OutcomeSuccess {
		t.Fatalf("1st outcome = %v err=%v", res1.Outcome, res1.Err)
	}
	res2 := s.Send(context.Background(), Message{Content: "hi again"})
	if res2.Outcome != OutcomeSuccess {
		t.Fatalf("2nd outcome = %v err=%v", res2.Outcome, res2.Err)
	}
	if n := atomic.LoadInt32(&openCalls); n != 1 {
		t.Fatalf("openCalls = %d, want 1 (second send must use cache)", n)
	}
	if n := atomic.LoadInt32(&msgCalls); n != 2 {
		t.Fatalf("msgCalls = %d, want 2", n)
	}
}

// ---- Case 2: 401 on open-DM → permanent, redacted ----

func TestBotDMSender_OpenDM_401(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/users/@me/channels") {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		w.WriteHeader(401)
		_, _ = io.WriteString(w, `{"message":"Unauthorized"}`)
	}))
	defer srv.Close()

	s := newTestBotDMSender(nil, newBotDMTestClient(srv, 4*time.Second))
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomePermanentError {
		t.Fatalf("outcome = %v, want PermanentError; err=%v", res.Outcome, res.Err)
	}
	if res.StatusCode != 401 {
		t.Fatalf("status = %d", res.StatusCode)
	}
	if res.Err == nil {
		t.Fatalf("err = nil")
	}
	if strings.Contains(res.Err.Error(), "test-token") {
		t.Fatalf("err leaks token: %q", res.Err.Error())
	}
}

// ---- Case 3: 404 on send invalidates cache ----

func TestBotDMSender_Send_404InvalidatesCache(t *testing.T) {
	var openCalls int32
	var sendCallN int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/users/@me/channels"):
			n := atomic.AddInt32(&openCalls, 1)
			if n == 1 {
				writeOpenDM(w, "CHAN1")
			} else {
				writeOpenDM(w, "CHAN2")
			}
		case strings.HasSuffix(r.URL.Path, "/channels/CHAN1/messages"):
			n := atomic.AddInt32(&sendCallN, 1)
			if n == 1 {
				w.WriteHeader(204) // 1st Send succeeds
			} else {
				w.WriteHeader(404) // 2nd Send: channel now 404
			}
		case strings.HasSuffix(r.URL.Path, "/channels/CHAN2/messages"):
			w.WriteHeader(204) // 3rd Send succeeds after cache invalidation
		default:
			t.Errorf("unexpected path %q", r.URL.Path)
			w.WriteHeader(500)
		}
	}))
	defer srv.Close()

	s := newTestBotDMSender(nil, newBotDMTestClient(srv, 4*time.Second))

	r1 := s.Send(context.Background(), Message{Content: "1"})
	if r1.Outcome != OutcomeSuccess {
		t.Fatalf("r1 outcome = %v err=%v", r1.Outcome, r1.Err)
	}
	r2 := s.Send(context.Background(), Message{Content: "2"})
	if r2.StatusCode != 404 {
		t.Fatalf("r2 status = %d, want 404", r2.StatusCode)
	}
	if atomic.LoadInt32(&openCalls) != 1 {
		t.Fatalf("before 3rd send openCalls = %d, want 1", atomic.LoadInt32(&openCalls))
	}
	r3 := s.Send(context.Background(), Message{Content: "3"})
	if r3.Outcome != OutcomeSuccess {
		t.Fatalf("r3 outcome = %v err=%v", r3.Outcome, r3.Err)
	}
	if n := atomic.LoadInt32(&openCalls); n != 2 {
		t.Fatalf("final openCalls = %d, want 2 (cache should have been invalidated)", n)
	}
}

// ---- Case 4: 429 headers ----

func TestBotDMSender_Send_429_Headers(t *testing.T) {
	future := strconv.FormatInt(time.Now().Add(10*time.Second).Unix(), 10)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/users/@me/channels") {
			writeOpenDM(w, "CHAN1")
			return
		}
		w.Header().Set("X-RateLimit-Remaining", "0")
		w.Header().Set("X-RateLimit-Reset", future)
		w.Header().Set("Retry-After", "2")
		w.WriteHeader(429)
	}))
	defer srv.Close()

	s := newTestBotDMSender(nil, newBotDMTestClient(srv, 4*time.Second))
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomeRateLimited {
		t.Fatalf("outcome = %v", res.Outcome)
	}
	if res.RetryAfterSec != 2 {
		t.Fatalf("retryAfterSec = %d, want 2", res.RetryAfterSec)
	}
	if res.Remaining != 0 {
		t.Fatalf("remaining = %d, want 0", res.Remaining)
	}
	if res.Global {
		t.Fatalf("global = true, want false")
	}
}

func TestBotDMSender_Send_429_Global(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/users/@me/channels") {
			writeOpenDM(w, "CHAN1")
			return
		}
		w.Header().Set("X-RateLimit-Scope", "global")
		w.Header().Set("Retry-After", "3")
		w.WriteHeader(429)
	}))
	defer srv.Close()

	s := newTestBotDMSender(nil, newBotDMTestClient(srv, 4*time.Second))
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomeRateLimited {
		t.Fatalf("outcome = %v", res.Outcome)
	}
	if !res.Global {
		t.Fatalf("global = false, want true")
	}
}

// ---- Case 5: 403 on send → permanent ----

func TestBotDMSender_Send_403_DMsClosed(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/users/@me/channels") {
			writeOpenDM(w, "CHAN1")
			return
		}
		w.WriteHeader(403)
		_, _ = io.WriteString(w, `{"message":"Cannot send messages to this user","code":50007}`)
	}))
	defer srv.Close()

	s := newTestBotDMSender(nil, newBotDMTestClient(srv, 4*time.Second))
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomePermanentError {
		t.Fatalf("outcome = %v", res.Outcome)
	}
	if res.StatusCode != 403 {
		t.Fatalf("status = %d", res.StatusCode)
	}
}

// ---- Case 6: network error via tight timeout ----

func TestBotDMSender_Send_NetworkError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(50 * time.Millisecond)
		writeOpenDM(w, "CHAN1")
	}))
	defer srv.Close()

	s := newTestBotDMSender(nil, newBotDMTestClient(srv, 1*time.Millisecond))
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomeNetworkError {
		t.Fatalf("outcome = %v err=%v", res.Outcome, res.Err)
	}
}

// ---- Case 7: RouteKey on non-429 ----

func TestBotDMSender_RouteKey(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/users/@me/channels") {
			writeOpenDM(w, "CHAN1")
			return
		}
		w.WriteHeader(204)
	}))
	defer srv.Close()

	s := newTestBotDMSender(nil, newBotDMTestClient(srv, 4*time.Second))
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("outcome = %v err=%v", res.Outcome, res.Err)
	}
	if res.RouteKey != "POST /channels/:channel_id/messages" {
		t.Fatalf("routeKey = %q", res.RouteKey)
	}
}
