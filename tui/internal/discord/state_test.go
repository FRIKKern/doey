package discord

import (
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
)

// setupRuntime pins RUNTIME_DIR to a per-test temp dir and returns the
// project dir used by callers (any non-empty string works — RuntimeDir
// prefers the env var).
func setupRuntime(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("RUNTIME_DIR", dir)
	return "/tmp/not-used-because-runtime-dir-is-set"
}

func TestLoad_MissingFile_ReturnsZeroState(t *testing.T) {
	proj := setupRuntime(t)
	st, err := Load(proj)
	if err != nil {
		t.Fatalf("Load on missing: %v", err)
	}
	if st == nil {
		t.Fatal("expected non-nil state")
	}
	if st.V != RLStateVersion {
		t.Errorf("V=%d, want %d", st.V, RLStateVersion)
	}
	if st.CredHash != "" || len(st.PerRoute) != 0 || len(st.RecentTitles) != 0 {
		t.Errorf("expected zero values, got %+v", st)
	}
}

func TestSaveAtomic_RoundTrip(t *testing.T) {
	proj := setupRuntime(t)
	orig := &RLState{
		V:                   RLStateVersion,
		CredHash:            "abc123",
		PerRoute:            map[string]Route{"webhook:/x": {Remaining: 4, ResetUnix: 1700000000}},
		GlobalPauseUntil:    123,
		BreakerOpenUntil:    456,
		ConsecutiveFailures: 2,
		RecentTitles: []CoalesceEntry{
			{Hash: "h1", Ts: 111, Count: 1, PendingFlush: false, Event: "stop", TaskID: "42", Title: "Build done"},
			{Hash: "h2", Ts: 222, Count: 3, PendingFlush: true},
		},
	}
	if err := WithFlock(proj, func(_ int) error { return SaveAtomic(proj, orig) }); err != nil {
		t.Fatalf("SaveAtomic: %v", err)
	}
	got, err := Load(proj)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.CredHash != orig.CredHash || got.GlobalPauseUntil != 123 ||
		got.BreakerOpenUntil != 456 || got.ConsecutiveFailures != 2 {
		t.Errorf("round-trip mismatch: %+v vs %+v", got, orig)
	}
	if len(got.RecentTitles) != 2 || got.RecentTitles[0].Title != "Build done" {
		t.Errorf("RecentTitles lost: %+v", got.RecentTitles)
	}
	if r, ok := got.PerRoute["webhook:/x"]; !ok || r.Remaining != 4 {
		t.Errorf("PerRoute lost: %+v", got.PerRoute)
	}
}

// TestAtomicWrite_IgnoresDanglingTmp verifies that a leftover .tmp file from
// a prior crash does not affect Load (which reads the final file, not .tmp).
func TestAtomicWrite_IgnoresDanglingTmp(t *testing.T) {
	proj := setupRuntime(t)
	// Write a real state first.
	real := &RLState{V: RLStateVersion, CredHash: "real"}
	if err := WithFlock(proj, func(_ int) error { return SaveAtomic(proj, real) }); err != nil {
		t.Fatal(err)
	}
	// Drop a partial .tmp next to it.
	tmp := tmpStatePath(proj)
	if err := os.WriteFile(tmp, []byte("{partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := Load(proj)
	if err != nil {
		t.Fatalf("Load should succeed with dangling tmp: %v", err)
	}
	if got.CredHash != "real" {
		t.Errorf("expected real state, got %+v", got)
	}
	// Now save again — SaveAtomic should tolerate the leftover tmp.
	if err := WithFlock(proj, func(_ int) error { return SaveAtomic(proj, &RLState{V: 1, CredHash: "fresh"}) }); err != nil {
		t.Fatalf("SaveAtomic with leftover tmp: %v", err)
	}
	got2, _ := Load(proj)
	if got2.CredHash != "fresh" {
		t.Errorf("expected fresh, got %+v", got2)
	}
}

func TestWithFlock_Serializes(t *testing.T) {
	proj := setupRuntime(t)
	var counter int64
	var wg sync.WaitGroup
	// Two goroutines each increment counter inside the lock. Under a correct
	// flock the final value is exactly 2. go test -race catches missing sync.
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := WithFlock(proj, func(_ int) error {
				v := atomic.LoadInt64(&counter)
				atomic.StoreInt64(&counter, v+1)
				return nil
			}); err != nil {
				t.Errorf("WithFlock: %v", err)
			}
		}()
	}
	wg.Wait()
	if got := atomic.LoadInt64(&counter); got != 2 {
		t.Errorf("counter=%d, want 2", got)
	}
}

