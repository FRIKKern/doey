# Doey Hooks Audit Report

**Date:** 2026-03-23
**Scope:** All 12 files in `.claude/hooks/`
**Auditor:** Worker 3 (R&D Team)

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2     |
| HIGH     | 8     |
| MEDIUM   | 11    |
| LOW      | 8     |

---

## CRITICAL

### [CRITICAL] watchdog-scan.sh line:210-216 — Non-atomic crash file write

Crash files are written directly without tmp+mv pattern. The watchdog or manager could read a partially-written file.

```bash
# Current:
cat > "$CRASH_FILE" << CRASH_EOF
PANE_INDEX=${i}
TIMESTAMP=$(date +%s)
LAST_OUTPUT=$(echo "$CRASH_CAPTURE" | tail -5 | tr '\n' '|')
CRASH_EOF
```

```bash
# Suggested:
cat > "${CRASH_FILE}.tmp" << CRASH_EOF
PANE_INDEX=${i}
TIMESTAMP=$(date +%s)
LAST_OUTPUT=$(echo "$CRASH_CAPTURE" | tail -5 | tr '\n' '|')
CRASH_EOF
mv "${CRASH_FILE}.tmp" "$CRASH_FILE"
```

### [CRITICAL] watchdog-scan.sh line:269-271 — Blocking sleep in hot-path scan loop

`sleep 0.3` blocks the entire scan loop per anomalous pane. With 6 workers stuck in PROMPT_STUCK, the scan blocks for 1.8 seconds. This delays state detection for all other panes and can cause the watchdog to appear unresponsive.

```bash
# Current:
tmux send-keys -t "$PANE_REF" Escape 2>/dev/null
sleep 0.3
tmux send-keys -t "$PANE_REF" "1" Enter 2>/dev/null
```

```bash
# Suggested: Remove sleep and send as a single sequence, or move auto-fix to a post-scan phase
tmux send-keys -t "$PANE_REF" Escape 2>/dev/null
tmux send-keys -t "$PANE_REF" "1" Enter 2>/dev/null
```

---

## HIGH

### [HIGH] on-pre-tool-use.sh line:1-95 — Hot path performance: multiple subshells per tool call

This hook runs before EVERY tool call. For Bash tools, it spawns 5+ subshells: `cat` (stdin), `jq`/`grep+sed` (parse), `tmux show-environment`, `tmux display-message`, `date`, plus sourcing `common.sh` which spawns more. Each tool call pays this cost.

```
Suggested: Cache role detection in an env var (set once in on-session-start.sh)
so hot-path checks can skip tmux calls entirely. The role doesn't change mid-session.
```

### [HIGH] on-pre-tool-use.sh line:17 — tmux show-environment uses pane target incorrectly

`tmux show-environment -t "$TMUX_PANE"` passes a pane target, but `show-environment` operates at session/global level. Tmux resolves this to the session, but the intent is unclear and may break if tmux changes target resolution behavior.

```bash
# Current:
RUNTIME_DIR=$(tmux show-environment -t "$TMUX_PANE" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
```

```bash
# Suggested: Use show-environment without -t (uses current session) or extract session name first
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
```

### [HIGH] stop-notify.sh line:30 — send-keys message injection into active pane

`send_to_pane` injects text via `tmux send-keys` into a pane that may be actively processing input. If the manager is mid-prompt composition, the injected text corrupts its input buffer. There is no guard against this.

```
Suggested: Use a file-based message queue (write to messages/ dir) instead of
raw send-keys, or check pane idle state before injecting.
```

### [HIGH] on-session-start.sh line:70-78 — Concurrent skill directory sync without locking

Multiple panes starting simultaneously run `cp -R` and `rm -rf` on the same `.claude/skills/doey-*/` directories. Two concurrent `cp -R` operations to the same target can produce corrupted files.

```bash
# Current (no locking):
cp -R "$_sd" "$_skill_target/.claude/skills/"
```

```
Suggested: Use a lockfile or check if the pane is the first to start (e.g., pane 0 only).
```

### [HIGH] watchdog-scan.sh line:120-131 — Fragile JSON parsing with sed

Parsing the previous states JSON by stripping `{}",` chars is brittle. Any state value containing these characters would corrupt the parse. Currently safe because state values are simple strings, but any future change could break this silently.

```bash
# Current:
PREV_PAIRS=$(echo "$PREV_JSON" | sed 's/[{}"]//g' | tr ',' '\n')
```

```bash
# Suggested: Use jq when available, with the sed fallback clearly documented as limited
if command -v jq >/dev/null 2>&1; then
  # Use jq for reliable parsing
else
  # Fallback: only works with simple string values
fi
```

### [HIGH] watchdog-scan.sh line:511-513 — Repeated tmux capture-pane per anomaly pane

For each anomaly event, `tmux capture-pane` is called again despite the pane already being captured at lines 229 and 318. This is wasted I/O in the scan loop.

