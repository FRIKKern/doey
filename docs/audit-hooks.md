# Hook Audit Report — .claude/hooks/
**Date:** 2026-03-23
**Auditor:** R&D Worker 3 (hook-audit_0323)
**Scope:** All 12 hook scripts + common.sh
**Method:** Static analysis — race conditions, file locking, performance, error handling, bash 3.2 compat, inter-hook interactions

---

## CRITICAL

### on-pre-tool-use.sh

**[CRITICAL] on-pre-tool-use.sh line:69 — `init_hook` runs in pipe subshell; all variable assignments lost**

```
Current:  echo "$INPUT" | init_hook
```

`init_hook` is on the right side of a pipe. In bash (including 3.2, without `lastpipe`), the right side of a pipe always executes in a subshell. All assignments made inside `init_hook` — `RUNTIME_DIR`, `PANE`, `WINDOW_INDEX`, `PANE_INDEX`, `PANE_SAFE`, `SESSION_NAME`, `NOW` — are discarded when the subshell exits. The subsequent calls to `is_manager` (line 71), `is_session_manager` (line 72), and `is_watchdog` (line 82) operate on **unset variables**, producing undefined behavior.

Impact: `is_watchdog` checks `[ "$WINDOW_INDEX" != "0" ]`; with `WINDOW_INDEX` unset, `"" != "0"` is true, so `is_watchdog` always returns 1 (not a watchdog). The Watchdog pane's special send-keys allowances (send to Manager pane, /compact, bare Enter) are **never applied**. The Watchdog is silently treated as a Worker, meaning its legitimate tmux send-keys operations are blocked by the Worker restriction at line 127.

---

## HIGH

### on-pre-tool-use.sh

**[HIGH] on-pre-tool-use.sh line:82 — Watchdog's send-keys allowances are never reached**

Consequence of the CRITICAL finding above. The block at lines 82–110 (`if is_watchdog; then`) is dead code for any pane that reaches the slow path. A Watchdog pane in the slow path hits the Worker-level `tmux send-keys` block (line 127) instead of the watchdog-specific logic. Legitimate watchdog actions such as sending `/compact` to a worker or `Enter` for recovery are incorrectly blocked.

---

**[HIGH] on-pre-tool-use.sh line:40 — Watchdog role excluded from early-exit fast paths**

```
Current:  case "$_DOEY_ROLE" in manager|session_manager) exit 0 ;; esac
```

`watchdog` is not included in the early-exit list. When `_DOEY_ROLE="watchdog"`, the script falls through to the slow path (lines 67–133), triggering the broken pipe-subshell init_hook. Managers and Session Managers exit immediately and safely; watchdogs do not.

---

### stop-notify.sh

**[HIGH] stop-notify.sh line:75-76 — Manager→SM notification depends on stop hook execution order**

```
Current:  _cur=$(grep '^STATUS:' "$STATUS_FILE" ...)
          [ "${_cur#STATUS: }" = "BUSY" ] || exit 0
```

`stop-notify.sh` checks that the Manager's status is `BUSY` before sending the Session Manager notification. `stop-status.sh` also runs on the same stop event and writes `READY` to the same status file. If hooks run sequentially in alphabetical order (`stop-notify` before `stop-status`), the BUSY value is read correctly. If hooks run in parallel or reverse order, `stop-status.sh` may overwrite `BUSY` → `READY` before `stop-notify.sh` reads it, silently dropping the Manager→Session Manager notification. No ordering guarantee is documented or enforced.

---

### on-session-start.sh

**[HIGH] on-session-start.sh line:77-94 — Skill sync lock can leak on SIGKILL, blocking all future session starts**

```
Current:  LOCK_DIR="${RUNTIME_DIR}/.skill_sync_lock"
          if mkdir "$LOCK_DIR" 2>/dev/null; then
            trap '_skill_lock_cleanup' EXIT
            ...
            rmdir "$LOCK_DIR" 2>/dev/null || true
            trap - EXIT
          else
            sleep 1
          fi
```

`mkdir` is used as a lock (correct). The EXIT trap cleans up on normal exit. However, `SIGKILL` bypasses EXIT traps. If a session start process is killed mid-sync, `$LOCK_DIR` remains. All subsequent session starts see the existing lock, hit `sleep 1`, and skip skill sync **permanently** until the lock is manually removed. No staleness check (e.g., check lock mtime) or timeout is implemented.

