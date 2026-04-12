# Stats System

Local-only operational metrics for Doey sessions. All data stays on disk — nothing is transmitted externally.

## What is collected

Event-based metrics emitted by hooks and shell scripts during a Doey session. Each event has a category, type, timestamp, session ID, and key-value payload filtered through the allowlist.

**Categories and example types:**

| Category | Types | Emitted by |
|----------|-------|------------|
| `session` | `session_start` | `on-session-start.sh` |
| `skill` | `install_run`, `skill_invoked`, `intent_fallback`, `masterplan_started` | `doey-stats-emit.sh`, `doey.sh`, `doey-intent-dispatch.sh` |
| `worker` | `tool_blocked`, `context_compacted`, `taskmaster_wake`, `reviewer_wake`, `team_killed` | `on-pre-tool-use.sh`, `on-pre-compact.sh`, wait hooks, `doey-team-mgmt.sh` |

## Privacy contract

All emitted payloads are filtered through a strict allowlist before storage. The allowlist lives in two byte-identical copies:

- `shell/doey-stats-allowlist.txt` (consumed by `shell/doey-stats.sh`)
- `tui/cmd/doey-ctl/doey-stats-allowlist.txt` (embedded via `go:embed` in `stats.go`)

**Allowed keys** (operational metrics only):

`role`, `window`, `pane`, `mode`, `status`, `task_id`, `files_changed`, `tool_count`, `version`, `origin`, `cmd`, `dep`, `mapped_cmd`, `team`, `team_type`, `worker_count`, `reason`, `duration_ms`, `exit_code`, `retry`

**Guarantees:**

- No PII: no usernames, emails, IP addresses, or file paths containing user-identifiable information
- No content: no code snippets, file contents, prompts, or responses
- Any key not in the allowlist is silently dropped before insert
- Both the shell emitter and Go ingest enforce the allowlist independently
- Storage is local only — `$PROJECT/.doey/stats.db` (SQLite). No network transmission

## Storage

Stats are stored in a per-project SQLite database:

```
$PROJECT/.doey/stats.db
```

Each event row contains: `id`, `session_id`, `timestamp`, `category`, `type`, and a JSON payload with only allowlisted keys.

The `session_id` is a UUID generated once per Doey session launch and stored at `${DOEY_RUNTIME}/session_id`. All panes in the same session share this ID for event grouping.

## How to opt out

Set the kill switch environment variable:

```bash
export DOEY_STATS=0
```

This can be set in:
- `~/.config/doey/config.sh` (global, all projects)
- `$PROJECT/.doey/config.sh` (per-project)
- Shell environment (per-session)

When `DOEY_STATS=0`, all emitters return immediately without writing. The `doey doctor` command reports the kill switch state.

## Querying stats

Use `doey doctor --stats-verbose` to view recent events and counters.

For direct queries via `doey-ctl`:

```bash
# Recent events (last 10)
doey-ctl stats query recent --project-dir . --limit 10

# Counters
doey-ctl stats query counters --project-dir .
```

## Adding new metrics

1. Add the key to `shell/doey-stats-allowlist.txt`
2. Copy the file byte-for-byte to `tui/cmd/doey-ctl/doey-stats-allowlist.txt`
3. Update the `_doey_stats_key_allowed` case statement in `shell/doey-stats.sh`
4. Emit via `doey-stats-emit.sh <category> <type> key=value`
5. Verify with `bash tests/test-bash-compat.sh`

New keys must be operational metrics only — no PII, no content, no file paths.

## Retention

Retention policy is deferred to a future task. Currently stats.db grows unbounded per project. A future implementation will add automatic pruning of events older than a configurable threshold.
