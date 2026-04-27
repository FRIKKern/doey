package planview

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/doey-cli/doey/tui/internal/planparse"
)

// Live is the production Source — it reads the plan and live signals
// directly from the project's runtime tree. NewLive starts a fsnotify
// watcher goroutine that emits Snapshot deltas down the Updates
// channel on file changes. NewLiveLegacy returns a Live without a
// watcher (snapshot-only) for the --legacy / DOEY_PLAN_VIEW_LEGACY=1
// rollback path documented in DECISIONS.md D4.
type Live struct {
	planPath   string
	runtimeDir string
	teamWindow string

	updatesCh chan Snapshot

	// watcher goroutine handle; nil in legacy mode.
	stop   chan struct{}
	doneCh chan struct{}

	// degraded reports an inotify watch failure (ENOSPC etc.); when
	// set, the watcher polls instead. atomic.Bool so the TUI can read
	// without a lock.
	degraded       atomic.Bool
	degradedReason atomic.Value // string

	selfWriteMu sync.Mutex
	selfWrites  map[string]time.Time

	closeOnce sync.Once
}

// NewLive constructs a Live source bound to the given plan path and
// starts a fsnotify watcher goroutine. The runtimeDir is the project's
// /tmp/doey/<project>/ directory and teamWindow is the tmux window
// index of the planning team (empty string when no team is bound yet).
//
// The watcher subscribes to the plan markdown, consensus.state, both
// reviewer verdict files, the research/ directory, and the
// per-pane <PANE_SAFE>.status files for the five planning panes
// (when teamWindow is non-empty). On any relevant event the watcher
// debounces (100ms), waits for size-stable-for-100ms via
// waitForStableSize, re-loads the snapshot, and sends it on Updates()
// with drop-oldest coalescing.
//
// If fsnotify cannot be started (e.g. ENOSPC), Live falls back to a 1s
// polling loop and Degraded() returns true with DegradedReason() set.
func NewLive(planPath, runtimeDir, teamWindow string) *Live {
	l := newLiveBase(planPath, runtimeDir, teamWindow)
	l.updatesCh = make(chan Snapshot, 1)
	l.stop = make(chan struct{})
	l.doneCh = make(chan struct{})
	l.degradedReason.Store("")
	go l.watchLoop()
	return l
}

// NewLiveLegacy constructs a Live source with no fsnotify watcher and
// a nil Updates channel. Read still works (snapshot-only). Close is
// safe (no-op). This is the --legacy / DOEY_PLAN_VIEW_LEGACY=1 path.
func NewLiveLegacy(planPath, runtimeDir, teamWindow string) *Live {
	l := newLiveBase(planPath, runtimeDir, teamWindow)
	l.degradedReason.Store("")
	return l
}

func newLiveBase(planPath, runtimeDir, teamWindow string) *Live {
	return &Live{
		planPath:   planPath,
		runtimeDir: runtimeDir,
		teamWindow: teamWindow,
		selfWrites: make(map[string]time.Time),
	}
}

// Read returns a freshly built Snapshot. Always re-loads from disk;
// callers that want a cached value should use Updates().
func (l *Live) Read(ctx context.Context) (Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	return l.loadSnapshot()
}

// Updates returns the watcher channel. Returns nil when constructed
// via NewLiveLegacy.
func (l *Live) Updates() <-chan Snapshot {
	return l.updatesCh
}

// Close stops the watcher goroutine and closes the Updates channel.
// Safe to call multiple times.
func (l *Live) Close() error {
	l.closeOnce.Do(func() {
		if l.stop != nil {
			close(l.stop)
			<-l.doneCh
		}
		if l.updatesCh != nil {
			close(l.updatesCh)
		}
	})
	return nil
}

// Degraded reports whether the watcher fell back to polling because
// fsnotify could not be set up (e.g. inotify watch limit).
func (l *Live) Degraded() bool {
	return l.degraded.Load()
}

// DegradedReason returns a human-readable explanation of the degraded
// state, or "" when not degraded.
func (l *Live) DegradedReason() string {
	if v, ok := l.degradedReason.Load().(string); ok {
		return v
	}
	return ""
}

// NotifySelfWrite records that the caller is about to perform a write
// to path; the watcher will suppress Write events on path for 200ms.
// Used by the persist() path so checkbox toggles don't echo back as
// cursor jumps.
func (l *Live) NotifySelfWrite(path string) {
	if path == "" {
		return
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		abs = path
	}
	l.selfWriteMu.Lock()
	l.selfWrites[abs] = time.Now().Add(200 * time.Millisecond)
	l.selfWriteMu.Unlock()
}

