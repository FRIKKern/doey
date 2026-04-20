// Package discord implements Doey's Discord notification state machine,
// failure log, and bind helper. It is pure persistence + decision logic —
// no HTTP or send logic lives here. Higher-level packages (Phase 3+)
// call into this package to decide whether to send, coalesce, or skip a
// notification and to record failures.
package discord

// FailedLogMaxEntries is the soft cap on discord-failed.jsonl line count.
// When exceeded, the next append triggers a lazy prune OR the user must run
// `doey discord failures --prune`. Single source of truth — masterplan line 259.
const FailedLogMaxEntries = 200

// RLStateVersion is the current schema version for discord-rl.state.
const RLStateVersion = 1

// FailedLogVersion is the current schema version for discord-failed.jsonl lines.
const FailedLogVersion = 1

// RecentTitlesCap is the ring buffer cap for coalesce bucket (ADR-8, line 71).
const RecentTitlesCap = 32

// CoalesceWindow is the 30-second duplicate-burst window (ADR-8, line 72).
const CoalesceWindow = 30 // seconds

// BreakerThreshold — open breaker after N consecutive failures.
const BreakerThreshold = 5

// BreakerOpenDuration — seconds the breaker stays open.
const BreakerOpenDuration = 120

// FailedLogMaxLineBytes — single O_APPEND write size cap under POSIX PIPE_BUF
// atomicity guarantee (masterplan line 210).
const FailedLogMaxLineBytes = 4096
