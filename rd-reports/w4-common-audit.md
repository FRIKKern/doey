# W4 Audit: common.sh & on-session-start.sh

**Date:** 2026-03-24
**Scope:** Read-only analysis of hook foundation files

---

## 1. `_log()` Function

### Signature
```bash
_log() {
  local msg="$1"
  ...
}
```

**Parameters:** Single positional arg — the log message string (no level/severity concept).

### Behavior
1. Reads `DOEY_PANE_ID` (env var set by on-session-start.sh) to name the log file.
   Falls back to literal `unknown` if unset.
2. Log file path: `${RUNTIME_DIR}/logs/${pane_id}.log`
   Example: `/tmp/doey/myproject/logs/t1-w2.log`
3. **Rotation:** Before writing, checks file size with `wc -c`. If > 512 000 bytes (~500 KB), truncates to last 200 lines via `tail -200 > .tmp && mv`.
4. **Write format:** `[2026-03-24T14:05:00] <msg>` — timestamp + message, newline-terminated.
   Uses `printf '[%s] %s\n'`; appends with `>>` — never truncates.
5. All I/O errors suppressed (`2>/dev/null`), so `_log()` is **non-fatal**.

### Callers
- Not called inside `common.sh` or `on-session-start.sh` themselves.
- Intended to be called by any hook that sources `common.sh` after `init_hook()`.
- `init_hook()` calls `_ensure_dirs` which creates the `logs/` subdirectory.

### Gaps / Limitations
- **No severity level** — all messages are uniform; no ERROR vs INFO distinction.
- Log file is per-pane; there is no shared/aggregate error log.
- Rotation is "last 200 lines" only — older context is silently dropped.
- `DOEY_PANE_ID` must be set externally (by `on-session-start.sh`) before `_log()` is useful; if called before session start it logs to `unknown.log`.

---

## 2. DOEY_* Environment Variables (set by on-session-start.sh)

All variables are injected into `$CLAUDE_ENV_FILE` via `cat >>` heredoc. They become shell environment variables inside the Claude Code process.

| Variable | Source / How Derived | Example Value | Always Set? |
|----------|---------------------|---------------|-------------|
| `DOEY_RUNTIME` | `tmux show-environment DOEY_RUNTIME` — the runtime directory path | `/tmp/doey/myproject` | Yes (script exits if missing) |
| `SESSION_NAME` | Read from `session.env` `SESSION_NAME=` key | `doey-myproject` | Yes |
| `PROJECT_DIR` | Read from `session.env` `PROJECT_DIR=` key | `/Users/pelle/Documents/github/myproject` | Yes |
| `PROJECT_NAME` | Read from `session.env` `PROJECT_NAME=` key | `myproject` | Yes |
| `DOEY_ROLE` | Computed from pane position vs `session.env`/`team_N.env` | `worker`, `manager`, `watchdog`, `session_manager`, `info_panel`, `git_agent` | Yes |
| `DOEY_PANE_INDEX` | Tmux `#{pane_index}` of this pane | `2` | Yes |
| `DOEY_WINDOW_INDEX` | Tmux `#{window_index}` of this pane | `1` | Yes |
| `DOEY_TEAM_WINDOW` | Same as WINDOW_INDEX for most roles; for watchdogs it's the team window they watch (from `team_N.env` filename) | `1` | Yes |
| `DOEY_TEAM_DIR` | `WORKTREE_DIR` from `team_N.env` if set, else `PROJECT_DIR` | `/tmp/doey/myproject/worktrees/branch-name` | Yes (falls back to PROJECT_DIR) |
| `DOEY_PROJECT_ACRONYM` | `PROJECT_ACRONYM` from `session.env`, else derived: first char of each hyphen-segment of PROJECT_NAME, max 4 chars | `mp` | Yes |
| `DOEY_PANE_ID` | Short ID: `sm`, `info`, `t1-mgr`, `t1-wd`, `t1-git`, `t1-w2`, `t1-f2` | `t1-w2` | Yes |
| `DOEY_FULL_PANE_ID` | `${PROJECT_ACRONYM}-${PANE_ID}` | `mp-t1-w2` | Yes |

### Role Values and When Set
- `session_manager` — window 0, pane matches `SM_PANE` in `session.env`
- `info_panel` — window 0, pane index 0
- `watchdog` — window 0, pane matches `WATCHDOG_PANE` in any `team_N.env`
- `manager` — non-zero window, pane index matches `MANAGER_PANE` in `team_N.env`
- `git_agent` — non-zero window, freelancer team, role_override file = `git_agent`
- `worker` — all other non-zero window panes (default)