// shouldSuppress reports whether an event on path should be ignored
// because of a recent NotifySelfWrite. Expired entries are GC'd.
func (l *Live) shouldSuppress(path string) bool {
	abs, err := filepath.Abs(path)
	if err != nil {
		abs = path
	}
	l.selfWriteMu.Lock()
	defer l.selfWriteMu.Unlock()
	now := time.Now()
	for k, deadline := range l.selfWrites {
		if now.After(deadline) {
			delete(l.selfWrites, k)
		}
	}
	deadline, ok := l.selfWrites[abs]
	if !ok {
		return false
	}
	return now.Before(deadline)
}

// markDegraded sets the degraded flag with a reason. Idempotent.
func (l *Live) markDegraded(reason string) {
	l.degraded.Store(true)
	l.degradedReason.Store(reason)
}

// emit sends s on updatesCh with drop-oldest coalescing: if the
// channel is full (a previous Snapshot has not been consumed), the
// stale value is drained first so the receiver always sees the
// latest state. Non-blocking.
func (l *Live) emit(s Snapshot) {
	if l.updatesCh == nil {
		return
	}
	for {
		select {
		case l.updatesCh <- s:
			return
		default:
			select {
			case <-l.updatesCh:
				// drained one stale value; retry the send
			default:
				return
			}
		}
	}
}

// planID returns the plan file basename without the .md suffix.
func (l *Live) planID() string {
	return strings.TrimSuffix(filepath.Base(l.planPath), ".md")
}

// planDir returns the directory siblings of the plan path. Phase 2
// uses filepath.Dir(planPath); Phase 3 unifies path resolution.
func (l *Live) planDir() string {
	return filepath.Dir(l.planPath)
}

// loadSnapshot rebuilds the entire Snapshot from disk. All sub-loaders
// soft-fail on missing files.
func (l *Live) loadSnapshot() (Snapshot, error) {
	planDir := l.planDir()

	planBytes, err := os.ReadFile(l.planPath)
	if err != nil {
		return Snapshot{}, fmt.Errorf("planview: read plan %q: %w", l.planPath, err)
	}
	plan, err := planparse.Parse(planBytes)
	if err != nil {
		return Snapshot{}, fmt.Errorf("planview: parse plan %q: %w", l.planPath, err)
	}

	consensus := loadConsensus(planDir)
	review := loadReview(planDir, l.planID())
	research := loadResearch(planDir)
	workers := loadWorkers(l.runtimeDir, l.teamWindow)
	task := loadTaskFooter()

	return Snapshot{
		Plan: PlanState{
			Plan:       plan,
			PlanPath:   l.planPath,
			RuntimeDir: l.runtimeDir,
			PlanDir:    planDir,
			TeamWindow: l.teamWindow,
		},
		Consensus: consensus,
		Review:    review,
		Research:  research,
		Workers:   workers,
		Task:      task,
		Timestamp: time.Now(),
	}, nil
}

// loadConsensus reads <planDir>/consensus.state and returns a populated
// ConsensusInfo. Thin wrapper over parseConsensusFile so live and fixture
// loaders share one code path (Phase 4, see DECISIONS.md D6).
func loadConsensus(planDir string) ConsensusInfo {
	return parseConsensusFile(filepath.Join(planDir, "consensus.state"))
}

// parseConsensusFile reads a consensus.state file at the given path and
// returns the populated ConsensusInfo. Extracts CONSENSUS_STATE/STATE,
// ROUND, the per-reviewer verdict fields (used to derive
// Agreed/BlockingParties), and the UPDATED epoch (falling back to file
// mtime). When the file is absent, Standalone is set to true and State
// is left empty. RawSource is always set to path. This is the single
// shared parser used by both Live and Demo sources (Phase 4).
func parseConsensusFile(path string) ConsensusInfo {
	info := ConsensusInfo{RawSource: path}

	data, err := os.ReadFile(path)
	if err != nil {
		info.Standalone = true
		return info
	}

	if st, statErr := os.Stat(path); statErr == nil {
		info.UpdatedAt = st.ModTime()
	}

	var archVerdict, critVerdict string
	var updatedEpoch int64
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.Trim(strings.TrimSpace(line[eq+1:]), `"'`)
		switch {
		case strings.EqualFold(key, "CONSENSUS_STATE") || strings.EqualFold(key, "STATE"):
			info.State = strings.ToUpper(val)
		case strings.EqualFold(key, "ROUND"):
			fmt.Sscanf(val, "%d", &info.Round)
		case strings.EqualFold(key, "ARCHITECT_VERDICT"):
			archVerdict = strings.ToUpper(val)
		case strings.EqualFold(key, "CRITIC_VERDICT"):
			critVerdict = strings.ToUpper(val)
		case strings.EqualFold(key, "UPDATED"):
			fmt.Sscanf(val, "%d", &updatedEpoch)
		}
	}
	if updatedEpoch > 0 {
		info.UpdatedAt = time.Unix(updatedEpoch, 0)
	}
	info.AgreedParties, info.BlockingParties = derivePartiesFromVerdicts(archVerdict, critVerdict)
	return info
}