---

## MEDIUM

### common.sh

**[MEDIUM] common.sh line:123-126 — `send_notification` cooldown is not atomically read-modify-written**

```
Current:  last_sent=$(cat "$cooldown_file" 2>/dev/null) || last_sent=0
          now=$(date +%s)
          [ "$((now - last_sent))" -lt 60 ] && return 0
          echo "$now" > "$cooldown_file" 2>/dev/null || true
```

Two concurrent stop hooks (e.g., two workers finishing at the same second) both call `send_notification`. Both read the cooldown file before either writes the new timestamp. Both pass the 60-second check. Both send a desktop notification. Non-atomic read-then-write race. Should use an `mv`-based atomic write or lock.

**[MEDIUM] common.sh line:26-31 — `_ensure_dirs` sentinel TOCTOU race**

```
Current:  [ -f "${RUNTIME_DIR}/.dirs_created" ] && return 0
          if [ ! -d ... ]; then mkdir -p ... fi
          touch "${RUNTIME_DIR}/.dirs_created"
```

Multiple hooks starting concurrently (session start for several panes) can all fail the sentinel check before any writes it, then all call `mkdir -p`. `mkdir -p` is idempotent so this is benign, but the sentinel itself is not written atomically. Low real-world impact since `mkdir -p` is safe, but the sentinel's purpose is defeated.

---

### on-pre-tool-use.sh

**[MEDIUM] on-pre-tool-use.sh line:47-48,76-78 — grep/sed TOOL_COMMAND fallback fails on multi-line or escaped JSON**

```
Current:  grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed '...'
```

The fallback (when jq is absent) cannot extract commands containing escaped double quotes (`\"`), newlines, or Unicode. A Bash tool call with a multi-line command will be parsed as empty, silently skipping the block check. In practice jq is almost always present, but the fallback is subtly broken.

---

### stop-notify.sh

**[MEDIUM] stop-notify.sh line:55-61 — reads result file that may not yet be written by stop-results.sh**

```
Current:  if [ -f "$RESULT_FILE" ]; then
            STATUS=$(jq -r '.status // "done"' "$RESULT_FILE" ...)
```

`stop-results.sh` and `stop-notify.sh` are both stop hooks for the same event. If `stop-notify.sh` runs before `stop-results.sh` writes the result JSON, `RESULT_FILE` does not exist yet. `STATUS` defaults to `"done"`, masking any `"error"` status that would have been reported. Worker→Manager notifications always show `"done"` in this race.

---

### stop-results.sh

**[MEDIUM] stop-results.sh line:29 — uses tmux session environment for DOEY_TEAM_DIR**

```
Current:  PROJECT_DIR=$(tmux show-environment DOEY_TEAM_DIR 2>/dev/null | cut -d= -f2-)
```

`tmux show-environment` reads the session-wide tmux environment. In multi-team setups with different worktrees, each team has a different `DOEY_TEAM_DIR`. The session environment is last-write-wins and not per-window, so a worker on Team 2 might read Team 1's `DOEY_TEAM_DIR` if it was set last. Worktree isolation is broken for `git diff` in `stop-results.sh`.

---

### session-manager-wait.sh

**[MEDIUM] session-manager-wait.sh line:25-29 — wakes immediately if any result or crash file exists (files not consumed here)**

```
Current:  set -- "$RUNTIME_DIR/results"/pane_*.json
          [ -f "${1:-}" ] && { echo "NEW_RESULTS"; exit 0; }
          set -- "$RUNTIME_DIR/status"/crash_pane_*
          [ -f "${1:-}" ] && { echo "CRASH_ALERT"; exit 0; }
```

Result files (`pane_*.json`) are never deleted by the wait script or by normal processing. Once any worker has ever completed, the wait script exits immediately on every call without sleeping. The Session Manager effectively spins (no sleep) as long as result files exist. Similarly, unprocessed crash alerts cause permanent spin-wakeup.

---

### watchdog-wait.sh

**[MEDIUM] watchdog-wait.sh line:5 — falls back to team "1" if DOEY_TEAM_WINDOW unset**

```
Current:  TRIGGER="${RUNTIME_DIR}/status/watchdog_trigger_W${1:-${DOEY_TEAM_WINDOW:-1}}"
```