```bash
# Current:
_a_capture_snippet=$(tmux capture-pane -t "${SESSION_NAME}:${TARGET_WINDOW}.${_a_pane}" -p -S -3 2>/dev/null | tail -3 | tr '\n' '|')
```

```
Suggested: Reuse the capture already stored in $_boot_capture or $CAPTURE from the scan loop.
Store captures in indexed variables during the scan phase.
```

### [HIGH] common.sh line:108-134 — Notification command injection via title/body

`send_notification` escapes `\` and `"` but not other shell metacharacters. The `osascript -e` call embeds title/body in a double-quoted string. Characters like `$()` or backticks in the body could execute arbitrary commands.

```bash
# Current:
osascript -e "display notification \"${body}\" with title \"${title}\" sound name \"Ping\"" 2>/dev/null &
```

```bash
# Suggested: Use osascript with stdin to avoid shell interpolation
osascript <<APPLESCRIPT 2>/dev/null &
display notification "$body" with title "$title" sound name "Ping"
APPLESCRIPT
```

### [HIGH] post-tool-lint.sh line:75-77 — JSON output with incomplete escaping

The violation text is escaped with sed for `\` and `"`, then joined with awk, but doesn't handle other JSON-special characters (e.g., tab, control characters). Malformed JSON causes Claude Code to misinterpret the block response.

```bash
# Current:
reason_escaped=$(echo "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//')
echo "{\"decision\": \"block\", \"reason\": \"${reason_escaped}\"}"
```

```bash
# Suggested: Use jq for JSON encoding when available
if command -v jq >/dev/null 2>&1; then
  echo "{\"decision\": \"block\", \"reason\": $(echo "$reason" | jq -Rs '.')}"
else
  # existing fallback
fi
```

---

## MEDIUM

### [MEDIUM] common.sh line:117-120 — TOCTOU on notification cooldown file

Read-then-write to cooldown file without locking. Two concurrent hook invocations could both read the old timestamp and both send notifications. Low practical impact due to Session Manager being single-instance.

```bash
# Current:
last_sent=$(cat "$cooldown_file" 2>/dev/null) || last_sent=0
now=$(date +%s)
[ "$((now - last_sent))" -lt 60 ] && return 0
echo "$now" > "$cooldown_file" 2>/dev/null || true
```

### [MEDIUM] on-prompt-submit.sh line:11 — mktemp fallback bypasses atomic write

When `mktemp` fails, the status file is written directly (non-atomic). The watchdog could read a partially-written status file.

```bash
# Current:
tmp=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null) || tmp="$STATUS_FILE"
```

```
Suggested: If mktemp fails, the runtime dir may have permissions issues.
Log a warning rather than silently degrading to non-atomic writes.
```

### [MEDIUM] stop-results.sh line:58 — Same mktemp fallback issue as on-prompt-submit.sh

```bash
TMPFILE=$(mktemp "${RUNTIME_DIR}/results/.tmp_XXXXXX" 2>/dev/null) || TMPFILE="$RESULT_FILE"
```

### [MEDIUM] stop-status.sh line:21 — Same mktemp fallback issue

```bash
TMP=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null) || TMP="$STATUS_FILE"
```

### [MEDIUM] watchdog-scan.sh line:329-331 — Read-modify-write counter without locking

The unchanged_count counter is read, incremented, and written without any file locking. Concurrent watchdog restarts could produce incorrect counts.

```bash
read -r OLD_COUNT < "$COUNTER_FILE" 2>/dev/null || OLD_COUNT=0
NEW_COUNT=$((OLD_COUNT + 1))
echo "$NEW_COUNT" > "$COUNTER_FILE"
```

### [MEDIUM] session-manager-wait.sh line:6 — Sourcing session.env as shell code

`source "${RUNTIME_DIR}/session.env"` executes the file as shell code. If session.env is corrupted or tampered with, it could execute arbitrary commands. The file is generated by doey, so this is low-risk but violates principle of least privilege.

```bash
# Suggested: Use read-based parsing (like on-session-start.sh does) instead of source
while IFS='=' read -r key value; do ...
```

### [MEDIUM] watchdog-scan.sh line:221,237,325,376,394-398,476-480,497 — Extensive use of eval for dynamic variables

11 `eval` statements for dynamic variable access. All variables are internally constructed (not user-controlled), but `eval` makes reasoning about correctness harder and any future change introducing external data would create injection risk.

```bash
# Current (multiple locations):
eval "_prev=\${PREV_STATE_${i}:-UNKNOWN}"
```

```
Suggested: Document eval safety invariant: all index variables ($i, $idx)
must be validated as numeric before eval. Currently enforced by is_numeric checks.
```

### [MEDIUM] on-pre-tool-use.sh line:84 — rm pattern could match unintended commands

The pattern `*"rm -rf ~"*` checks for tilde, but `~` in a double-quoted string is literal, not expanded. A command like `rm -rf ~/Documents` would NOT match this pattern because the shell expands `~` before passing to the hook, while the pattern matches the literal `~` character.