// derivePartiesFromVerdicts maps the per-reviewer verdict strings into
// agreed/blocking party lists. APPROVE → agreed; any non-empty
// non-APPROVE value (REVISE, BLOCK, …) → blocking. Empty values are
// "not yet voted" and contribute to neither list.
func derivePartiesFromVerdicts(arch, crit string) (agreed, blocking []string) {
	classify := func(role, verdict string) {
		v := strings.ToUpper(strings.TrimSpace(verdict))
		switch v {
		case "":
			return
		case "APPROVE", "APPROVED", "ACCEPT", "OK":
			agreed = append(agreed, role)
		default:
			blocking = append(blocking, role)
		}
	}
	classify("Architect", arch)
	classify("Critic", crit)
	return agreed, blocking
}

// loadReview populates the architect/critic VerdictCards by stat'ing
// the verdict files at <planDir>/<planID>.<role>.md. Phase 2 records
// VerdictPath, VerdictPresent, and FileMTime only — verdict line
// parsing is Phase 3 (see masterplan-20260426-203854 §Phase 3).
func loadReview(planDir, planID string) ReviewState {
	build := func(role string) VerdictCard {
		path := filepath.Join(planDir, planID+"."+role+".md")
		card := VerdictCard{VerdictPath: path}
		if st, err := os.Stat(path); err == nil {
			card.VerdictPresent = true
			card.FileMTime = st.ModTime()
		}
		return card
	}
	return ReviewState{
		Architect: build("architect"),
		Critic:    build("critic"),
	}
}

// loadResearch enumerates <planDir>/research/*.md and returns a
// ResearchIndex with Path, Size, MTime, and a one-line abstract. The
// abstract is the first non-empty line that does not start with "#"
// or "---", truncated to 120 chars.
func loadResearch(planDir string) ResearchIndex {
	dir := filepath.Join(planDir, "research")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ResearchIndex{}
	}
	var out []ResearchEntry
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()
		if !strings.HasSuffix(name, ".md") {
			continue
		}
		path := filepath.Join(dir, name)
		st, err := os.Stat(path)
		if err != nil {
			continue
		}
		out = append(out, ResearchEntry{
			Path:     path,
			Size:     st.Size(),
			MTime:    st.ModTime(),
			Abstract: extractAbstract(path),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return ResearchIndex{Entries: out}
}

// extractAbstract reads up to ~64KB from path and returns the first
// non-empty prose line (not a heading and not a YAML fence),
// truncated to 120 chars.
func extractAbstract(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 4096), 1<<16)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#") || strings.HasPrefix(line, "---") {
			continue
		}
		if len(line) > 120 {
			line = line[:120]
		}
		return line
	}
	return ""
}

// loadWorkers builds WorkerRow entries for the five planning panes
// (Planner=<W>.0, Architect=<W>.2, Critic=<W>.3, W1=<W>.4, W2=<W>.5)
// in the team window. Returns nil when teamWindow is empty.
//
// PANE_SAFE = `tr ':.-' '_'` of `<session>:<window>.<pane>`. Session
// name is taken from $DOEY_SESSION; if absent we fall back to deriving
// it from filepath.Base(runtimeDir) (which mirrors how
// shell/doey-session.sh exports it). Status files live at
// $runtimeDir/status/<PANE_SAFE>.status; sentinels are
// .unread / .reserved next to them.
func loadWorkers(runtimeDir, teamWindow string) []WorkerRow {
	if teamWindow == "" || runtimeDir == "" {
		return nil
	}
	session := os.Getenv("DOEY_SESSION")
	if session == "" {
		session = filepath.Base(runtimeDir)
		if session != "" {
			session = "doey-" + session
		}
	}
	if session == "" {
		return nil
	}
	statusDir := filepath.Join(runtimeDir, "status")
	panes := []string{"0", "2", "3", "4", "5"}
	rows := make([]WorkerRow, 0, len(panes))
	for _, p := range panes {
		paneIndex := teamWindow + "." + p
		safe := paneSafe(session, teamWindow, p)
		row := WorkerRow{PaneIndex: paneIndex}
		statusPath := filepath.Join(statusDir, safe+".status")
		if data, err := os.ReadFile(statusPath); err == nil {
			parseWorkerStatus(string(data), &row)
		}
		if _, err := os.Stat(filepath.Join(statusDir, safe+".unread")); err == nil {
			row.HasUnread = true
		}
		if _, err := os.Stat(filepath.Join(statusDir, safe+".reserved")); err == nil {
			row.Reserved = true
			if row.Status == "" {
				row.Status = "RESERVED"
			}
		}
		if hb, err := os.Stat(filepath.Join(statusDir, safe+".heartbeat")); err == nil {
			row.HeartbeatAge = time.Since(hb.ModTime())
		}
		rows = append(rows, row)
	}
	return rows
}