If neither `$1` (argument) nor `DOEY_TEAM_WINDOW` (env var) is set, the trigger file defaults to `watchdog_trigger_W1`. In multi-team setups, a Watchdog for Team 2 would wait on Team 1's trigger file, never waking on Team 2 worker completions. `DOEY_TEAM_WINDOW` is set by `on-session-start.sh` via `CLAUDE_ENV_FILE`, but that env is not inherited by Bash tool subprocesses without explicit export.

---

### watchdog-scan.sh

**[MEDIUM] watchdog-scan.sh line:294-312 — `_prev_cpu_secs` comparison without numeric guard after file read**

```
Current:  [ -f "$CPU_FILE" ] && read -r _prev_cpu_secs < "$CPU_FILE" 2>/dev/null
          _atomic_write "$CPU_FILE" "$_cpu_secs"
          if [ "$_prev_cpu_secs" -lt 0 ]; then
```

If `$CPU_FILE` contains corrupted/non-numeric content (e.g., from a partial write), `[ "$_prev_cpu_secs" -lt 0 ]` fails with an arithmetic error. With `set -euo pipefail`, this exits the entire watchdog-scan script. The `_atomic_write` function itself could fail mid-write if the disk is full. No guard before the `-lt` comparison.

**[MEDIUM] watchdog-scan.sh line:120-131 — manual JSON parsing of previous pane states fails on embedded commas**

```
Current:  PREV_PAIRS=$(echo "$PREV_JSON" | sed 's/[{}"]//g' | tr ',' '\n')
```

Parses `{"1":"IDLE","2":"WORKING"}` by stripping braces/quotes and splitting on commas. Breaks if state values ever contain commas. Safe for current fixed state names (IDLE, WORKING, etc.), but fragile. A stale/corrupted JSON file could produce incorrect PREV_STATE values, causing wrong duration calculations and false state-change events.

**[MEDIUM] watchdog-scan.sh — excessive tmux calls per scan cycle (performance)**

Per worker pane, each scan cycle makes approximately 8+ tmux invocations:
1. `tmux display-message` (pane mode)
2. `tmux capture-pane` (30-line output)
3. `tmux display-message` (current command)
4. `tmux capture-pane` (5-line boot check)
5. `tmux display-message` (pane PID)
6. `tmux capture-pane` (5-line hash capture)
7–9. `tmux display-message` (pane title, called by `_get_pane_title` up to 3×)

With 6 workers: 48+ tmux calls per scan, each ~10–30ms → 0.5–1.5s scan latency before any output is processed. Scans are synchronous (no parallelism). The `pane_output` captured at line 200 (`-S -30`) is not reused for subsequent checks within the same pane.

---

### post-tool-lint.sh

**[MEDIUM] post-tool-lint.sh line:77-79 — JSON escaping broken for paths/descriptions containing double quotes**

```
Current:  reason_escaped=$(echo "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk ...)
          echo "{\"decision\": \"block\", \"reason\": \"${reason_escaped}\"}"
```

`sed 's/"/\\"/g'` converts `"` → `\"` in the shell variable. When `echo "...${reason_escaped}..."` is evaluated, bash's double-quote context interprets `\"` as a literal `"`, stripping the escaping. The resulting JSON string has unescaped `"` characters and is not valid JSON. Triggered when linted `.sh` files contain lines with `"` (very common in shell scripts). Claude Code may fail to parse the block decision.

---

## LOW

### common.sh

**[LOW] common.sh line:44 — `_read_team_key` does not quote or validate key parameter**

```
Current:  val=$(grep "^$2=" "$1" | cut -d= -f2)
```

`$2` (the key name) is interpolated directly into the grep pattern. If a caller passes a key with regex metacharacters, the pattern would be malformed. In practice all callers use fixed string literals, so no real risk, but the function is not defensive.

**[LOW] common.sh line:71-74 — `is_session_manager` calls `get_sm_pane` on every invocation (no caching)**

Unlike `is_watchdog` (caches in `_DOEY_IS_WD`) and `is_manager` (caches in `_DOEY_IS_MGR`), `is_session_manager` calls `get_sm_pane` which greps `session.env` on every call. Called from multiple hooks per event. Minor I/O overhead.

---

### on-session-start.sh

**[LOW] on-session-start.sh line:15 — `_env_val` duplicates `_read_team_key` from common.sh**

