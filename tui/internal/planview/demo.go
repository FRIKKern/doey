package planview

import (
	"context"
	"fmt"
)

// Demo is the read-only Source backed by a fixture directory. It is
// used for screenshots, golden-file tests, and offline demos. NewDemo
// loads the entire fixture eagerly and caches the resulting Snapshot;
// Read returns the cached value with no I/O. Updates returns nil
// (static fixtures never change). Close is a no-op.
//
// Demo deliberately offers no write surface — see DECISIONS.md D6.
// Write short-circuiting lives at the model's call sites (persist,
// runSendToTasks, any DB write) so a future refactor cannot leak a
// write path through the Source boundary.
type Demo struct {
	fixtureDir string
	snapshot  Snapshot
}

// NewDemo loads the fixture directory and returns a Demo bound to its
// cached Snapshot. Returns an error when fixtureDir is empty or when
// LoadFixture fails (missing or unparseable plan.md). The returned
// Demo's Read never returns an error: the snapshot is fully resolved
// at construction time.
func NewDemo(fixtureDir string) (*Demo, error) {
	if fixtureDir == "" {
		return nil, fmt.Errorf("planview: NewDemo requires a non-empty fixtureDir")
	}
	snap, err := LoadFixture(fixtureDir)
	if err != nil {
		return nil, err
	}
	return &Demo{fixtureDir: fixtureDir, snapshot: snap}, nil
}

// Read returns the cached fixture Snapshot. Honours ctx cancellation
// but performs no I/O — the snapshot was loaded by NewDemo.
func (d *Demo) Read(ctx context.Context) (Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	return d.snapshot, nil
}

// Updates returns nil. Demo fixtures are static — ranging over a nil
// channel blocks forever, which is the contract callers expect.
func (d *Demo) Updates() <-chan Snapshot {
	return nil
}

// Close is a no-op. Idempotent — safe to call multiple times.
func (d *Demo) Close() error {
	return nil
}

// FixtureDir returns the directory the Demo was loaded from. Useful
// for footer display ("demo: <scenario>") in the model.
func (d *Demo) FixtureDir() string {
	return d.fixtureDir
}
