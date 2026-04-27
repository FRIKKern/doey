package planview

import "context"

// Demo is the read-only Source backed by a fixture directory. It is used
// for screenshots, golden-file tests, and offline demos. Phase 4
// implements the fixture loader; Phase 1 returns ErrNotImplemented.
type Demo struct {
	fixtureDir string
}

// NewDemo constructs a Demo source bound to fixtureDir. Returns
// ErrNotImplemented when fixtureDir is empty so callers do not silently
// produce empty Snapshots.
//
// TODO Phase 4: load fixtures from
// <fixtureDir>/{plan.md,consensus.state,verdicts/*,research/*,status/*,team.env}
// at construction time and surface parse errors here.
func NewDemo(fixtureDir string) (*Demo, error) {
	if fixtureDir == "" {
		return nil, ErrNotImplemented
	}
	return &Demo{fixtureDir: fixtureDir}, nil
}

// Read returns the fixture Snapshot. Phase 1 returns ErrNotImplemented.
func (d *Demo) Read(ctx context.Context) (Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	// TODO Phase 4: return the snapshot loaded by NewDemo.
	return Snapshot{}, ErrNotImplemented
}

// Updates returns nil. Demo fixtures are static — ranging over a nil
// channel blocks forever, which is the contract callers expect.
func (d *Demo) Updates() <-chan Snapshot {
	return nil
}

// Close releases fixture handles. Phase 1: no-op.
func (d *Demo) Close() error {
	return nil
}
