// Package planview provides the data shape and source abstraction used by
// the masterplan TUI binary. A Source produces a Snapshot that bundles the
// parsed Plan with every live signal the viewer can render — consensus
// state, reviewer verdicts, research index, worker status rows, and the
// active task footer. Two implementations satisfy the interface: Live
// (reads from the project runtime tree on demand and — in Phase 2 — via
// fsnotify watchers) and Demo (loads a frozen fixture directory for
// screenshots and tests). Both feed the same Snapshot shape, so the model
// in cmd/doey-masterplan-tui never branches on which backend is active.
//
// # APPROVED vs CONSENSUS gate aliasing
//
// The Send-to-Tasks gate accepts both APPROVED and CONSENSUS
// (case-insensitive). The badge palette renders either as ✓ CONSENSUS.
// Historical inconsistency between shell consensus.state (CONSENSUS) and
// reviewer verdict files (APPROVE) is reconciled by treating them as
// semantically equivalent. IsConsensusReached is the single source of
// truth — every gate, badge, and tooltip routes through it instead of
// comparing strings directly.
package planview
