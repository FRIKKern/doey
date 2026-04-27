package planview

import (
	"context"
	"time"
)

// Source is the abstraction the masterplan TUI model uses to obtain a
// Snapshot. Live and Demo both satisfy this interface, so the model
// never branches on which backend is active.
//
// Phase 2 wires fsnotify watchers so Live emits a fresh Snapshot down
// Updates() whenever a watched signal changes (after debounce + atomic
// rendezvous). Read still works as a synchronous one-shot snapshot
// read for the Init path and the legacy mode.
//
// Demo is read-only: callers must short-circuit any write attempt
// (persist, runSendToTasks, DB writes) at the call site so a refactor
// cannot leak a write path through the watcher boundary. Phase 4
// implements the fixture loader; Phase 1 returns ErrNotImplemented.
type Source interface {
	// Read returns the current Snapshot. The returned Snapshot is a
	// value type and may be retained by the caller without further
	// synchronisation. Read always re-loads from disk; the cached
	// Snapshot is only an optimisation for Updates() coalescing.
	Read(ctx context.Context) (Snapshot, error)
	// Updates returns a channel that emits a fresh Snapshot whenever
	// any watched signal changes. The channel is buffered with capacity
	// 1; if a previous Snapshot has not been consumed the implementation
	// coalesces by overwriting (drop-oldest) so the receiver always sees
	// the latest state. The same channel is returned for the lifetime
	// of the Source — callers may range over it.
	//
	// Live: returns a non-nil channel populated by the fsnotify
	// watcher goroutine. In legacy mode (NewLiveLegacy) this returns
	// nil. Demo: returns nil — ranging a nil channel blocks forever,
	// which is the desired behaviour for static fixtures.
	Updates() <-chan Snapshot
	// WorkerStatuses returns the live activity status of every worker
	// pane bound to the given plan. The planID is the SQLite plans-row
	// key; implementations may ignore it when their team binding is
	// already pinned (Live carries the team window in its receiver,
	// Demo loads from a fixture). Soft-fails: a missing status tree
	// yields a nil slice, not an error.
	//
	// Phase 8 Track B uses this to drive RenderWorkerTicker — the
	// activity strip that lives next to the research index pillar.
	WorkerStatuses(planID int64) ([]WorkerStatus, error)
	// Close releases any watchers, file handles, or background
	// goroutines held by the Source. Calling Close on a never-started
	// Source is a no-op. After Close the Updates channel is closed.
	Close() error
}

// WorkerStatus is the compact, render-ready row used by the worker
// activity ticker pillar. It carries the minimum identity + state
// fields the renderer needs and is intentionally narrower than the
// internal WorkerRow (no PaneIndex, no StallAge) so future Source
// implementations can populate it from non-tmux backends.
//
// PaneSafe doubles as the row's display label and matches the
// `tr ':.-' '_'` encoding used by the on-disk status file basename.
type WorkerStatus struct {
	PaneSafe     string        // PANE_SAFE identifier (display label)
	Status       string        // STATUS field — BUSY / READY / FINISHED / RESERVED / ERROR / UNKNOWN
	Activity     string        // free-text activity hint, "" when none
	HeartbeatAge time.Duration // age of the most recent heartbeat write
	HasUnread    bool          // true when an unread sentinel exists for this pane
	Reserved     bool          // mirrors Status == RESERVED, hoisted for convenience
}

// workerRowsToStatuses converts the internal []WorkerRow that the
// snapshot loaders already populate into the public []WorkerStatus
// surface. The conversion is total — every row produces exactly one
// status — so live and demo Sources can share the projection.
//
// PaneSafe is sourced from the row's PaneIndex. Live populates
// PaneIndex with the dotted form (`<window>.<pane>`); Demo uses the
// fixture filename basename. Both are stable identifiers within their
// scope and round-trip cleanly through the renderer.
func workerRowsToStatuses(rows []WorkerRow) []WorkerStatus {
	if len(rows) == 0 {
		return nil
	}
	out := make([]WorkerStatus, 0, len(rows))
	for _, r := range rows {
		out = append(out, WorkerStatus{
			PaneSafe:     r.PaneIndex,
			Status:       r.Status,
			Activity:     r.Activity,
			HeartbeatAge: r.HeartbeatAge,
			HasUnread:    r.HasUnread,
			Reserved:     r.Reserved,
		})
	}
	return out
}
