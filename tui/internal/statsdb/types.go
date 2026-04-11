// Package statsdb is the persistent writer for `.doey/stats.db` — the
// per-project aggregated telemetry store. It is strictly separate from
// tui/internal/store (the ephemeral runtime IPC/event log at
// ${DOEY_RUNTIME}/store.db); there are no cross-writes between them.
//
// Phase 1 scope: schema bootstrap, PRAGMA setup, single-row Emit. Readers
// live in tui/internal/stats (Phase 4). Task #525 owns the `violations`
// table in this same DB file — schema bootstrap here must be idempotent
// and must not DROP anything.
package statsdb

// SchemaVersion is the current stats.db schema version recorded in
// schema_meta. Bumped via an ALTER/CREATE-guarded migration when fields
// change; callers should never depend on a specific value.
const SchemaVersion = 1

// Event is the wire-shape for a single stats row. Payload keys must be
// drawn from the allow-list in shell/doey-stats-allowlist.txt (enforced
// upstream in the emitter, not re-validated here).
type Event struct {
	Timestamp int64             // unix millis
	Category  string            // session | task | worker | skill
	Type      string            // e.g. session_start, task_completed
	SessionID string            // stable UUID from session.env
	Project   string            // canonical project path
	Payload   map[string]string // allow-listed keys only
}

// Mode selects how Open will configure the underlying sql.DB. Phase 1
// only exercises ModeRW; the reader package in Phase 4 uses a different
// DSN and does not go through this package.
type Mode int

const (
	// ModeRW opens the database read-write with WAL journaling enabled.
	// The parent directory is created if missing.
	ModeRW Mode = iota
	// ModeRO opens the database read-only with query_only=1. Reserved
	// for Phase 4 integrations; Phase 1 callers should use ModeRW.
	ModeRO
)