func TestDecide_EmptyState_DecidesSend(t *testing.T) {
	st := &RLState{V: 1}
	key := ComputeCoalesceKey("stop", "42", "build done")
	d, ns := Decide(st, 1000, "hash1", key, false)
	if d != DecisionSend {
		t.Errorf("decision=%v, want Send", d)
	}
	if len(ns.RecentTitles) != 1 {
		t.Errorf("expected 1 ring entry, got %d", len(ns.RecentTitles))
	}
	if ns.CredHash != "hash1" {
		t.Errorf("CredHash not set: %q", ns.CredHash)
	}
}

func TestDecide_CoalesceSuppress(t *testing.T) {
	key := ComputeCoalesceKey("stop", "42", "build done")
	st := &RLState{V: 1, CredHash: "h", RecentTitles: []CoalesceEntry{{Hash: key, Ts: 1000, Count: 1}}}
	d, ns := Decide(st, 1005, "h", key, false)
	if d != DecisionCoalesceSuppress {
		t.Errorf("decision=%v, want CoalesceSuppress", d)
	}
	if ns.RecentTitles[0].Count != 2 || !ns.RecentTitles[0].PendingFlush {
		t.Errorf("ring not updated: %+v", ns.RecentTitles[0])
	}
}

func TestDecide_DeferredFlushThenSend(t *testing.T) {
	key := ComputeCoalesceKey("stop", "42", "build done")
	// Pending flush from 60s ago — window expired.
	st := &RLState{V: 1, CredHash: "h", RecentTitles: []CoalesceEntry{
		{Hash: key, Ts: 1000, Count: 3, PendingFlush: true},
	}}
	d, ns := Decide(st, 1060, "h", key, false)
	if d != DecisionDeferredFlushThenSend {
		t.Errorf("decision=%v, want DeferredFlushThenSend", d)
	}
	if ns.RecentTitles[0].PendingFlush {
		t.Errorf("PendingFlush should be cleared in returned state")
	}
}

func TestDecide_BreakerSkip(t *testing.T) {
	st := &RLState{V: 1, CredHash: "h", BreakerOpenUntil: 2000}
	d, _ := Decide(st, 1500, "h", "k", false)
	if d != DecisionBreakerSkip {
		t.Errorf("decision=%v, want BreakerSkip", d)
	}
}

func TestDecide_PauseSkip(t *testing.T) {
	st := &RLState{V: 1, CredHash: "h", GlobalPauseUntil: 2000}
	d, _ := Decide(st, 1500, "h", "k", false)
	if d != DecisionPauseSkip {
		t.Errorf("decision=%v, want PauseSkip", d)
	}
}

func TestDecide_PauseBeatsBreaker(t *testing.T) {
	st := &RLState{V: 1, CredHash: "h", GlobalPauseUntil: 2000, BreakerOpenUntil: 2000}
	d, _ := Decide(st, 1500, "h", "k", false)
	if d != DecisionPauseSkip {
		t.Errorf("decision=%v, want PauseSkip (pause first)", d)
	}
}

func TestDecide_CoalesceKey_DifferentTaskIDs_SeparateEntries(t *testing.T) {
	k1 := ComputeCoalesceKey("stop", "42", "t")
	k2 := ComputeCoalesceKey("stop", "43", "t")
	if k1 == k2 {
		t.Fatal("keys should differ for different task ids")
	}
	st := &RLState{V: 1, CredHash: "h"}
	_, st2 := Decide(st, 1000, "h", k1, false)
	_, st3 := Decide(st2, 1001, "h", k2, false)
	if len(st3.RecentTitles) != 2 {
		t.Errorf("expected 2 entries, got %d", len(st3.RecentTitles))
	}
}

func TestDecide_CredHashChange_ZeroesCaches_PreservesPause(t *testing.T) {
	st := &RLState{
		V:                   1,
		CredHash:            "old",
		PerRoute:            map[string]Route{"r": {Remaining: 1}},
		BreakerOpenUntil:    9999,
		ConsecutiveFailures: 5,
		GlobalPauseUntil:    88888,
	}
	_, ns := Decide(st, 100, "new", "k", false)
	if ns.CredHash != "new" {
		t.Errorf("CredHash=%q, want new", ns.CredHash)
	}
	if ns.PerRoute != nil {
		t.Errorf("PerRoute not cleared: %+v", ns.PerRoute)
	}
	if ns.BreakerOpenUntil != 0 || ns.ConsecutiveFailures != 0 {
		t.Errorf("breaker not reset: open=%d cf=%d", ns.BreakerOpenUntil, ns.ConsecutiveFailures)
	}
	if ns.GlobalPauseUntil != 88888 {
		t.Errorf("GlobalPauseUntil should be preserved, got %d", ns.GlobalPauseUntil)
	}
}

