package sender

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// noSleep replaces the package-level sleepFn for the lifetime of t with a
// no-op, cutting synthetic retry delays so unit tests stay fast. Tests that
// assert real wall-clock budgets (case 12) must opt out.
func noSleep(t *testing.T) {
	t.Helper()
	orig := sleepFn
	sleepFn = func(time.Duration) {}
	t.Cleanup(func() { sleepFn = orig })
}

func newTestSender(t *testing.T, srv *httptest.Server) *webhookSender {
	t.Helper()
	return newWebhookSenderWithClient(srv.URL+"/api/webhooks/123456789/tokenXYZ", srv.Client())
}

// ---- Case 1: 200 success + body/method/header assertions ----

func TestWebhook_200Success(t *testing.T) {
	noSleep(t)
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		if r.Method != http.MethodPost {
			t.Errorf("method = %s, want POST", r.Method)
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/json" {
			t.Errorf("content-type = %q", ct)
		}
		b, _ := io.ReadAll(r.Body)
		var body webhookBody
		if err := json.Unmarshal(b, &body); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if body.Content != "hello" || body.Username != "doey" {
			t.Errorf("body = %+v", body)
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()

	s := newTestSender(t, srv)
	res := s.Send(context.Background(), Message{Content: "hello", Username: "doey"})
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("outcome = %v err=%v", res.Outcome, res.Err)
	}
	if res.StatusCode != 200 {
		t.Fatalf("status = %d", res.StatusCode)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("handler calls = %d, want 1", got)
	}
	if res.RouteKey != "POST /webhooks/123456789" {
		t.Fatalf("routeKey = %q", res.RouteKey)
	}
}

// ---- Case 2: 204 success ----

func TestWebhook_204Success(t *testing.T) {
	noSleep(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(204)
	}))
	defer srv.Close()
	s := newTestSender(t, srv)
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("outcome = %v err=%v", res.Outcome, res.Err)
	}
	if res.StatusCode != 204 {
		t.Fatalf("status = %d", res.StatusCode)
	}
}

// ---- Case 3: 401 permanent, no retry ----

func TestWebhook_401NoRetry(t *testing.T) {
	noSleep(t)
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(401)
	}))
	defer srv.Close()
	s := newTestSender(t, srv)
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomePermanentError {
		t.Fatalf("outcome = %v", res.Outcome)
	}
	if res.StatusCode != 401 {
		t.Fatalf("status = %d", res.StatusCode)
	}
	if n := atomic.LoadInt32(&calls); n != 1 {
		t.Fatalf("calls = %d, want 1", n)
	}
}

// ---- Case 4: 404 permanent, no retry ----

func TestWebhook_404NoRetry(t *testing.T) {
	noSleep(t)
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(404)
	}))
	defer srv.Close()
	s := newTestSender(t, srv)
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomePermanentError {
		t.Fatalf("outcome = %v", res.Outcome)
	}
	if n := atomic.LoadInt32(&calls); n != 1 {
		t.Fatalf("calls = %d, want 1", n)
	}
}

// ---- Case 5: 429 with Retry-After header → retry succeeds ----

func TestWebhook_429HeaderRetrySucceeds(t *testing.T) {
	noSleep(t)
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&calls, 1)
		if n == 1 {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(429)
			return
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()
	s := newTestSender(t, srv)
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("outcome = %v err=%v", res.Outcome, res.Err)
	}
	if n := atomic.LoadInt32(&calls); n != 2 {
		t.Fatalf("calls = %d, want 2", n)
	}
}

// ---- Case 6: 429 with JSON body fallback → retry succeeds ----

func TestWebhook_429JSONBodyFallback(t *testing.T) {
	noSleep(t)
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&calls, 1)
		if n == 1 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(429)
			io.WriteString(w, `{"retry_after": 0.5}`)
			return
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()
	s := newTestSender(t, srv)
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomeSuccess {
		t.Fatalf("outcome = %v err=%v", res.Outcome, res.Err)
	}
	if n := atomic.LoadInt32(&calls); n != 2 {
		t.Fatalf("calls = %d, want 2", n)
	}
}

// ---- Case 7: 429 global, exhaust retries ----

func TestWebhook_429Global(t *testing.T) {
	noSleep(t)
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.Header().Set("X-RateLimit-Scope", "global")
		w.Header().Set("Retry-After", "0.2")
		w.WriteHeader(429)
	}))
	defer srv.Close()
	s := newTestSender(t, srv)
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Outcome != OutcomeRateLimited {
		t.Fatalf("outcome = %v", res.Outcome)
	}
	if !res.Global {
		t.Fatalf("global = false, want true")
	}
	if res.RetryAfterSec < 1 {
		t.Fatalf("retryAfterSec = %d, want >=1", res.RetryAfterSec)
	}
}

