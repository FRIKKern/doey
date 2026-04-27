package planview

import "context"

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
	// Close releases any watchers, file handles, or background
	// goroutines held by the Source. Calling Close on a never-started
	// Source is a no-op. After Close the Updates channel is closed.
	Close() error
}
