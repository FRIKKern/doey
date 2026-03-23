# Hook Scripts Audit Report

**Date:** 2026-03-23 (consolidated — pass 1 + pass 2)
**Scope:** All 12 files in `.claude/hooks/`
**Focus:** Race conditions, file locking, performance, error handling, bash 3.2 compatibility

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 4 |
| MEDIUM | 8 |
| LOW | 8 |

---

## HIGH

### [HIGH] watchdog-scan.sh:200 — Dead variable `pane_output`: wasted tmux IPC per pane per cycle

Line 200 captures `tmux capture-pane -S -30` into `pane_output`, but this variable is never referenced. Lines 232 and 322 perform separate captures (`-S -5`). That's 3 tmux subprocesses per worker pane per scan cycle when 1 suffices.

```bash
# Current (line 200 — UNUSED):
pane_output=$(tmux capture-pane -t "$PANE_REF" -p -S -30 2>/dev/null) || pane_output=""
```

Suggested: Remove line 200 entirely. Consolidate lines 232 and 322 into a single capture reused for boot detection, hash comparison, and tool extraction.

---

### [HIGH] watchdog-scan.sh:232,322 — Redundant pane captures: `_boot_capture` and `CAPTURE` are identical

Both capture the same pane with `-S -5`. Combined with line 200 (unused), this means 3 captures per pane instead of 1.

```bash
# Lines 232 and 322 both do:
tmux capture-pane -t "$PANE_REF" -p -S -5 2>/dev/null
```

Suggested: Capture once at the top of the loop iteration, reuse everywhere.

---

### [HIGH] stop-results.sh:29 — Wrong env source: `DOEY_TEAM_DIR` not in tmux session env

```bash
# Current:
PROJECT_DIR=$(tmux show-environment DOEY_TEAM_DIR 2>/dev/null | cut -d= -f2-) || PROJECT_DIR=""
```

`DOEY_TEAM_DIR` is exported via `CLAUDE_ENV_FILE` (process env), NOT `tmux set-environment`. `tmux show-environment` won't find it, so `PROJECT_DIR` is always empty → `FILES_LIST` always empty → `files_changed` in result JSON always `[]`.

```bash
# Suggested:
PROJECT_DIR="${DOEY_TEAM_DIR:-}"
```

---

### [HIGH] common.sh:44 — `_read_team_key` truncates values containing `=`

```bash
# Current:
val=$(grep "^$2=" "$1" | cut -d= -f2)
```

`cut -d= -f2` returns only the second field. Values like `WORKTREE_DIR=/path/to/x=y` are silently truncated. Compare with `_env_val` in `on-session-start.sh:15` which correctly uses `-f2-`.

```bash
# Suggested:
val=$(grep "^$2=" "$1" | cut -d= -f2-)
```

Called by `is_watchdog`, `is_manager`, `get_sm_pane`, and `stop-notify.sh`.

---

## MEDIUM

### [MEDIUM] on-session-start.sh:78-94 — Stale lock on abnormal termination

`mkdir` lock for skill sync cleaned only via `trap EXIT`. SIGKILL cannot be trapped. If process killed during sync, `.skill_sync_lock` persists → all future sessions sleep 1s and skip sync.

```
Suggested: Check lock age: find "$LOCK_DIR" -mmin +5 → rmdir stale lock.
```

---

### [MEDIUM] on-session-start.sh:92-93 — Lock contention silently skips skill sync

```bash
# Current:
else sleep 1; fi
```

If lock is held, waits 1s and exits without syncing. No retry, no warning.

```
Suggested: Retry 2-3 times with 1s sleep, or log to doey-warnings.log.
```

---

### [MEDIUM] on-pre-tool-use.sh:86 — Slow path redundantly invokes `init_hook` for watchdog

```bash
# Current:
source "$(dirname "$0")/common.sh"
echo "$INPUT" | init_hook
```

The role file was already read on lines 17-26, and RUNTIME_DIR/PANE info is available. `init_hook` re-derives everything with 4+ tmux subprocesses. This is the PreToolUse hook — runs before EVERY tool call.

```
Suggested: For watchdog path, derive only needed fields from already-known values.
```

---

### [MEDIUM] common.sh:36-38 — `parse_field` grep fallback truncates on escaped quotes

```bash
grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
```

Breaks on values containing `\"`. E.g., `"command": "echo \"hello\""` truncates. Mitigated by jq being the primary path.

---

### [MEDIUM] stop-results.sh:35-43 — `_tmpfile` not covered by EXIT trap

Non-`timeout` fallback creates `_tmpfile=$(mktemp)` but the trap on line 14 only cleans `$TMPFILE`. If killed between lines 35-43, temp file leaks.

```
Suggested: Add _tmpfile to the EXIT trap.
```

---

### [MEDIUM] session-manager-wait.sh:6 — Sources session.env as executable shell code

```bash
source "${RUNTIME_DIR}/session.env"
```

If corrupted, arbitrary code runs. `on-session-start.sh` correctly uses `while IFS='=' read` for the same file — inconsistent.

```bash
# Suggested: Use read-loop parsing (like on-session-start.sh:19-26)
```

---

### [MEDIUM] common.sh:122-127 — Non-atomic write for notification cooldown file

```bash
echo "$now" > "$cooldown_file"
```