func TestDecide_RingEvictsOldestAtCap(t *testing.T) {
	st := &RLState{V: 1, CredHash: "h"}
	// Fill to cap with unique keys.
	for i := 0; i < RecentTitlesCap; i++ {
		k := ComputeCoalesceKey("ev", "", string(rune('a'+i)))
		_, st = Decide(st, int64(1000+i), "h", k, false)
	}
	if len(st.RecentTitles) != RecentTitlesCap {
		t.Fatalf("ring not filled to cap: %d", len(st.RecentTitles))
	}
	oldestHash := st.RecentTitles[0].Hash
	// Add one more with a fresh key.
	k := ComputeCoalesceKey("ev", "", "NEW")
	_, st = Decide(st, 9999, "h", k, false)
	if len(st.RecentTitles) != RecentTitlesCap {
		t.Errorf("ring grew past cap: %d", len(st.RecentTitles))
	}
	for _, e := range st.RecentTitles {
		if e.Hash == oldestHash {
			t.Errorf("oldest entry should have been evicted")
		}
	}
}

func TestDecide_BypassCoalesce_AlwaysSends_NoRingMutation(t *testing.T) {
	key := ComputeCoalesceKey("stop", "42", "t")
	st := &RLState{V: 1, CredHash: "h", RecentTitles: []CoalesceEntry{{Hash: key, Ts: 1000, Count: 1}}}
	d, ns := Decide(st, 1005, "h", key, true)
	if d != DecisionSend {
		t.Errorf("decision=%v, want Send", d)
	}
	if ns.RecentTitles[0].Count != 1 {
		t.Errorf("ring mutated under bypass: count=%d", ns.RecentTitles[0].Count)
	}
}

func TestRecordSendResult_SuccessResetsBreaker(t *testing.T) {
	st := &RLState{ConsecutiveFailures: 3, BreakerOpenUntil: 999}
	ns := RecordSendResult(st, 100, true, 0, false)
	if ns.ConsecutiveFailures != 0 || ns.BreakerOpenUntil != 0 {
		t.Errorf("success should reset: %+v", ns)
	}
}

func TestRecordSendResult_FailureOpensBreakerAtThreshold(t *testing.T) {
	st := &RLState{ConsecutiveFailures: BreakerThreshold - 1}
	ns := RecordSendResult(st, 100, false, 0, false)
	if ns.ConsecutiveFailures != BreakerThreshold {
		t.Errorf("cf=%d, want %d", ns.ConsecutiveFailures, BreakerThreshold)
	}
	if ns.BreakerOpenUntil != 100+int64(BreakerOpenDuration) {
		t.Errorf("breaker not opened: %d", ns.BreakerOpenUntil)
	}
}

func TestRecordSendResult_GlobalPause(t *testing.T) {
	st := &RLState{}
	ns := RecordSendResult(st, 100, false, 30, true)
	if ns.GlobalPauseUntil != 130 {
		t.Errorf("GlobalPauseUntil=%d, want 130", ns.GlobalPauseUntil)
	}
}

func TestResetBreaker(t *testing.T) {
	st := &RLState{ConsecutiveFailures: 9, BreakerOpenUntil: 99999}
	ns := ResetBreaker(st)
	if ns.ConsecutiveFailures != 0 || ns.BreakerOpenUntil != 0 {
		t.Errorf("breaker not reset: %+v", ns)
	}
}

func TestStatePath_UsesRuntimeDir(t *testing.T) {
	proj := setupRuntime(t)
	p := StatePath(proj)
	if filepath.Base(p) != "discord-rl.state" {
		t.Errorf("unexpected path: %q", p)
	}
}

func TestRuntimeDir_FallbackWhenNoEnv(t *testing.T) {
	t.Setenv("RUNTIME_DIR", "")
	os.Unsetenv("RUNTIME_DIR")
	got := RuntimeDir("/home/frikk/my-project")
	want := "/tmp/doey/my-project"
	if got != want {
		t.Errorf("RuntimeDir=%q, want %q", got, want)
	}
}
