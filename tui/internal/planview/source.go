package planview

import "context"

// Source is the abstraction the masterplan TUI model uses to obtain a
// Snapshot. Live and Demo both satisfy this interface, so the model
// never branches on which backend is active.
//
// Phase 1: Live calls Read once per tick (snapshot mode, equivalent to
// the legacy binary's behaviour). Phase 2 wires fsnotify watchers so
// Read becomes the read side of an event-driven cache and only blocks
// when the cache is cold.
//
// Demo is read-only: callers must short-circuit any write attempt
// (persist, runSendToTasks, DB writes) at the call site so a refactor
// cannot leak a write path through the watcher boundary. Phase 4
// implements the fixture loader; Phase 1 returns ErrNotImplemented.
type Source interface {
	// Read returns the current Snapshot. The returned Snapshot is a
	// value type and may be retained by the caller without further
	// synchronisation.
	Read(ctx context.Context) (Snapshot, error)
	// Close releases any watchers, file handles, or background
	// goroutines held by the Source. Calling Close on a never-started
	// Source is a no-op.
	Close() error
}
