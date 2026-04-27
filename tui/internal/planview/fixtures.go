package planview

import "errors"

// ErrNotImplemented is returned by Phase-1 stubs whose real
// implementation lands in a later phase of masterplan
// 20260426-203854. Callers should treat ErrNotImplemented as a soft
// failure and fall back to whatever the legacy code path did.
var ErrNotImplemented = errors.New("planview: not yet implemented (Phase 4)")

// LoadFixture loads a frozen Snapshot from a fixture directory laid out
// as:
//
//	<dir>/plan.md
//	<dir>/consensus.state
//	<dir>/verdicts/<role>.md
//	<dir>/research/<n>.md
//	<dir>/status/<pane>.status
//	<dir>/team.env
//
// Phase 4 implements the loader; Phase 1 returns ErrNotImplemented.
//
// TODO Phase 4: parse fixture tree into Snapshot.
func LoadFixture(dir string) (Snapshot, error) {
	_ = dir
	return Snapshot{}, ErrNotImplemented
}
