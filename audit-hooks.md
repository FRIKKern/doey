# Doey Hooks Audit Report

**Date:** 2026-03-23
**Scope:** All 12 files in `.claude/hooks/`
**Auditor:** Worker 3 (R&D Team) -- Second pass, thorough review

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| HIGH     | 7 |
| MEDIUM   | 12 |
| LOW      | 8 |

---

## CRITICAL

### [CRITICAL] file:on-session-start.sh line:63 — tmux set-environment DOEY_ROLE race overwrites all panes' roles

`tmux set-environment -t "$SESSION_NAME" DOEY_ROLE "$ROLE"` sets a **session-level** environment variable. When multiple panes start concurrently (which is the normal case during boot), the last pane to execute this line wins and overwrites the value for the entire session. A worker starting after the manager will set `DOEY_ROLE=worker` session-wide.

**Impact analysis:** `on-pre-tool-use.sh` lines 18, 38, and 42 read `${DOEY_ROLE:-}` from the **process environment** (inherited via `CLAUDE_ENV_FILE` at line 98), not from `tmux show-environment`. Since `CLAUDE_ENV_FILE` is written per-pane and sourced into each Claude process individually, the process-level DOEY_ROLE is correct. The tmux session-level value at line 63 is therefore **dead code that creates confusion** but does not cause actual role misidentification in hooks that use `${DOEY_ROLE:-}`.

**However:** If any code ever calls `tmux show-environment DOEY_ROLE` (as on-pre-tool-use.sh line 24 does for DOEY_RUNTIME), it would get the wrong value. This is a latent correctness hazard.

**Recommendation:** Remove line 63 entirely, or write to a per-pane file like `${RUNTIME_DIR}/status/role_${PANE_SAFE}`.

### [CRITICAL] file:on-pre-tool-use.sh line:24 — tmux show-environment uses pane target incorrectly

```bash
RUNTIME_DIR=$(tmux show-environment -t "$TMUX_PANE" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
```

The `-t` flag for `show-environment` expects a **session** target, not a pane ID like `%5`. Tmux resolves the session from the pane, so this works by accident. But if multiple doey sessions exist, this queries the session-level env which could be stale or overwritten (same class of bug as line 63 of on-session-start.sh).

### [CRITICAL] file:on-pre-tool-use.sh line:25 — `read` without `-r` flag

```bash
read WINDOW_INDEX CURRENT_PANE <<< "$(tmux display-message ...)"
```

`read` without `-r` interprets backslashes in the input. If tmux output ever contains backslashes, the parsed values would be corrupted, potentially causing role misidentification and security bypass (wrong pane could be identified as manager, skipping all restrictions).

---

## HIGH