`on-session-start.sh` does not source `common.sh` (correct — it has no `init_hook` call). It defines its own `_env_val` inline, which does the same key-value extraction as `common.sh:_read_team_key`. Not a bug, but a maintenance hazard: changes to the parsing logic must be applied in both places.

**[LOW] on-session-start.sh line:69 — team_0.env lookup for window 0 panes silently returns empty**

```
Current:  wt_dir=$(_env_val "${RUNTIME_DIR}/team_${TEAM_WINDOW}.env" WORKTREE_DIR)
```

For panes in window 0 (SM, Watchdog, Info Panel), `TEAM_WINDOW` may be "0". `team_0.env` typically does not exist, so `wt_dir` is empty and `DOEY_TEAM_DIR` defaults to `$PROJECT_DIR`. Expected behavior, but no diagnostic log or explicit handling.

---

### on-prompt-submit.sh

**[LOW] on-prompt-submit.sh line:34-38 — collapsed column file removal is not coordinated**

```
Current:  if [ -f "$collapsed" ]; then
            tmux resize-pane ... -x 80
            rm -f "$collapsed"
          fi
```

The watchdog-scan.sh also reads pane dimensions. If two prompts are submitted in rapid succession to the same pane (unlikely but possible), both hooks read `$collapsed` as present and both attempt `tmux resize-pane`. The second `rm -f` is harmless, but `tmux resize-pane` fires twice. No real-world impact.

---

### stop-status.sh

**[LOW] stop-status.sh line:11 — research block JSON decision uses unquoted shell substitution**

```
Current:  echo '{"decision": "block", "reason": "Research task requires a report. Write your report to '"${REPORT_FILE}"' before stopping."}'
```

If `$REPORT_FILE` contains characters that break JSON (backslash, double quote, or embedded newline), the output is invalid JSON and Claude Code may not parse the block decision. File paths under `/tmp/doey/` with embedded spaces or special chars would cause this.

---

### stop-results.sh

**[LOW] stop-results.sh line:20-26 — tool count heuristic from pane capture is fragile**

```
Current:  case "$line" in
            *"Read("*|*"Edit("*|*"Write("*|...) TOOL_COUNT=$((TOOL_COUNT + 1)) ;;
```

Counts lines from the raw terminal capture containing `ToolName(`. Over-counts if Claude Code outputs text discussing tools, or if pane contains prior session history. Under-counts if tool name display format changes. Silently produces wrong `tool_calls` values in result JSON.

**[LOW] stop-results.sh line:35-43 — mktemp fallback leaves `_tmpfile` empty on failure**

In the `timeout`-absent code path: `_tmpfile=$(mktemp)` with `set -euo pipefail` would exit if mktemp fails. However, the subshell `(...)` inherits `set -e` and would also exit. The backgrounded `_killer` process would then be orphaned with no cleanup. Minor edge case.

---

### watchdog-scan.sh

**[LOW] watchdog-scan.sh line:223-225 — `case "$i"` numeric guard is redundant after `is_numeric` check**

```
Current:  is_numeric "$i" || continue   # line 183
          ...
          case "$i" in *[!0-9]*) continue ;; esac  # lines 223, 240, 255, ...
```

After `is_numeric "$i" || continue` at the top of the loop, `$i` is guaranteed numeric. The subsequent `case "$i" in *[!0-9]*) continue ;; esac` guards scattered throughout the loop body are redundant and add noise (7+ occurrences). No bug, but obscures intent.

**[LOW] watchdog-scan.sh line:405-419 — `case "$i" in *[!0-9]*) continue ;; esac` inside counting loops**

Same redundant guard issue in the post-loop summary counters (lines 399–421). `$i` was validated at loop entry via `is_numeric`.

**[LOW] watchdog-scan.sh line:348-349 — `_update_duration` called with hardcoded "WORKING" instead of `$_prev_raw`**

```
Current:  _update_duration "$i" "WORKING" "WORKING"
          _set_pane_info "$i" "$_unch_state" ... "" "WORKING"
```

In the `UNCHANGED` (hash match + CPU active) path, `_update_duration` is called with `"WORKING"` for both prev and cur, ignoring `eval "_prev=\${PREV_STATE_${i}}"` computed just above. The duration "since" timestamp is reset only on state transitions; forcing "WORKING"→"WORKING" with the same prev/cur means the timer is never reset in this path. Likely intentional (keep duration accumulating), but misleading.