// paneSafe mirrors `tr ':.-' '_'` of `<session>:<window>.<pane>` (see
// .claude/hooks/common.sh:83).
func paneSafe(session, window, pane string) string {
	raw := session + ":" + window + "." + pane
	return strings.Map(func(r rune) rune {
		switch r {
		case ':', '.', '-':
			return '_'
		}
		return r
	}, raw)
}

// parseWorkerStatus parses a `.status` file's KEY: VALUE lines into a
// WorkerRow. Soft-fails on missing keys.
func parseWorkerStatus(body string, row *WorkerRow) {
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		colon := strings.IndexByte(line, ':')
		if colon < 0 {
			continue
		}
		key := strings.TrimSpace(line[:colon])
		val := strings.TrimSpace(line[colon+1:])
		switch strings.ToUpper(key) {
		case "STATUS":
			row.Status = strings.ToUpper(val)
		case "ACTIVITY":
			row.Activity = val
		case "LAST_ACTIVITY":
			if ts, err := parseUnix(val); err == nil {
				row.StallAge = time.Since(ts)
			}
		}
	}
}

// parseUnix parses a numeric unix-timestamp string.
func parseUnix(s string) (time.Time, error) {
	var n int64
	if _, err := fmt.Sscanf(s, "%d", &n); err != nil {
		return time.Time{}, err
	}
	return time.Unix(n, 0), nil
}

// loadTaskFooter populates the TaskFooter from $DOEY_TASK_ID and
// enriches it from .doey/tasks/<id>.task (file authoritative) plus the
// SQLite plans table (DB fallback). Phase 8 owns the enrichment — see
// LoadTaskFooter in task_footer.go for the resolution order.
func loadTaskFooter() TaskFooter {
	return LoadTaskFooter(os.Getenv("DOEY_PROJECT_DIR"), os.Getenv("DOEY_TASK_ID"))
}

// waitForStableSize polls os.Stat at ~25ms intervals and returns once
// two consecutive samples yield identical size, with at least window
// elapsed between samples. A file that has been size-zero for window
// is treated as a legitimate empty state and returns immediately.
//
// To avoid blocking the watcher loop on a continuously-growing file,
// the total wait is capped at 2*window — on hitting the cap the
// helper returns the latest sample. Stat errors return zeroed values
// and the error.
//
// Default window is 100ms when the caller passes 0.
func waitForStableSize(path string, window time.Duration) (int64, time.Time, error) {
	if window <= 0 {
		window = 100 * time.Millisecond
	}
	deadline := time.Now().Add(2 * window)
	tick := 25 * time.Millisecond

	st, err := os.Stat(path)
	if err != nil {
		return 0, time.Time{}, err
	}
	prevSize := st.Size()
	prevMtime := st.ModTime()
	prevAt := time.Now()

	for {
		if time.Now().After(deadline) {
			return prevSize, prevMtime, nil
		}
		if remaining := time.Until(prevAt.Add(window)); remaining > 0 {
			time.Sleep(minDur(remaining, tick))
			continue
		}
		st, err := os.Stat(path)
		if err != nil {
			return 0, time.Time{}, err
		}
		size := st.Size()
		if size == prevSize {
			return size, st.ModTime(), nil
		}
		prevSize = size
		prevMtime = st.ModTime()
		prevAt = time.Now()
	}
}

func minDur(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

// errIsENOSPC reports whether err wraps a system "no space left" error
// (the inotify watch-limit signal on Linux).
func errIsENOSPC(err error) bool {
	if err == nil {
		return false
	}
	return errors.Is(err, syscall.ENOSPC)
}
