package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/doey-cli/doey/tui/internal/discord"
)

// withStdin swaps the package-level stdinSource to deliver b, restoring
// on cleanup. Each subtest must call this BEFORE invoking runSend so the
// body arrives via the stdin path (never argv).
func withStdin(t *testing.T, body string) {
	t.Helper()
	prev := stdinSource
	stdinSource = func() (io.Reader, bool) {
		return strings.NewReader(body), true
	}
	t.Cleanup(func() { stdinSource = prev })
}

// writeWebhookCreds writes a webhook conf pointing at url. Returns the
// binding stanza written as well (always "default").
func writeWebhookCreds(t *testing.T, e *testEnv, url string) {
	t.Helper()
	e.writeBinding(t, "default")
	e.writeConf(t, "[default]\nkind=webhook\nwebhook_url="+url+"\n", 0o600)
}

func callSend(args ...string) (int, string, string) {
	var out, errb bytes.Buffer
	code := runSend(args, &out, &errb)
	return code, out.String(), errb.String()
}

// countHits returns a handler that counts requests + delegates to inner.
func countHits(counter *int32, inner http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(counter, 1)
		inner(w, r)
	}
}

// ── 1. 200 happy path ─────────────────────────────────────────────────

func TestSend_200Happy(t *testing.T) {
	e := newTestEnv(t)
	var hits int32
	srv := httptest.NewServer(countHits(&hits, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)
	withStdin(t, "hello")

	code, _, stderr := callSend("--title", "X", "--event", "stop")
	if code != 0 {
		t.Fatalf("exit=%d, want 0; stderr=%q", code, stderr)
	}
	if atomic.LoadInt32(&hits) != 1 {
		t.Fatalf("hits=%d, want 1", hits)
	}
	if _, err := os.Stat(discord.StatePath(e.Project)); err != nil {
		t.Fatalf("state file missing: %v", err)
	}
	n, _ := discord.CountFailures(e.Project)
	if n != 0 {
		t.Fatalf("failed log should be empty; got %d lines", n)
	}
}

// ── 2. 404 permanent ──────────────────────────────────────────────────

func TestSend_404Permanent(t *testing.T) {
	e := newTestEnv(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)
	withStdin(t, "hi")

	code, _, stderr := callSend("--title", "X", "--event", "stop")
	if code != 0 {
		t.Fatalf("exit=%d, want 0; stderr=%q", code, stderr)
	}
	n, err := discord.CountFailures(e.Project)
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 1 {
		t.Fatalf("want 1 failure entry; got %d", n)
	}
}

// ── 3. 429 retry-after=0 then 200 ─────────────────────────────────────

func TestSend_429Then200(t *testing.T) {
	e := newTestEnv(t)
	var hits int32
	srv := httptest.NewServer(countHits(&hits, func(w http.ResponseWriter, r *http.Request) {
		if atomic.LoadInt32(&hits) == 1 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)
	withStdin(t, "hi")

	code, _, stderr := callSend("--title", "X", "--event", "stop")
	if code != 0 {
		t.Fatalf("exit=%d, want 0; stderr=%q", code, stderr)
	}
	if h := atomic.LoadInt32(&hits); h != 2 {
		t.Fatalf("hits=%d, want 2", h)
	}
}

// ── 4. Coalesce merge (two identical sends within 30s) ────────────────

func TestSend_CoalesceMerge(t *testing.T) {
	e := newTestEnv(t)
	var hits int32
	srv := httptest.NewServer(countHits(&hits, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)

	withStdin(t, "hi")
	if code, _, se := callSend("--title", "T", "--event", "stop", "--task-id", "42"); code != 0 {
		t.Fatalf("first send exit=%d stderr=%q", code, se)
	}
	withStdin(t, "hi")
	if code, _, se := callSend("--title", "T", "--event", "stop", "--task-id", "42"); code != 0 {
		t.Fatalf("second send exit=%d stderr=%q", code, se)
	}
	if h := atomic.LoadInt32(&hits); h != 1 {
		t.Fatalf("hits=%d, want 1 (second call must coalesce)", h)
	}
	raw, err := os.ReadFile(discord.StatePath(e.Project))
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	var st discord.RLState
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatalf("parse state: %v", err)
	}
	found := false
	for _, entry := range st.RecentTitles {
		if entry.Count >= 2 {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("no ring entry with Count>=2: %+v", st.RecentTitles)
	}
}

// ── 5. Different task-ids: both hit HTTP ──────────────────────────────

func TestSend_CoalesceSeparate(t *testing.T) {
	e := newTestEnv(t)
	var hits int32
	srv := httptest.NewServer(countHits(&hits, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)

	withStdin(t, "a")
	callSend("--title", "T", "--event", "stop", "--task-id", "1")
	withStdin(t, "b")
	callSend("--title", "T", "--event", "stop", "--task-id", "2")

	if h := atomic.LoadInt32(&hits); h != 2 {
		t.Fatalf("hits=%d, want 2 (distinct task-ids)", h)
	}
}

// ── 6. Breaker opens after 5 × 500 ───────────────────────────────────

func TestSend_BreakerOpens(t *testing.T) {
	e := newTestEnv(t)
	var hits int32
	srv := httptest.NewServer(countHits(&hits, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)

	// 5 sends, each with distinct task-id so coalesce doesn't eat them.
	for i := 0; i < 5; i++ {
		withStdin(t, "x")
		code, _, se := callSend(
			"--title", "T",
			"--event", "err",
			"--task-id", []string{"a", "b", "c", "d", "e"}[i],
		)
		if code != 0 {
			t.Fatalf("send #%d exit=%d stderr=%q", i, code, se)
		}
	}
	hitsAfterFive := atomic.LoadInt32(&hits)

	// 6th call: breaker is open, no HTTP.
	withStdin(t, "x")
	code, _, se := callSend("--title", "T", "--event", "err", "--task-id", "f")
	if code != 0 {
		t.Fatalf("6th send exit=%d stderr=%q", code, se)
	}
	if got := atomic.LoadInt32(&hits); got != hitsAfterFive {
		t.Fatalf("6th call hit HTTP (hits %d -> %d)", hitsAfterFive, got)
	}

	entries, err := discord.TailFailures(e.Project, 100)
	if err != nil {
		t.Fatalf("tail: %v", err)
	}
	found := false
	for _, en := range entries {
		if en.Error == "breaker-open" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("no breaker-open entry in failure log: %+v", entries)
	}
}

// ── 7. --if-bound with no binding: silent exit 0, no HTTP, no state ───

func TestSend_IfBoundNoHTTP(t *testing.T) {
	e := newTestEnv(t)
	var hits int32
	srv := httptest.NewServer(countHits(&hits, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	// deliberately do NOT writeBinding/writeConf
	withStdin(t, "hi")
	code, out, stderr := callSend("--if-bound", "--title", "T", "--event", "stop")
	if code != 0 {
		t.Fatalf("exit=%d, want 0; stderr=%q", code, stderr)
	}
	if out != "" || stderr != "" {
		t.Fatalf("expected silent; out=%q stderr=%q", out, stderr)
	}
	if atomic.LoadInt32(&hits) != 0 {
		t.Fatalf("unexpected HTTP hits: %d", hits)
	}
	if _, err := os.Stat(discord.StatePath(e.Project)); !os.IsNotExist(err) {
		t.Fatalf("state file should not exist: %v", err)
	}
}

// ── 8. send-test bypasses coalesce ────────────────────────────────────

func TestSendTest_BypassCoalesce(t *testing.T) {
	e := newTestEnv(t)
	var hits int32
	srv := httptest.NewServer(countHits(&hits, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)

	for i := 0; i < 2; i++ {
		var out, errb bytes.Buffer
		if code := runSendTest(nil, &out, &errb); code != 0 {
			t.Fatalf("send-test #%d exit=%d stderr=%q", i, code, errb.String())
		}
	}
	if h := atomic.LoadInt32(&hits); h != 2 {
		t.Fatalf("hits=%d, want 2 (send-test must bypass coalesce)", h)
	}
}

// ── 9. Stdin body reaches HTTP handler untouched ──────────────────────

func TestSend_StdinBodyReachesHTTP(t *testing.T) {
	e := newTestEnv(t)
	var gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)

	const marker = "SECRETXYZ123"
	// Hermetic against ambient env: METADATA_ONLY wins precedence, so an
	// inherited DOEY_DISCORD_METADATA_ONLY=1 would suppress the body before
	// INCLUDE_BODY=1 takes effect. Unset it for this test.
	t.Setenv("DOEY_DISCORD_METADATA_ONLY", "")
	t.Setenv("DOEY_DISCORD_INCLUDE_BODY", "1")
	withStdin(t, marker)
	code, _, stderr := callSend("--title", "T", "--event", "stop")
	if code != 0 {
		t.Fatalf("exit=%d; stderr=%q", code, stderr)
	}
	if !strings.Contains(gotBody, marker) {
		t.Fatalf("HTTP body missing stdin marker; got %q", gotBody)
	}
}

// ── Sanity: runtime dir we wrote to matches the env ──────────────────

func TestSend_UsesIsolatedRuntime(t *testing.T) {
	e := newTestEnv(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)
	withStdin(t, "x")
	if code, _, se := callSend("--title", "T", "--event", "stop"); code != 0 {
		t.Fatalf("exit=%d stderr=%q", code, se)
	}
	if _, err := os.Stat(filepath.Join(e.Runtime, "discord-rl.state")); err != nil {
		t.Fatalf("state not in isolated runtime dir: %v", err)
	}
}