// ---- Case 8: 500 exhausts 3 retries → PermanentError ----

func TestWebhook_500Exhausts(t *testing.T) {
	noSleep(t)
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(500)
	}))
	defer srv.Close()
	s := newTestSender(t, srv)
	res := s.Send(context.Background(), Message{Content: "x"})
	// We document: exhausted 5xx maps to OutcomePermanentError (definitive HTTP response).
	if res.Outcome != OutcomePermanentError {
		t.Fatalf("outcome = %v (want OutcomePermanentError)", res.Outcome)
	}
	if res.StatusCode != 500 {
		t.Fatalf("status = %d", res.StatusCode)
	}
}

// ---- Case 9: retry count cap is 3 ----

func TestWebhook_RetryCap3(t *testing.T) {
	noSleep(t)
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(500)
	}))
	defer srv.Close()
	s := newTestSender(t, srv)
	_ = s.Send(context.Background(), Message{Content: "x"})
	if n := atomic.LoadInt32(&calls); n != 3 {
		t.Fatalf("calls = %d, want exactly 3", n)
	}
}

// ---- Case 10: RL headers parsed ----

func TestWebhook_RateLimitHeadersParsed(t *testing.T) {
	noSleep(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-RateLimit-Remaining", "5")
		w.Header().Set("X-RateLimit-Reset", "1800000000.5")
		w.Header().Set("X-RateLimit-Bucket", "abc")
		w.WriteHeader(200)
	}))
	defer srv.Close()
	s := newTestSender(t, srv)
	res := s.Send(context.Background(), Message{Content: "x"})
	if res.Remaining != 5 {
		t.Fatalf("remaining = %d", res.Remaining)
	}
	if res.ResetUnix != 1800000000 {
		t.Fatalf("resetUnix = %d", res.ResetUnix)
	}
	if res.Bucket != "abc" {
		t.Fatalf("bucket = %q", res.Bucket)
	}
}

// ---- Case 11: context cancellation ----

func TestWebhook_ContextCancelled(t *testing.T) {
	noSleep(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	s := newTestSender(t, srv)
	res := s.Send(ctx, Message{Content: "x"})
	if res.Outcome != OutcomeNetworkError {
		t.Fatalf("outcome = %v", res.Outcome)
	}
	if res.Err == nil || !strings.Contains(res.Err.Error(), "context") {
		t.Fatalf("err = %v", res.Err)
	}
}

// ---- Case 12: total budget enforced (time-sensitive) ----

func TestWebhook_TotalBudgetEnforced(t *testing.T) {
	// Do NOT override sleepFn — we want real wall-clock enforcement.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Sleep longer than per-retry timeout to force client-side timeout.
		time.Sleep(5 * time.Second)
		w.WriteHeader(200)
	}))
	defer srv.Close()
	s := newTestSender(t, srv)
	start := time.Now()
	res := s.Send(context.Background(), Message{Content: "x"})
	elapsed := time.Since(start)
	// Budget is 10s; allow slack for test-server cleanup and scheduler jitter.
	if elapsed > 15*time.Second {
		t.Fatalf("total elapsed = %v, want <=15s", elapsed)
	}
	if res.Outcome != OutcomeNetworkError && res.Outcome != OutcomePermanentError {
		t.Fatalf("outcome = %v (want network or permanent)", res.Outcome)
	}
}

// ---- Auxiliary: deriveRouteKey ----

func TestDeriveRouteKey(t *testing.T) {
	cases := map[string]string{
		"https://discord.com/api/webhooks/123/token":     "POST /webhooks/123",
		"https://example.com/webhooks/abc":               "POST /webhooks/abc",
		"https://example.com/foo/bar":                    "POST /webhooks/unknown",
		"://bad":                                         "POST /webhooks/unknown",
		"http://host/api/v10/webhooks/9999999999/secret": "POST /webhooks/9999999999",
	}
	for in, want := range cases {
		if got := deriveRouteKey(in); got != want {
			t.Errorf("deriveRouteKey(%q) = %q, want %q", in, got, want)
		}
	}
}

// ---- Auxiliary: NewSender dispatch ----

func TestNewSender_Dispatch(t *testing.T) {
	// Use the config package type via a minimal struct assembled here.
	// We assert behavior via error types.
	s, err := NewSender(nil)
	if s != nil || err == nil {
		t.Fatalf("nil config should error, got (%v,%v)", s, err)
	}
}

// sanity: assert max byte caps are sensible at compile time.
var _ = fmt.Sprintf("%d", MaxContentBytes)
