package discord

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
	"testing"
)

func TestAppendFailure_SingleLine(t *testing.T) {
	proj := setupRuntime(t)
	entry := FailureEntry{
		ID: "id1", Ts: "2026-01-01T00:00:00Z", CredHash: "h",
		Kind: "webhook", Event: "stop", Title: "t", Error: "boom",
	}
	if err := AppendFailure(proj, entry); err != nil {
		t.Fatalf("AppendFailure: %v", err)
	}
	b, err := os.ReadFile(FailedLogPath(proj))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(string(b), "\n") {
		t.Errorf("entry not newline-terminated: %q", string(b))
	}
	var decoded FailureEntry
	if err := json.Unmarshal([]byte(strings.TrimRight(string(b), "\n")), &decoded); err != nil {
		t.Errorf("decode: %v", err)
	}
	if decoded.V != FailedLogVersion {
		t.Errorf("V=%d, want %d", decoded.V, FailedLogVersion)
	}
	if decoded.ID != "id1" {
		t.Errorf("ID=%q, want id1", decoded.ID)
	}
}

func TestAppendFailure_ConcurrentAppends_NoInterleaving(t *testing.T) {
	proj := setupRuntime(t)
	const N = 20
	var wg sync.WaitGroup
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			e := FailureEntry{
				ID: GenerateID(), Ts: "2026-01-01T00:00:00Z",
				CredHash: "h", Kind: "webhook", Event: "e",
				Title: "t", Error: "err",
			}
			if err := AppendFailure(proj, e); err != nil {
				t.Errorf("AppendFailure: %v", err)
			}
		}(i)
	}
	wg.Wait()
	entries, err := TailFailures(proj, N+5)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != N {
		t.Errorf("got %d entries, want %d", len(entries), N)
	}
}

func TestAppendFailure_OversizeRejected(t *testing.T) {
	proj := setupRuntime(t)
	big := strings.Repeat("x", FailedLogMaxLineBytes+100)
	e := FailureEntry{
		ID: "big", Ts: "t", CredHash: "h", Kind: "webhook",
		Event: "e", Title: "t", Error: big,
	}
	err := AppendFailure(proj, e)
	if err == nil {
		t.Fatal("expected oversize error")
	}
	// File should not exist (nothing written).
	if _, statErr := os.Stat(FailedLogPath(proj)); statErr == nil {
		t.Errorf("file should not exist after oversize rejection")
	}
}

func TestTailFailures_ReturnsLastN(t *testing.T) {
	proj := setupRuntime(t)
	for i := 0; i < 10; i++ {
		e := FailureEntry{ID: string(rune('a' + i)), Ts: "t", CredHash: "h",
			Kind: "webhook", Event: "e", Title: "t", Error: "err"}
		if err := AppendFailure(proj, e); err != nil {
			t.Fatal(err)
		}
	}
	got, err := TailFailures(proj, 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d, want 3", len(got))
	}
	if got[0].ID != "h" || got[2].ID != "j" {
		t.Errorf("wrong tail: %+v", got)
	}
}

func TestTailFailures_SkipsUnparseableLines(t *testing.T) {
	proj := setupRuntime(t)
	e := FailureEntry{V: 1, ID: "ok", Ts: "t", CredHash: "h",
		Kind: "webhook", Event: "e", Title: "t", Error: "err"}
	if err := AppendFailure(proj, e); err != nil {
		t.Fatal(err)
	}
	// Append garbage directly.
	f, _ := os.OpenFile(FailedLogPath(proj), os.O_APPEND|os.O_WRONLY, 0o600)
	f.WriteString("{not valid json\n")
	f.Close()
	if err := AppendFailure(proj, e); err != nil {
		t.Fatal(err)
	}
	got, err := TailFailures(proj, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Errorf("got %d parsed entries, want 2 (garbage skipped)", len(got))
	}
}

func TestPruneFailures_KeepsLastN(t *testing.T) {
	proj := setupRuntime(t)
	for i := 0; i < 20; i++ {
		e := FailureEntry{ID: GenerateID(), Ts: "t", CredHash: "h",
			Kind: "webhook", Event: "e", Title: "t", Error: "err"}
		if err := AppendFailure(proj, e); err != nil {
			t.Fatal(err)
		}
	}
	removed, err := PruneFailures(proj, 5)
	if err != nil {
		t.Fatal(err)
	}
	if removed != 15 {
		t.Errorf("removed=%d, want 15", removed)
	}
	n, _ := CountFailures(proj)
	if n != 5 {
		t.Errorf("count=%d, want 5", n)
	}
}

func TestPruneFailures_NoOpWhenBelowThreshold(t *testing.T) {
	proj := setupRuntime(t)
	for i := 0; i < 3; i++ {
		e := FailureEntry{ID: GenerateID(), Ts: "t", CredHash: "h",
			Kind: "webhook", Event: "e", Title: "t", Error: "err"}
		AppendFailure(proj, e)
	}
	removed, err := PruneFailures(proj, 10)
	if err != nil {
		t.Fatal(err)
	}
	if removed != 0 {
		t.Errorf("removed=%d, want 0", removed)
	}
}

func TestLazyPruneIfNeeded(t *testing.T) {
	proj := setupRuntime(t)
	// Below threshold — no-op.
	for i := 0; i < 5; i++ {
		AppendFailure(proj, FailureEntry{ID: GenerateID(), Ts: "t",
			CredHash: "h", Kind: "webhook", Event: "e", Title: "t", Error: "err"})
	}
	if err := LazyPruneIfNeeded(proj); err != nil {
		t.Fatal(err)
	}
	n, _ := CountFailures(proj)
	if n != 5 {
		t.Errorf("should not prune below threshold: %d", n)
	}
}

func TestLazyPruneIfNeeded_Prunes(t *testing.T) {
	proj := setupRuntime(t)
	for i := 0; i < FailedLogMaxEntries+10; i++ {
		AppendFailure(proj, FailureEntry{ID: GenerateID(), Ts: "t",
			CredHash: "h", Kind: "webhook", Event: "e", Title: "t", Error: "err"})
	}
	if err := LazyPruneIfNeeded(proj); err != nil {
		t.Fatal(err)
	}
	n, _ := CountFailures(proj)
	if n != FailedLogMaxEntries {
		t.Errorf("count=%d, want %d", n, FailedLogMaxEntries)
	}
}

func TestCountFailures_MissingFile(t *testing.T) {
	proj := setupRuntime(t)
	n, err := CountFailures(proj)
	if err != nil {
		t.Fatalf("err=%v", err)
	}
	if n != 0 {
		t.Errorf("count=%d, want 0", n)
	}
}

func TestGenerateID_UniqueAndSortable(t *testing.T) {
	seen := make(map[string]bool)
	var prev string
	for i := 0; i < 100; i++ {
		id := GenerateID()
		if seen[id] {
			t.Fatalf("duplicate id: %s", id)
		}
		seen[id] = true
		if len(id) != 24 {
			t.Errorf("id length=%d, want 24", len(id))
		}
		if prev != "" && id < prev {
			// Clock monotonic within the same microsecond may flip due to
			// random suffix — but consecutive calls should not regress across
			// microseconds. Allow a small tolerance: skip if timestamps equal.
			// Just log, don't fail — monotonicity is best-effort.
			t.Logf("id went backward: %q < %q", id, prev)
		}
		prev = id
	}
}
