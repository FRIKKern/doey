package planview

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// minimal plan body sufficient for planparse.Parse to succeed.
const testPlanBody = `# Masterplan: tester
## Goal
test
### Phase 1: foo
**Status:** planned
- [ ] do a thing
`

func writePlan(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "plan.md")
	if err := os.WriteFile(path, []byte(testPlanBody), 0o644); err != nil {
		t.Fatalf("write plan: %v", err)
	}
	return path
}

func TestWaitForStableSize_StableFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stable")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	size, _, err := waitForStableSize(path, 100*time.Millisecond)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if size != 5 {
		t.Errorf("size=%d want 5", size)
	}
	if elapsed := time.Since(start); elapsed > 250*time.Millisecond {
		t.Errorf("took %v, want <250ms", elapsed)
	}
}

func TestWaitForStableSize_GrowingFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "growing")
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			return
		}
		defer f.Close()
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				_, _ = f.WriteString("x")
			}
		}
	}()
	defer func() {
		close(stop)
		wg.Wait()
	}()

	window := 100 * time.Millisecond
	start := time.Now()
	_, _, err := waitForStableSize(path, window)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	// The cap is 2*window. Allow generous slack for goroutine
	// scheduling (the helper measures from prevAt, so worst case is
	// 2*window + one tick).
	if elapsed > 2*window+200*time.Millisecond {
		t.Errorf("did not cap: elapsed=%v want <=%v", elapsed, 2*window+200*time.Millisecond)
	}
}

func TestWaitForStableSize_ZeroByte(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "empty")
	if err := os.WriteFile(path, []byte{}, 0o644); err != nil {
		t.Fatal(err)
	}
	window := 60 * time.Millisecond
	start := time.Now()
	size, _, err := waitForStableSize(path, window)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if size != 0 {
		t.Errorf("size=%d want 0", size)
	}
	if elapsed := time.Since(start); elapsed > 250*time.Millisecond {
		t.Errorf("took %v, want <250ms", elapsed)
	}
}

// atomicWrite mimics tmp+rename atomic-replace: write to <path>.tmp
// then os.Rename. Returns first error encountered.
func atomicWrite(path string, body []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, body, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func TestLive_AtomicRenameNoTornRead(t *testing.T) {
	dir := t.TempDir()
	planPath := writePlan(t, dir)
	consensusPath := filepath.Join(dir, "consensus.state")
	if err := atomicWrite(consensusPath, []byte("CONSENSUS_STATE=DRAFT\n")); err != nil {
		t.Fatal(err)
	}

	live := NewLiveLegacy(planPath, "", "")
	defer live.Close()

	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		states := []string{"DRAFT", "UNDER_REVIEW", "REVISIONS_NEEDED", "CONSENSUS"}
		for i := 0; i < 100; i++ {
			body := fmt.Sprintf("CONSENSUS_STATE=%s\nROUND=%d\n", states[i%len(states)], i)
			_ = atomicWrite(consensusPath, []byte(body))
			select {
			case <-stop:
				return
			case <-time.After(2 * time.Millisecond):
			}
		}
	}()

	hits := 0
	const reads = 100
	ctx := context.Background()
	for i := 0; i < reads; i++ {
		snap, err := live.Read(ctx)
		if err != nil {
			t.Fatalf("read[%d]: %v", i, err)
		}
		if snap.Consensus.State != "" {
			hits++
		}
		time.Sleep(time.Millisecond)
	}
	close(stop)
	wg.Wait()

	if hits < 95 {
		t.Errorf("only %d/%d reads observed a non-empty state", hits, reads)
	}
}

