package discord

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// Sentinel errors for this package.
var (
	ErrFlockUnsupported = errors.New("discord state: flock(2) not supported on this filesystem")
	ErrStateCorrupt     = errors.New("discord state: corrupt state file")
)

// RLState is the rate-limit / coalesce / breaker state persisted to
// <runtime>/discord-rl.state. Written atomically under a flock.
type RLState struct {
	V                   int              `json:"v"`
	CredHash            string           `json:"cred_hash"`
	PerRoute            map[string]Route `json:"per_route"`
	GlobalPauseUntil    int64            `json:"global_pause_until"`
	BreakerOpenUntil    int64            `json:"breaker_open_until"`
	ConsecutiveFailures int              `json:"consecutive_failures"`
	RecentTitles        []CoalesceEntry  `json:"recent_titles"`
}

// Route tracks Discord's per-route rate-limit counters (X-RateLimit-*).
type Route struct {
	Remaining int   `json:"remaining"`
	ResetUnix int64 `json:"reset_unix"`
}

// CoalesceEntry is one ring-buffer slot for duplicate-burst suppression.
type CoalesceEntry struct {
	Hash         string `json:"hash"`
	Ts           int64  `json:"ts"`
	Count        int    `json:"count"`
	PendingFlush bool   `json:"pending_flush"`
	Event        string `json:"event,omitempty"`
	TaskID       string `json:"task_id,omitempty"`
	Title        string `json:"title,omitempty"`
}

// Decision is the outcome of Decide — the caller should act on it.
type Decision int

const (
	DecisionSend Decision = iota
	DecisionCoalesceSuppress
	DecisionBreakerSkip
	DecisionPauseSkip
	// DecisionDeferredFlushThenSend — emit pending "(×N)" summary THEN proceed to send.
	DecisionDeferredFlushThenSend
)

// RuntimeDir returns the runtime directory: RUNTIME_DIR env var if set,
// otherwise /tmp/doey/<basename(projectDir)>.
func RuntimeDir(projectDir string) string {
	if env := os.Getenv("RUNTIME_DIR"); env != "" {
		return env
	}
	return filepath.Join("/tmp", "doey", filepath.Base(projectDir))
}

// StatePath returns the absolute path of discord-rl.state.
func StatePath(projectDir string) string {
	return filepath.Join(RuntimeDir(projectDir), "discord-rl.state")
}

// LockPath returns the absolute path of discord-rl.state.lock.
func LockPath(projectDir string) string {
	return filepath.Join(RuntimeDir(projectDir), "discord-rl.state.lock")
}

// tmpStatePath returns the atomic-write temp path. Flock serializes writers,
// so a fixed name is safe and cleaner than CreateTemp's random suffix.
func tmpStatePath(projectDir string) string {
	return filepath.Join(RuntimeDir(projectDir), "discord-rl.state.tmp")
}

// WithFlock opens the lock file (creating runtime dir + lock file if needed),
// acquires an exclusive advisory lock, invokes fn, and releases the lock.
// Returns ErrFlockUnsupported if the filesystem rejects flock(2).
func WithFlock(projectDir string, fn func(lockFd int) error) error {
	dir := RuntimeDir(projectDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("discord state: mkdir runtime: %w", err)
	}
	lp := LockPath(projectDir)
	f, err := os.OpenFile(lp, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("discord state: open lock: %w", err)
	}
	defer f.Close()

	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		if errors.Is(err, syscall.EINVAL) || errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.ENOSYS) {
			return ErrFlockUnsupported
		}
		return fmt.Errorf("discord state: flock: %w", err)
	}
	defer func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	}()

	return fn(int(f.Fd()))
}

// Load reads and decodes the state file. On ENOENT returns zero-value state
// with V=RLStateVersion. On decode error returns ErrStateCorrupt.
func Load(projectDir string) (*RLState, error) {
	p := StatePath(projectDir)
	b, err := os.ReadFile(p)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return &RLState{V: RLStateVersion}, nil
		}
		return nil, fmt.Errorf("discord state: read: %w", err)
	}
	if len(b) == 0 {
		return &RLState{V: RLStateVersion}, nil
	}
	var st RLState
	if err := json.Unmarshal(b, &st); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrStateCorrupt, err)
	}
	if st.V == 0 {
		st.V = RLStateVersion
	}
	return &st, nil
}