**[LOW] watchdog-scan.sh line:583-589 — context pressure check reads own pane output (reentrancy risk)**

```
Current:  _ctx_line=$(tmux capture-pane -t "${TMUX_PANE}" -p -S -5 ...)
```

The watchdog-scan.sh script reads its own pane's output to detect context pressure. The pane displays the previous scan's output, not the live context meter. If the scan output scrolls the context meter off-screen (more than 5 lines of scan output), the context check finds nothing and silently skips the compact warning. With verbose output (many panes, many events), this is common.

---

### post-tool-lint.sh

**[LOW] post-tool-lint.sh line:40 — grep pattern failure is silently suppressed**

```
Current:  ALL_MATCHES=$(grep -nE "$COMBINED_PATTERN" "$FILE_PATH" 2>/dev/null || true)
```

If `$COMBINED_PATTERN` is malformed (regex error), grep exits non-zero and `ALL_MATCHES` is empty. All lint violations are silently missed. The `|| true` masks the error. No warning is emitted.

---

## Inter-Hook Interaction Issues

**[HIGH] stop-notify.sh↔stop-status.sh — ordering dependency for Manager→SM notification**
See stop-notify.sh [HIGH] finding above. Notification correctness depends on stop-notify reading BUSY before stop-status writes READY.

**[MEDIUM] stop-notify.sh↔stop-results.sh — result file may not exist when stop-notify reads it**
See stop-notify.sh [MEDIUM] finding above. Worker error status is masked if stop-results.sh hasn't written the result file yet.

**[MEDIUM] session-manager-wait.sh↔stop-results.sh — result files accumulate and cause spin**
See session-manager-wait.sh [MEDIUM] finding above. The SM wait loop never sleeps once any results exist.

**[LOW] on-pre-compact.sh↔stop-status.sh — CURRENT_TASK read from status file may race with write**
`on-pre-compact.sh` greps TASK from the status file written by `on-prompt-submit.sh`. If compaction is triggered very quickly after a prompt (unlikely), the status file might not yet be written. `CURRENT_TASK` would be empty or stale. Low probability.

---

## Lifecycle Coverage Gaps

**on-session-start.sh**: No hook validates that `CLAUDE_ENV_FILE` write succeeded. If the write fails (permissions, disk full), Claude Code starts without any `DOEY_*` env vars, causing all subsequent hooks to exit early (no TMUX_PANE matching). Silent failure.

**stop-results.sh + stop-status.sh**: Both hooks run synchronously in the stop event. If either hangs (e.g., `git diff` hangs on a locked repo), it blocks Claude Code from stopping. `stop-results.sh` has a `timeout` guard for git, but only if `timeout` is available. The fallback uses `sleep 2 && kill`, which adds 2 seconds of latency to every worker stop.

**watchdog-scan.sh**: No maximum execution time guard. If a tmux call hangs (rare but possible on pane death), the scan blocks indefinitely, preventing the Watchdog from issuing further scans or detecting the hanging state.

---

## Summary Table

| Severity | Count | Files |
|----------|-------|-------|
| CRITICAL | 1 | on-pre-tool-use.sh |
| HIGH | 4 | on-pre-tool-use.sh (×2), stop-notify.sh, on-session-start.sh |
| MEDIUM | 10 | common.sh (×2), on-pre-tool-use.sh, stop-notify.sh (×2), stop-results.sh, session-manager-wait.sh, watchdog-wait.sh, watchdog-scan.sh (×3), post-tool-lint.sh |
| LOW | 14 | common.sh (×2), on-session-start.sh (×2), on-prompt-submit.sh, stop-status.sh, stop-results.sh (×2), watchdog-scan.sh (×5), post-tool-lint.sh |

**Priority fixes:**
1. `on-pre-tool-use.sh:69` — pipe-subshell init_hook (CRITICAL)
2. `on-pre-tool-use.sh:40` — add `watchdog` to fast-path exits (HIGH, depends on #1)
3. `on-session-start.sh:77` — add lock staleness check (HIGH)
4. `stop-notify.sh:75` — remove dependency on stop hook execution order (HIGH)
5. `post-tool-lint.sh:78` — fix JSON escaping via jq or printf (MEDIUM)
6. `session-manager-wait.sh:25` — add result file consumption/age check (MEDIUM)