func TestLive_SelfWriteFilter(t *testing.T) {
	dir := t.TempDir()
	planPath := writePlan(t, dir)

	live := NewLive(planPath, "", "")
	defer live.Close()

	if live.Updates() == nil {
		t.Fatal("Updates() must be non-nil for NewLive")
	}

	// Drain initial baseline emission(s).
	drainFor(live.Updates(), 150*time.Millisecond)

	// Notify self-write, then write — expect no Snapshot within 200ms.
	live.NotifySelfWrite(planPath)
	if err := os.WriteFile(planPath, []byte(testPlanBody+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	select {
	case <-live.Updates():
		t.Error("got Snapshot during self-write grace window")
	case <-time.After(250 * time.Millisecond):
	}

	// Wait past the grace window, write again, expect a Snapshot.
	time.Sleep(50 * time.Millisecond)
	if err := os.WriteFile(planPath, []byte(testPlanBody+"\n# more\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	select {
	case <-live.Updates():
	case <-time.After(2 * time.Second):
		t.Error("no Snapshot after grace window expired")
	}
}

// drainFor consumes from ch for at least d, returning when no event
// arrives within d.
func drainFor(ch <-chan Snapshot, d time.Duration) {
	for {
		select {
		case <-ch:
		case <-time.After(d):
			return
		}
	}
}

func TestLive_LegacyModeNoWatcher(t *testing.T) {
	dir := t.TempDir()
	planPath := writePlan(t, dir)

	live := NewLiveLegacy(planPath, "", "")
	if live.Updates() != nil {
		t.Errorf("Updates() = non-nil, want nil for legacy")
	}
	// Read still works.
	if _, err := live.Read(context.Background()); err != nil {
		t.Fatalf("read: %v", err)
	}
	// Close is a safe no-op.
	if err := live.Close(); err != nil {
		t.Errorf("close: %v", err)
	}
	// Double-close also safe.
	if err := live.Close(); err != nil {
		t.Errorf("double close: %v", err)
	}
}

func TestLive_DegradedFlagOnAddWatchError(t *testing.T) {
	// Point at a planPath inside a directory that does not exist —
	// fsnotify.Add on the parent will fail and the watcher will
	// degrade.
	bogus := filepath.Join(os.TempDir(), fmt.Sprintf("planview-no-such-%d-%d", os.Getpid(), time.Now().UnixNano()), "plan.md")
	live := NewLive(bogus, "", "")
	defer live.Close()

	// Wait up to 1s for the goroutine to mark degraded.
	deadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(deadline) {
		if live.Degraded() {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !live.Degraded() {
		t.Fatalf("expected Degraded() == true for bogus path")
	}
	if live.DegradedReason() == "" {
		t.Errorf("DegradedReason() empty")
	}
}

func TestLive_ResearchIndexLoad(t *testing.T) {
	dir := t.TempDir()
	planPath := writePlan(t, dir)

	researchDir := filepath.Join(dir, "research")
	if err := os.MkdirAll(researchDir, 0o755); err != nil {
		t.Fatal(err)
	}
	w1 := "# Heading\n\nFirst real line of w1.\nSecond line.\n"
	w2 := "# H1\n\n## sub\n\nFirst real line of w2 file.\nSecond line.\n"
	if err := os.WriteFile(filepath.Join(researchDir, "w1.md"), []byte(w1), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(researchDir, "w2.md"), []byte(w2), 0o644); err != nil {
		t.Fatal(err)
	}

	live := NewLiveLegacy(planPath, "", "")
	defer live.Close()
	snap, err := live.Read(context.Background())
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if got := len(snap.Research.Entries); got != 2 {
		t.Fatalf("entries=%d want 2", got)
	}
	abs1 := snap.Research.Entries[0].Abstract
	abs2 := snap.Research.Entries[1].Abstract
	if !strings.Contains(abs1, "First real line of w1") {
		t.Errorf("w1 abstract = %q", abs1)
	}
	if !strings.Contains(abs2, "First real line of w2 file") {
		t.Errorf("w2 abstract = %q", abs2)
	}
}

// TestLive_EmitCoalescing exercises the drop-oldest semantics directly
// so the contract is locked even if the watcher path is racy.
func TestLive_EmitCoalescing(t *testing.T) {
	live := NewLiveLegacy("/dev/null", "", "")
	defer live.Close()
	live.updatesCh = make(chan Snapshot, 1)

	var n int32
	mk := func() Snapshot {
		atomic.AddInt32(&n, 1)
		return Snapshot{Timestamp: time.Now()}
	}
	live.emit(mk())
	live.emit(mk()) // should overwrite, not block
	select {
	case <-live.updatesCh:
	case <-time.After(50 * time.Millisecond):
		t.Fatal("expected pending value")
	}
	// Channel now empty.
	select {
	case <-live.updatesCh:
		t.Fatal("expected empty channel")
	case <-time.After(20 * time.Millisecond):
	}
}

// sanity check that Live satisfies Source.
func TestLive_SatisfiesSource(t *testing.T) {
	var _ Source = (*Live)(nil)
	var _ Source = (*Demo)(nil)
}

// TestErrIsENOSPC sanity-checks the wrap detection so the degraded
// reason string is set correctly on the real error path.
func TestErrIsENOSPC(t *testing.T) {
	if errIsENOSPC(nil) {
		t.Fatal("nil should not be ENOSPC")
	}
	if errIsENOSPC(errors.New("plain")) {
		t.Fatal("plain string error should not be ENOSPC")
	}
}