// SaveAtomic writes the state via .tmp + fsync + rename + fsync(dir).
// Caller must hold the flock (i.e. call from inside WithFlock).
func SaveAtomic(projectDir string, st *RLState) error {
	if st == nil {
		return errors.New("discord state: nil state")
	}
	if st.V == 0 {
		st.V = RLStateVersion
	}
	dir := RuntimeDir(projectDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("discord state: mkdir: %w", err)
	}
	data, err := json.Marshal(st)
	if err != nil {
		return fmt.Errorf("discord state: marshal: %w", err)
	}

	tmp := tmpStatePath(projectDir)
	// Remove any stale tmp left by a prior crash (flock serializes us).
	_ = os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("discord state: create tmp: %w", err)
	}
	cleaned := false
	defer func() {
		if !cleaned {
			_ = os.Remove(tmp)
		}
	}()
	if _, err := f.Write(data); err != nil {
		f.Close()
		return fmt.Errorf("discord state: write: %w", err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return fmt.Errorf("discord state: fsync: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("discord state: close: %w", err)
	}
	if err := os.Rename(tmp, StatePath(projectDir)); err != nil {
		return fmt.Errorf("discord state: rename: %w", err)
	}
	cleaned = true
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

// ComputeCoalesceKey returns sha256 hex of event+"|"+taskID+"|"+title.
// If taskID=="" the separator is doubled so the empty-task key is distinct
// from any real task id.
func ComputeCoalesceKey(event, taskID, title string) string {
	var src string
	if taskID == "" {
		src = event + "||" + title
	} else {
		src = event + "|" + taskID + "|" + title
	}
	sum := sha256.Sum256([]byte(src))
	return hex.EncodeToString(sum[:])
}

// cloneState returns a deep-ish copy so Decide can mutate without racing the
// caller's reference. Routes map is shallow-copied; CoalesceEntry is a value
// type so slice copy suffices.
func cloneState(st *RLState) *RLState {
	if st == nil {
		return &RLState{V: RLStateVersion}
	}
	out := *st
	if st.PerRoute != nil {
		out.PerRoute = make(map[string]Route, len(st.PerRoute))
		for k, v := range st.PerRoute {
			out.PerRoute[k] = v
		}
	}
	if st.RecentTitles != nil {
		out.RecentTitles = append([]CoalesceEntry(nil), st.RecentTitles...)
	}
	return &out
}

// Decide is pure: given current state + clock + credential hash + coalesce
// key + bypass flag, returns (decision, newState). The returned state should
// be persisted by the caller under the flock.
func Decide(st *RLState, now int64, credHash, coalesceKey string, bypassCoalesce bool) (Decision, *RLState) {
	ns := cloneState(st)
	if ns.V == 0 {
		ns.V = RLStateVersion
	}

	// 1) Cred-hash change: zero per-route / breaker / consecutive; preserve pause.
	if ns.CredHash != credHash {
		ns.CredHash = credHash
		ns.PerRoute = nil
		ns.BreakerOpenUntil = 0
		ns.ConsecutiveFailures = 0
		// GlobalPauseUntil preserved deliberately.
	}

	// 2) Deferred-flush check: any pending entry whose window has expired.
	for i := range ns.RecentTitles {
		e := &ns.RecentTitles[i]
		if e.PendingFlush && e.Ts+int64(CoalesceWindow) <= now {
			e.PendingFlush = false
			return DecisionDeferredFlushThenSend, ns
		}
	}

	// 3) Global pause.
	if ns.GlobalPauseUntil > now {
		return DecisionPauseSkip, ns
	}

	// 4) Breaker open.
	if ns.BreakerOpenUntil > now {
		return DecisionBreakerSkip, ns
	}

	// 6) Bypass coalesce (send-test) — don't touch ring.
	if bypassCoalesce {
		return DecisionSend, ns
	}

	// 5) Coalesce: scan ring for same hash within window.
	for i := range ns.RecentTitles {
		e := &ns.RecentTitles[i]
		if e.Hash == coalesceKey && e.Ts+int64(CoalesceWindow) > now {
			e.Count++
			e.PendingFlush = true
			return DecisionCoalesceSuppress, ns
		}
	}

	// Not in window — add fresh entry, evict oldest if over cap.
	ns.RecentTitles = append(ns.RecentTitles, CoalesceEntry{
		Hash:         coalesceKey,
		Ts:           now,
		Count:        1,
		PendingFlush: false,
	})
	if len(ns.RecentTitles) > RecentTitlesCap {
		ns.RecentTitles = ns.RecentTitles[len(ns.RecentTitles)-RecentTitlesCap:]
	}
	return DecisionSend, ns
}

// RecordSendResult updates breaker / pause based on the outcome of a send.
// On success: reset ConsecutiveFailures + BreakerOpenUntil.
// On failure: increment ConsecutiveFailures; if it crosses BreakerThreshold,
// open the breaker. If global=true (e.g. global rate-limit), set
// GlobalPauseUntil=now+retryAfterSec.
func RecordSendResult(st *RLState, now int64, success bool, retryAfterSec int, global bool) *RLState {
	ns := cloneState(st)
	if ns.V == 0 {
		ns.V = RLStateVersion
	}
	if success {
		ns.ConsecutiveFailures = 0
		ns.BreakerOpenUntil = 0
		return ns
	}
	ns.ConsecutiveFailures++
	if ns.ConsecutiveFailures >= BreakerThreshold {
		ns.BreakerOpenUntil = now + int64(BreakerOpenDuration)
	}
	if global && retryAfterSec > 0 {
		ns.GlobalPauseUntil = now + int64(retryAfterSec)
	}
	return ns
}

// ResetBreaker zeros ConsecutiveFailures + BreakerOpenUntil (manual recovery).
func ResetBreaker(st *RLState) *RLState {
	ns := cloneState(st)
	ns.ConsecutiveFailures = 0
	ns.BreakerOpenUntil = 0
	return ns
}