### Conditionally Set
- `DOEY_TEAM_DIR` uses worktree path only when `WORKTREE_DIR` is present in `team_N.env`; otherwise equals `PROJECT_DIR`.
- `DOEY_PROJECT_ACRONYM` falls back to computed value if not in `session.env`.

---

## 3. Utility Functions in common.sh Relevant to Error Logging

### `init_hook()` (lines 6–23)
Sets up the runtime context required for any hook function:
- Reads `INPUT` from stdin if not already set
- Extracts `RUNTIME_DIR` from tmux environment
- Resolves `PANE`, `PANE_SAFE`, `SESSION_NAME`, `PANE_INDEX`, `WINDOW_INDEX`
- Sets `NOW` timestamp
- Calls `_ensure_dirs` (creates `logs/`, `status/`, etc.)

**Relevance:** Must be called before `_log()` to have `RUNTIME_DIR` available. Any `_log_error()` should also require `init_hook()` to have run.

### `_ensure_dirs()` (lines 25–29)
Creates subdirectories: `status`, `research`, `reports`, `results`, `messages`, `logs`.
Uses sentinel file `.dirs_created` to avoid redundant mkdir calls.

**Relevance:** Guarantees the `logs/` directory exists. No changes needed for error logging.

### `parse_field()` (lines 46–53)
Extracts a JSON field from `$INPUT` using `jq` (preferred) or grep+sed fallback.

**Relevance:** Not directly relevant to error logging, but useful in hooks that want to log tool names or parameters.

### `_read_team_key()` (lines 55–60)
Reads a key=value pair from a `.env` file.
Usage: `_read_team_key <file> <key>`

**Relevance:** Used by role-detection functions. `_log_error()` could use this pattern for structured metadata lookups.

### `is_watchdog()`, `is_manager()`, `is_session_manager()`, `is_worker()` (lines 62–93)
Cached role predicates. Each caches its result in a `_DOEY_IS_*` variable using `return 0/1` convention.

**Relevance:** A `_log_error()` function could include the detected role in the log entry for context, or error logging could be role-conditional (e.g., workers escalate errors to manager).

### `send_notification()` (lines 141–169)
Sends a desktop notification (macOS/Linux/Windows). Only fires when `is_session_manager` is true. Has a 60-second per-title cooldown enforced via a file in `status/`.

**Relevance:** For critical errors, `_log_error()` could optionally call `send_notification()` after logging — but only from session manager context, same as now.

### `atomic_write()` (line 124)
`printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"` — safe atomic replacement.

**Relevance:** Could be used by `_log_error()` if we ever want a "last error" sentinel file alongside the per-pane log.

### `write_pane_status()` (lines 128–134)
Writes a structured 4-line status file atomically.

**Relevance:** Pattern to follow for any structured error record file.

---

## 4. Best Insertion Point for `_log_error()`

**Recommended location:** Immediately after the existing `_log()` function, at **line 45** in `common.sh`.

### Rationale
- `_log()` ends at line 44. Inserting right after keeps logging functions grouped.
- `_log_error()` will naturally delegate to `_log()` with a prefixed message, so proximity aids readability.
- Both functions share the same dependencies (`RUNTIME_DIR`, `DOEY_PANE_ID`).

### Suggested Design (for implementer reference)
```bash
_log_error() {
  local msg="$1"
  local context="${2:-}"          # optional: calling hook name
  local entry="ERROR ${context:+[$context] }${msg}"
  _log "$entry"

  # Also append to shared error log for cross-pane visibility
  local err_log="${RUNTIME_DIR}/logs/errors.log"
  printf '[%s] [%s] %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" \
    "${DOEY_PANE_ID:-unknown}" \
    "$entry" >> "$err_log" 2>/dev/null
}
```

**Key differences from `_log()`:**
1. Prefixes message with `ERROR` so it's grep-able in per-pane logs.
2. Writes a duplicate entry to `logs/errors.log` (shared, not per-pane) — enables `tail -f errors.log` monitoring without knowing which pane errored.
3. `context` parameter allows callers to identify which hook triggered the error.
4. Does NOT call `send_notification()` by default — callers can do that selectively.

---

## 5. Summary

| Item | Key Finding |
|------|-------------|
| `_log()` log path | `$RUNTIME_DIR/logs/$DOEY_PANE_ID.log` |
| `_log()` format | `[ISO-timestamp] message` |
| `_log()` rotation | Truncate to last 200 lines when > 500 KB |
| `_log()` severity | None — single level only |
| DOEY_* vars always set | 12 variables always injected |
| DOEY_TEAM_DIR | Conditional: worktree path if set, else PROJECT_DIR |
| `_log_error()` insertion | After line 44 (after `_log()`) in common.sh |
| Shared error log opportunity | `logs/errors.log` — does not yet exist |
