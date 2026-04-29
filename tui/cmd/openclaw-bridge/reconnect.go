package main

import (
	"context"
	"fmt"
	"log"
	"os/exec"
	"sync"
)

// ReconnectHandler runs a daemon-version smoke check whenever the poller
// transitions from a failed state back to a healthy one. The startup
// version is captured at bridge boot from .doey/openclaw-binding; on
// every reconnect the binding is re-read so that an out-of-band
// /doey-openclaw-connect (which rewrites the binding) surfaces as a
// version mismatch on the next poll-recover edge.
//
// The handler does NOT hard-fail on mismatch — it logs, surfaces a
// dashboard hint, and shells out to `doey openclaw reconnect-status`
// which dedup-creates a single status task across reconnect cycles.
type ReconnectHandler struct {
	ProjectDir     string
	StartupVersion string
	MinRequired    string
	dashboard      *Dashboard
	mu             sync.Mutex
	count          int
}

func NewReconnectHandler(projectDir string, dash *Dashboard) *ReconnectHandler {
	h := &ReconnectHandler{ProjectDir: projectDir, dashboard: dash}
	if b, err := LoadBinding(projectDir); err == nil {
		h.StartupVersion = b.RecordedDaemonVersion
		h.MinRequired = b.MinRequiredVersion
	}
	return h
}

// SmokeResult is the structured outcome of a reconnect smoke check.
type SmokeResult struct {
	Count    int
	Expected string
	Observed string
	Mismatch bool
}

// Probe re-reads the binding and compares the recorded daemon version
// against the version captured at bridge startup. Pure: no IO besides
// the binding read; safe to call from tests.
func (r *ReconnectHandler) Probe() SmokeResult {
	if r == nil {
		return SmokeResult{}
	}
	r.mu.Lock()
	r.count++
	n := r.count
	r.mu.Unlock()

	expected := r.StartupVersion
	observed := expected
	if b, err := LoadBinding(r.ProjectDir); err == nil {
		observed = b.RecordedDaemonVersion
	}
	mismatch := expected != "" && observed != "" && expected != observed
	return SmokeResult{Count: n, Expected: expected, Observed: observed, Mismatch: mismatch}
}

// OnReconnect runs the smoke probe and, best-effort, dispatches the
// status-task helper. Failures are logged and swallowed — reconnect
// recovery must never be blocked by a missing CLI.
func (r *ReconnectHandler) OnReconnect(ctx context.Context) {
	if r == nil {
		return
	}
	res := r.Probe()
	log.Printf("reconnect smoke #%d: expected=%q observed=%q mismatch=%v",
		res.Count, res.Expected, res.Observed, res.Mismatch)

	if res.Mismatch && r.dashboard != nil {
		_ = r.dashboard.WriteStuck("version_mismatch",
			fmt.Sprintf("daemon version changed: %s → %s", res.Expected, res.Observed),
			0)
	}

	body := fmt.Sprintf("reconnect=%d expected=%s observed=%s mismatch=%v",
		res.Count,
		valueOr(res.Expected, "(unknown)"),
		valueOr(res.Observed, "(unknown)"),
		res.Mismatch)

	cmd := exec.CommandContext(ctx, "doey", "openclaw", "reconnect-status",
		valueOr(res.Expected, "unknown"),
		valueOr(res.Observed, "unknown"),
		body)
	cmd.Dir = r.ProjectDir
	if out, err := cmd.CombinedOutput(); err != nil {
		log.Printf("reconnect-status helper failed: %v: %s", err, string(out))
	}
}

func valueOr(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