Direct write without tmp+mv. Low probability race since session manager is single-pane.

---

### [MEDIUM] watchdog-scan.sh:528 — Extra tmux capture-pane per anomaly event

For each anomaly in the post-scan persistence block, another `tmux capture-pane` is called despite the pane already being captured during the scan loop.

```
Suggested: Cache capture results during scan phase for reuse.
```

---

## LOW

### [LOW] watchdog-scan.sh:223,329,381,399-402,484-494 — Redundant numeric guards

`is_numeric "$i"` at loop entry (line 183/399) is followed by ~15 `case "$i" in *[!0-9]*) continue` guards. All dead code.

```
Suggested: Remove redundant case guards; loop-top is_numeric suffices.
```

---

### [LOW] on-session-start.sh:20, watchdog-scan.sh:86,103,457 — Misleading `&&` between assignments

`value="${value%\"}" && value="${value#\"}"` — parameter expansion never fails, so `&&` reads as conditional but always executes both. Use `;` or separate lines.

---

### [LOW] on-prompt-submit.sh:11-15, stop-status.sh:21-25 — No trap for mktemp cleanup

Both use mktemp for atomic writes but set no EXIT trap. Temp files leak if killed between mktemp and mv.

```
Suggested: Use deterministic temp name (e.g., ${STATUS_FILE}.tmp) like watchdog-scan does.
```

---

### [LOW] common.sh:130-136 — Background notification processes not waited

`osascript` and `notify-send` launched with `&` but never waited/reaped. Creates brief zombie entries.

---

### [LOW] stop-results.sh:20-24 — Tool count from screen scraping is unreliable

Counting tool calls by pattern-matching captured output is fragile. Undercounts if output scrolls beyond the 80-line capture window.

---

### [LOW] stop-notify.sh:23 — Message file uniqueness relies on timestamp+PID

`timestamp="$(date +%s)_$$"` — theoretical collision if same PID generates two messages in same second.

---

### [LOW] watchdog-scan.sh:120-131 — JSON parsing via sed is fragile

`sed 's/[{}"]//g' | tr ',' '\n'` works only for the specific `{"N":"STATE"}` format. Currently safe (self-generated JSON) but any format change breaks silently.

---

### [LOW] watchdog-wait.sh:9-11 — TOCTOU on trigger file

Check-then-delete race: trigger created between `[ -f "$TRIGGER" ]` and `rm -f` is lost. Benign since watchdog is single-threaded.

---

## Bash 3.2 Compatibility

All 12 hook scripts checked. **No violations found.**

Features verified absent: `declare -A/-n/-l/-u`, `printf '%(%s)T'`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `BASH_REMATCH`.
Features present and safe: `printf -v` (bash 3.1+), `+=` string concatenation (bash 3.1+), substring `${var:offset:length}`.

---

## Exit Code Correctness

| Hook | Expected | Actual | Correct? |
|------|----------|--------|----------|
| common.sh | N/A (sourced) | N/A | N/A |
| on-pre-compact.sh | 0 (output only) | 0 | Yes |
| on-pre-tool-use.sh | 0=allow, 2=block | 0 or 2 | Yes |
| on-prompt-submit.sh | 0 (always) | 0 | Yes |
| on-session-start.sh | 0 (always) | 0 | Yes |
| post-tool-lint.sh | 0 + JSON decision | 0 | Yes |
| session-manager-wait.sh | 0 (always) | 0 | Yes |
| stop-notify.sh | 0 (always) | 0 | Yes |
| stop-results.sh | 0 (always) | 0 | Yes |
| stop-status.sh | 0 or 2 (research block) | 0 or 2 | Yes |
| watchdog-scan.sh | 0 (always) | 0 | Yes |
| watchdog-wait.sh | 0 (always) | 0 | Yes |

---

## Race Conditions & Concurrency Summary

| Pattern | Used By | Assessment |
|---------|---------|------------|
| Atomic write (tmp+mv) | stop-results, stop-status, on-prompt-submit, watchdog-scan | Correct |
| Directory lock (mkdir) | on-session-start (skill sync) | Correct, minor stale-lock risk |
| File-based triggers | watchdog-wait, session-manager-wait | Correct, TOCTOU gap benign |
| Status file reads without locking | All hooks reading `.status` files | Acceptable — atomic writes prevent partial reads |

---

## Top Priorities

1. **Fix watchdog-scan.sh redundant captures** (HIGH ×2) — biggest perf win, saves 2+ tmux subprocesses per pane per scan cycle
2. **Fix stop-results.sh wrong env source** (HIGH) — `files_changed` always empty due to this bug
3. **Fix common.sh `_read_team_key` truncation** (HIGH) — silent data corruption on values with `=`
4. **Optimize on-pre-tool-use.sh watchdog slow path** (MEDIUM) — unnecessary init_hook in hot path

---

## Positive Patterns Observed

1. Atomic writes via tmp+mv used consistently
2. Graceful degradation: jq-with-grep-fallback throughout
3. Role caching: `is_watchdog()`/`is_manager()` results cached
4. Trap cleanup in stop-results.sh
5. Early exits for non-Doey sessions
6. Zero bash 3.2 violations across all 12 scripts
7. Hot path optimization: on-pre-tool-use.sh has dedicated fast paths for workers and managers