### [HIGH] file:common.sh line:10 — RUNTIME_DIR from tmux show-environment queries global server env

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
```

No `-t` flag means this queries the **global** tmux server environment. If multiple doey sessions run simultaneously with different RUNTIME_DIR values, this returns the last one set. The same issue appears in on-session-start.sh line 8, watchdog-scan.sh line 75, watchdog-wait.sh line 4, and session-manager-wait.sh line 5.

### [HIGH] file:session-manager-wait.sh line:6 — `source` executes session.env as arbitrary code

```bash
source "${RUNTIME_DIR}/session.env" 2>/dev/null || true
```

`source` evaluates the file as bash. If session.env is corrupted or tampered with (or contains expansions/commands beyond simple assignments), this executes arbitrary code. Should use the `while IFS='=' read` pattern used elsewhere (e.g., on-session-start.sh lines 19-26).

### [HIGH] file:stop-results.sh lines:34-41 — manual timeout with PID recycling race

When `timeout` is unavailable, the script spawns git in background, then spawns a killer process. If git finishes fast and its PID is recycled, `kill "$_killer"` at line 39 could kill an unrelated process. The `wait` calls are best-effort and don't fully prevent the race.

### [HIGH] file:stop-results.sh line:27 — tmux show-environment queries global env for DOEY_TEAM_DIR

```bash
PROJECT_DIR=$(tmux show-environment DOEY_TEAM_DIR 2>/dev/null | cut -d= -f2-)
```

Should use `${DOEY_TEAM_DIR:-}` from the process environment (set via CLAUDE_ENV_FILE) instead of querying tmux.

### [HIGH] file:watchdog-scan.sh line:33 — `printf -v` with pane-index-derived variable names

```bash
printf -v "PANE_STATE_${idx}" '%s' "$state"
```

Used ~20 times throughout the file. While `idx` comes from tmux pane indices and is validated in most paths, not every code path has a guard. If a non-numeric index slipped through, this could set arbitrary variable names.

### [HIGH] file:watchdog-scan.sh lines:224,241,256,330,382,401-512 — extensive `eval` usage

11+ `eval` statements for dynamic variable access. All index variables are internally constructed and most have `is_numeric` guards, but the sheer volume of eval calls makes reasoning about correctness difficult. Additionally, the redundant `case "$i" in *[!0-9]*) continue` guards before nearly every eval (lines 400, 402, 406, 485-494) suggest low confidence in the single loop guard at line 399.

### [HIGH] file:common.sh line:139 — PowerShell notification command injection

```bash
powershell.exe -Command "... '${ps_body}' ..."
```

`ps_title` and `ps_body` are single-quote escaped (`'` -> `''`) but the outer string uses double quotes. A body containing `'` followed by `);` could break out of the PowerShell string. Low risk (macOS-primary, content from Claude), but still an injection vector.

---

## MEDIUM

### [MEDIUM] file:on-pre-compact.sh lines:23-26 — find + xargs + stat pipeline could be slow

```bash
RECENT_FILES=$(find "$SEARCH_DIR" -maxdepth 4 ... -print0 | xargs -0 stat ... | awk ... | head -10)
```

Runs `find` across up to 4 directory levels, then `stat` on every matching file. For large projects with many files, this could block the compaction hook for several seconds. Compaction is infrequent, so impact is limited.

### [MEDIUM] file:on-pre-compact.sh line:20-22 — stat flag detection fragility

BSD vs GNU stat detection via `stat -f '%m' /dev/null`. Works on macOS and standard Linux, but could misdetect in minimal containers where `/dev/null` has unusual stat behavior.

### [MEDIUM] file:post-tool-lint.sh line:76-77 — JSON output escaping is incomplete

```bash
reason_escaped=$(echo "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//')
echo "{\"decision\": \"block\", \"reason\": \"${reason_escaped}\"}"
```

Doesn't handle tab characters, control characters, or multi-byte edge cases. Malformed JSON could cause Claude Code to misinterpret the block response. Should use `jq -Rs` when available.

### [MEDIUM] file:common.sh line:38 — grep-based JSON fallback handles only flat string fields

`parse_field` grep fallback only handles top-level string fields. Nested JSON, arrays, or escaped quotes in values cause silent failure (returns empty). Callers may not be aware of this limitation.

### [MEDIUM] file:common.sh lines:48-58 — `is_watchdog()` iterates all team files on first call

While cached via `_DOEY_IS_WD`, the first call per hook invocation iterates all `team_*.env` files. In sessions with many teams, this adds latency.

### [MEDIUM] file:watchdog-scan.sh line:200,232,322 — redundant tmux capture-pane calls

Line 200 captures `pane_output` (unused after capture). Line 232 captures `_boot_capture` with `-S -5`. Line 322 captures `CAPTURE` with `-S -5`. Three tmux subprocesses per pane per scan cycle; should reuse a single capture.

### [MEDIUM] file:watchdog-scan.sh line:120-131 — fragile JSON parsing with sed

```bash
PREV_PAIRS=$(echo "$PREV_JSON" | sed 's/[{}"]//g' | tr ',' '\n')
```

Strips `{}",` chars to parse JSON. Any state value containing these characters would corrupt the parse. Currently safe because state values are simple enum strings, but fragile against future changes.

### [MEDIUM] file:on-pre-tool-use.sh line:53 — rm pattern matching is incomplete

```bash
*"rm -rf /"*|*"rm -rf ~"*|*'rm -rf $HOME'*)
```

The `~` check matches the literal `~` character, but Claude sends commands with `~` already expanded to the home directory path. The `$HOME` check is in single quotes so matches the literal `$HOME` string. Neither catches `rm -rf /Users/username` or `rm -rf /home/username`.

### [MEDIUM] file:common.sh line:100 — `sanitize_message` doesn't validate max_len is numeric

```bash
text="${text:0:$((max_len - 3))}..."
```

If a caller passes a non-numeric `max_len`, `$((...))` errors and `set -e` kills the script. No current callers pass bad values, but no validation exists.

### [MEDIUM] file:watchdog-scan.sh line:582-584 — context pressure self-capture is format-dependent

```bash
_ctx_line=$(tmux capture-pane -t "${TMUX_PANE}" -p -S -5 2>/dev/null | grep 'Ctx ' | tail -1)
```

Parses own pane output for Claude Code's `Ctx` indicator. Any format change in Claude Code's status bar breaks this detection silently.

### [MEDIUM] file:stop-results.sh line:46 — jq dependency for FILES_JSON with no fallback

```bash
FILES_JSON=$(echo "$FILES_LIST" | jq -R '.' | jq -s '.' 2>/dev/null) || FILES_JSON="[]"
```

Falls back to `"[]"` when jq is unavailable, losing all file change information. The rest of the script has jq-or-grep fallbacks, but this path doesn't.

### [MEDIUM] file:watchdog-scan.sh line:273-276 — anomaly auto-fix sends keystrokes without checking pane state

```bash
tmux send-keys -t "$PANE_REF" Escape 2>/dev/null
tmux send-keys -t "$PANE_REF" Enter 2>/dev/null
```

Sends Escape then Enter to a stuck pane. If the pane recovered between detection and auto-fix, this injects unexpected input. The 15-second cooldown mitigates but doesn't prevent this.

---

## LOW

### [LOW] file:common.sh line:26 — TOCTOU on `.dirs_created` sentinel

Concurrent hooks could both see the sentinel missing and both run `mkdir -p`. This is idempotent, so no actual harm.

### [LOW] file:on-session-start.sh lines:74-90 — skill sync lock doesn't retry

If `mkdir "$LOCK_DIR"` fails (lock held), the script `sleep 1` then falls through without syncing skills. No retry loop means this pane may get stale skills.

### [LOW] file:on-session-start.sh line:93 — env file append without dedup

`cat >> "$CLAUDE_ENV_FILE"` appends without checking for existing entries. If on-session-start.sh runs twice, the env file gets duplicate exports. Functionally correct (last value wins) but wasteful.

### [LOW] file:stop-status.sh line:21-22 — mktemp fallback degrades to non-atomic write

When mktemp fails, writes directly to status file. Concurrent readers could see partial content. The fallback is logged to warnings.

### [LOW] file:watchdog-scan.sh line:521 — grep on SNAPSHOT_EVENTS may return exit code 1

`_anomaly_lines=$(grep '^ANOMALY ' ...)` — grep returns 1 when no match. Under `set -e`, simple assignments don't trigger exit, but this is a subtle edge case.

### [LOW] file:on-pre-tool-use.sh line:57 — misleading error message for workers

Error says "Only the Window Manager can do this" but Watchdog can also use limited send-keys. Minor messaging inaccuracy.

### [LOW] file:stop-results.sh line:20-24 — tool count from screen scraping is unreliable

Counting tool calls by pattern-matching captured pane output (`Read(`, `Edit(`, etc.) undercounts if output scrolls beyond the 80-line capture window.

### [LOW] file:watchdog-scan.sh lines:398-420 — redundant is_numeric + case guards throughout

`is_numeric "$i"` at loop entry (line 399) should suffice, but `case "$i" in *[!0-9]*) continue` is repeated ~15 times within the loop body. This is ~30 lines of redundant defensive code.

---

## Exit Code Convention Compliance

All hooks correctly follow the convention:
- `exit 0` -- allow/continue
- `exit 1` -- not used (correct: block+error without feedback is unused)
- `exit 2` -- block+feedback (used in on-pre-tool-use.sh, stop-status.sh)
- post-tool-lint.sh uses JSON `{"decision": "block", "reason": "..."}` output with `exit 0` (correct for post-tool hooks)

---

## Bash 3.2 Compatibility

No violations of forbidden constructs found:
- No `declare -A/-n/-l/-u`
- No `mapfile`/`readarray`
- No `|&` or `&>>`
- No `coproc`
- No `printf '%(%s)T'`
- No `BASH_REMATCH` usage

Constructs used that are bash 3.1+ (safe for 3.2):
- `printf -v` (watchdog-scan.sh, ~20 occurrences)
- `+=` string append (watchdog-scan.sh line 513)
- `<<<` here-strings (on-pre-tool-use.sh, watchdog-scan.sh)

---

## Positive Patterns Observed

1. **Atomic writes** via tmp+mv used consistently (stop-results.sh, stop-status.sh, on-prompt-submit.sh, watchdog-scan.sh `_atomic_write` helper)
2. **Graceful degradation**: jq-with-grep-fallback pattern used throughout for JSON parsing
3. **Role caching**: `is_watchdog()`/`is_manager()` cache results in `_DOEY_IS_WD`/`_DOEY_IS_MGR`
4. **Trap cleanup**: stop-results.sh properly cleans up temp files on EXIT
5. **Early exits**: Non-Doey sessions exit immediately (`[ -z "${TMUX_PANE:-}" ] && exit 0`)
6. **Fast paths in on-pre-tool-use.sh**: Role-based early exits avoid expensive tmux/init_hook calls for known roles
7. **Notification cooldown**: 60-second dedup in send_notification prevents notification spam
8. **File-based messaging**: stop-notify.sh uses atomic file writes with send-keys fallback

---

## Key Recommendation: DOEY_ROLE Environment Scope

The investigated bug (item 6 from task instructions) is **confirmed as a latent hazard but not an active bug**:

- **Process-level `DOEY_ROLE`** (via `CLAUDE_ENV_FILE`, line 98): Correct per-pane. This is what `on-pre-tool-use.sh` fast paths use at lines 18, 38, 42. Each Claude instance gets its own env file written before it starts.

- **Session-level `DOEY_ROLE`** (via `tmux set-environment`, line 63): **Overwritten by last pane to start**. This value is incorrect for all panes except the last one that booted. Currently no hook reads this via `tmux show-environment DOEY_ROLE`, so no active bug exists.

- **Recommendation**: Remove line 63 of on-session-start.sh to eliminate the latent hazard. If tmux-level role lookup is needed, use per-pane files instead.