```bash
# Current:
*"rm -rf /"*|*"rm -rf ~"*|*'rm -rf $HOME'*)
```

```
Suggested: Also match expanded home directory path:
*"rm -rf /"*|*"rm -rf ~"*|*"rm -rf $HOME"*|*"rm -rf /Users/"*|*"rm -rf /home/"*)
```

### [MEDIUM] watchdog-scan.sh line:567-570 — Self-capture for context pressure is fragile

Parsing own pane output with `grep 'Ctx '` and `sed` to extract context percentage relies on Claude Code's exact output format. Any format change breaks silent detection.

```bash
_ctx_line=$(tmux capture-pane -t "${TMUX_PANE}" -p -S -5 2>/dev/null | grep 'Ctx ' | tail -1) || _ctx_line=""
_ctx_pct=$(echo "$_ctx_line" | sed 's/.*Ctx [^ ]* //;s/%.*//')
```

### [MEDIUM] common.sh line:22-24 — Multiple stat calls on every hook init

`init_hook` checks 5 directories and potentially creates them on every invocation. For hot-path hooks (on-pre-tool-use.sh), this adds latency.

```bash
# Current:
if [ ! -d "${RUNTIME_DIR}/status" ] || [ ! -d "${RUNTIME_DIR}/results" ] || ...
```

```
Suggested: Cache a sentinel file (e.g., .dirs_created) after first mkdir -p,
and skip the check on subsequent calls.
```

### [MEDIUM] stop-results.sh line:30 — git diff in stop hook could be slow

`git diff --name-only HEAD` in a large repo could take significant time, blocking the stop hook pipeline.

```bash
FILES_LIST=$(cd "$PROJECT_DIR" 2>/dev/null && git diff --name-only HEAD 2>/dev/null | head -20) || FILES_LIST=""
```

---

## LOW

### [LOW] watchdog-wait.sh line:9-10 — TOCTOU on trigger file

Check-then-delete pattern on trigger file. If another process deletes between check and rm, rm fails silently (handled by `2>/dev/null`). No practical impact.

### [LOW] session-manager-wait.sh line:16-17 — Same TOCTOU on trigger file

Same check-then-delete pattern. Handled gracefully.

### [LOW] common.sh line:127 — Background notification process never reaped

`osascript ... &` creates orphaned background processes. On macOS, they're reaped by init, but in long-running sessions this could accumulate zombie entries briefly.

### [LOW] on-pre-compact.sh line:23-26 — find + xargs + stat on every pre-compact

Runs filesystem scan with `find | xargs stat | awk` on every compaction. Acceptable because compaction is infrequent, but could be slow in large project trees.

### [LOW] stop-results.sh line:20-24 — Tool count from screen scraping is unreliable

Counting tool calls by pattern-matching `tmux capture-pane` output (looking for `Read(`, `Edit(`, etc.) is fragile and undercounts if output scrolls beyond the 80-line capture window.

### [LOW] watchdog-scan.sh line:362-374 — Tool detection from screen scraping

Same screen-scraping approach for detecting last active tool. Only captures tools whose names appear in the last 5 lines of pane output.

### [LOW] on-pre-tool-use.sh line:89 — Workers blocked from all tmux send-keys

Workers cannot use `tmux send-keys` at all. While correct for security, the error message says "Only the Window Manager can do this" — but Watchdog can also use limited send-keys. Misleading error text.

### [LOW] common.sh line:94 — Substring expansion style

`${text:0:$((max_len - 3))}` works in bash 3.2 but is a less portable POSIX syntax. Not a violation, but worth noting for portability awareness.

---

## Exit Code Convention Compliance

All hooks correctly follow the convention:
- `exit 0` — allow/continue
- `exit 1` — not used (correct: no hooks need block+error without feedback)
- `exit 2` — block+feedback (used in on-pre-tool-use.sh, stop-status.sh)
- post-tool-lint.sh uses JSON `{"decision": "block", "reason": "..."}` output with `exit 0` (correct for post-tool hooks)

---

## Positive Patterns Observed

1. **Atomic writes** via tmp+mv pattern used consistently in stop-results.sh, stop-status.sh, on-prompt-submit.sh, watchdog-scan.sh (`_atomic_write` helper)
2. **Graceful degradation**: jq-with-grep-fallback pattern used throughout
3. **Role caching**: `is_watchdog()`/`is_manager()` cache results in `_DOEY_IS_WD`/`_DOEY_IS_MGR`
4. **Trap cleanup**: stop-results.sh properly cleans up temp files on exit
5. **Early exits**: Non-Doey sessions exit immediately (`[ -z "${TMUX_PANE:-}" ] && exit 0`)
6. **Bash 3.2 compliance**: No violations found (no `declare -A/-n`, no `mapfile`, no `|&`, no `&>>`)
