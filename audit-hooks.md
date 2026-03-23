# Hook Scripts Audit Report

**Date:** 2026-03-23 (updated)
**Scope:** All 12 `.sh` files in `.claude/hooks/`
**Auditor:** Worker 3 (hook-audit_0323)

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 1     |
| HIGH     | 5     |
| MEDIUM   | 9     |
| LOW      | 7     |
| INFO     | 4     |

---

## CRITICAL

### [CRITICAL] watchdog-scan.sh line:521 — `set -e` kills script when grep finds no ANOMALY events

The command `_anomaly_lines=$(printf '%s' "$SNAPSHOT_EVENTS" | grep '^ANOMALY ')` returns exit code 1 when no anomaly events exist. With `set -euo pipefail`, this terminates the script **before** writing the heartbeat (line 504), pane states JSON (line 517), running anomaly cleanup (lines 541-572), and the context pressure check (lines 582-590). The author is aware of this pattern — line 582 has `|| _ctx_line=""` as a guard, but line 521 is missing it. This means on any scan cycle without anomalies, the watchdog loses its heartbeat and state persistence.

```bash
# Current (line 521):
_anomaly_lines=$(printf '%s' "$SNAPSHOT_EVENTS" | grep '^ANOMALY ')

# Suggested:
_anomaly_lines=$(printf '%s' "$SNAPSHOT_EVENTS" | grep '^ANOMALY ' || true)
```

**Impact:** Watchdog heartbeat, pane states JSON, and anomaly cleanup are silently skipped on every non-anomaly scan cycle. Manager may detect watchdog as unresponsive.

---

## HIGH

### [HIGH] on-session-start.sh line:63 — Race condition: session-wide DOEY_ROLE overwritten by last pane to start

`tmux set-environment -t "$SESSION_NAME" DOEY_ROLE "$ROLE"` sets a **session-level** variable. When multiple panes start concurrently during session launch, the last one wins. A worker starting after the manager overwrites DOEY_ROLE with "worker" for the entire session. This affects the fallback role-detection path in on-pre-tool-use.sh (line 24) that reads `tmux show-environment`.

```bash
# Current (line 63):
tmux set-environment -t "$SESSION_NAME" DOEY_ROLE "$ROLE" 2>/dev/null || true

# Suggested: Remove this line entirely.
# Per-pane DOEY_ROLE is already exported via CLAUDE_ENV_FILE (line 98).
# The fallback in on-pre-tool-use.sh detects role from team env files when DOEY_ROLE is unset.
```

### [HIGH] watchdog-scan.sh line:200 — Unused `pane_output` wastes tmux capture-pane call per worker per cycle

`pane_output=$(tmux capture-pane -t "$PANE_REF" -p -S -30 2>/dev/null)` is set but **never referenced anywhere**. The scan later re-captures at lines 232 and 322 (both `-S -5`). This is a wasted subprocess + tmux IPC call per worker per scan cycle. For a 6-worker team with 5-second scan cycles, that's ~72 unnecessary tmux calls per minute.

```bash
# Current (line 200):
pane_output=$(tmux capture-pane -t "$PANE_REF" -p -S -30 2>/dev/null) || pane_output=""

# Suggested: Delete this line entirely.
```

### [HIGH] on-session-start.sh line:58 — Misidentifies pane 0 as manager when team env file is missing

When `team_${WINDOW_INDEX}.env` doesn't exist, `_env_val` returns empty, and `[ "$PANE_INDEX" = "${mgr_pane:-0}" ]` defaults to checking if PANE_INDEX is 0. This means pane 0 in any window without a team file gets ROLE="manager", gaining unrestricted tool access via on-pre-tool-use.sh.

```bash
# Current (lines 58-59):
mgr_pane=$(_env_val "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" MANAGER_PANE)
[ "$PANE_INDEX" = "${mgr_pane:-0}" ] && ROLE="manager"

# Suggested:
if [ -f "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" ]; then
  mgr_pane=$(_env_val "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" MANAGER_PANE)
  [ "$PANE_INDEX" = "${mgr_pane:-0}" ] && ROLE="manager"
fi
```

### [HIGH] common.sh line:130-134 — Notification dispatch: osascript heredoc + PowerShell command injection

The `send_notification` function uses an AppleScript heredoc (lines 130-134) which correctly avoids shell interpolation. However, the PowerShell branch (lines 138-139) embeds `$ps_body` with only single-quote escaping into a PowerShell `-Command` string. Characters like `$(...)` or backticks in the notification body could execute arbitrary PowerShell commands.

```bash
# Current (lines 138-139):
local ps_title="${title//\'/\'\'}" ps_body="${body//\'/\'\'}"
powershell.exe -Command "... '${ps_body}' ..."

# Suggested: Use -EncodedCommand with base64, or sanitize more thoroughly.
# Low practical risk on macOS, but a real injection vector on WSL/Windows.
```

### [HIGH] watchdog-scan.sh lines:232,322 — Redundant tmux capture-pane calls with identical parameters

Line 232 captures `-S -5` into `_boot_capture`. Line 322 captures `-S -5` into `CAPTURE`. These are identical captures done ~100 lines apart. Reusing one variable halves the per-worker tmux IPC cost.

```bash
# Current:
_boot_capture=$(tmux capture-pane -t "$PANE_REF" -p -S -5 ...)  # line 232
...
CAPTURE=$(tmux capture-pane -t "$PANE_REF" -p -S -5 ...)        # line 322

# Suggested: Capture once, reuse:
CAPTURE=$(tmux capture-pane -t "$PANE_REF" -p -S -5 2>/dev/null) || CAPTURE=""
_boot_capture="$CAPTURE"
_worker_capture="$CAPTURE"
```

---

## MEDIUM

### [MEDIUM] on-pre-tool-use.sh lines:40-51 — Worker Bash commands always pay init_hook overhead

Every Bash tool call from a worker sources `common.sh` and runs `init_hook` (4+ tmux/subprocess calls). Managers and session managers get a fast exit at line 38 via cached `DOEY_ROLE`, but workers fall through to the expensive path every time. For fast commands like `ls`, the hook overhead may exceed the command itself.

```bash
# Current (line 38):
case "${DOEY_ROLE:-}" in manager|session_manager) exit 0 ;; esac

# Suggested: Add worker fast-path before sourcing common.sh:
case "${DOEY_ROLE:-}" in manager|session_manager) exit 0 ;; esac
# Workers: extract command directly without full init_hook
if [ "${DOEY_ROLE:-}" = "worker" ]; then
  # ... inline command extraction and pattern matching ...
fi
```

### [MEDIUM] on-pre-tool-use.sh line:94 — Literal `$HOME` in pattern doesn't match expanded path

The pattern `*'rm -rf $HOME'*` matches the literal string `$HOME`, not its expansion. A command like `rm -rf /Users/pelle` bypasses this check. Similarly, `rm -rf ~/` is not caught since tilde expansion happens before the hook sees the command.

```bash
# Current (line 94):
*'rm -rf $HOME'*)

# Suggested: Also match expanded paths
*'rm -rf $HOME'*|*"rm -rf $HOME"*|*'rm -rf ~/'*)
# Note: Double-quoted $HOME expands to the actual path at pattern-match time.
```

### [MEDIUM] common.sh line:44 — `_read_team_key` truncates values containing `=` signs

`cut -d= -f2` returns only field 2 (between first and second `=`). Should be `-f2-` for field 2 onwards. Current callers use keys whose values don't contain `=`, but this is a latent bug.

```bash
# Current:
val=$(grep "^$2=" "$1" | cut -d= -f2)

# Suggested:
val=$(grep "^$2=" "$1" | cut -d= -f2-)
```

### [MEDIUM] common.sh line:38 — Non-jq JSON fallback fails on escaped quotes in field values

The grep/sed fallback `grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\""` cannot parse values containing escaped quotes (`\"`), nested objects, or array values. Systems without jq installed get silently incorrect parsing.

```bash
# Current:
echo "$INPUT" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed ...

# Suggested: Add python3 fallback before grep:
echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$field',''))" 2>/dev/null
```

### [MEDIUM] session-manager-wait.sh line:6 — Sourcing session.env executes arbitrary code

`source "${RUNTIME_DIR}/session.env"` executes the file as bash. The runtime dir is under `/tmp/doey/` which is user-writable but could be tampered with by another process. The `on-session-start.sh` hook correctly uses a `while IFS='=' read` loop instead.

```bash
# Current:
source "${RUNTIME_DIR}/session.env" 2>/dev/null || true

# Suggested: Parse with read loop:
while IFS='=' read -r key value; do
  value="${value%\"}" && value="${value#\"}"
  case "$key" in
    SESSION_NAME) SESSION_NAME="$value" ;; SM_PANE) SM_PANE="$value" ;;
  esac
done < "${RUNTIME_DIR}/session.env" 2>/dev/null || true
```

### [MEDIUM] watchdog-scan.sh line:528 — Extra tmux capture-pane per anomaly event

For each anomaly in `SNAPSHOT_EVENTS`, another `tmux capture-pane` call is made (line 528) despite the pane already being captured at lines 232/322 during the scan loop. This is avoidable IPC overhead.

```bash
# Current (line 528):
_a_capture_snippet=$(tmux capture-pane -t "${SESSION_NAME}:${TARGET_WINDOW}.${_a_pane}" -p -S -3 ...)

# Suggested: Store captures in indexed variables during scan loop and reuse them.
```

### [MEDIUM] post-tool-lint.sh line:76-77 — JSON escaping incomplete for control characters

The violation text is escaped for `\` and `"` but not tab, newline (beyond the awk join), or other JSON control characters. Malformed JSON could cause Claude Code to misinterpret the block response.

```bash
# Current:
reason_escaped=$(echo "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk ...)

# Suggested: Use jq when available:
if command -v jq >/dev/null 2>&1; then
  echo "{\"decision\": \"block\", \"reason\": $(echo "$reason" | jq -Rs '.')}"
fi
```

### [MEDIUM] on-session-start.sh line:93 — Appending to CLAUDE_ENV_FILE may duplicate exports

`cat >> "$CLAUDE_ENV_FILE"` appends. If the session-start hook runs multiple times for the same pane, duplicate `export` lines accumulate. Not harmful (last export wins in shell) but could confuse debugging.

```bash
# Current:
cat >> "$CLAUDE_ENV_FILE" << EOF

# Suggested: Use > instead of >> to overwrite, or guard with a sentinel.
```

### [MEDIUM] common.sh line:139 — PowerShell notification injection risk

See HIGH finding above (combined as the AppleScript path is now safe via heredoc). The PowerShell branch remains vulnerable to injection through single-quote escaping alone.

---

## LOW

### [LOW] stop-results.sh line:33 — Temp file `_tmpfile` not cleaned up on early exit

The `mktemp` at line 33 creates a temp file cleaned up at line 41, but the EXIT trap (line 14) only cleans `TMPFILE`, not `_tmpfile`. If the script exits between these lines, the temp file leaks.

```
Suggested: Add _tmpfile to the EXIT trap, or use TMPFILE for both purposes.
```

### [LOW] on-session-start.sh lines:74-86 — Lock not cleaned if script killed between mkdir and trap

If killed between `mkdir "$LOCK_DIR"` (line 74) and `trap '_skill_lock_cleanup' EXIT` (line 76), the lock directory persists. Subsequent sessions sleep 1s and skip skill sync forever until manual cleanup.

```
Suggested: Add a staleness check: if lock dir is older than 60s, remove and retry.
```

### [LOW] common.sh line:44 — `grep "^$2="` doesn't escape regex metacharacters in key name

If `$2` contains regex special chars (`.`, `*`, `[`), the grep pattern matches unintended lines. Current callers pass safe strings (`WATCHDOG_PANE`, `MANAGER_PANE`, etc.).

```
Suggested: Use grep -F for fixed-string matching.
```

### [LOW] stop-results.sh lines:75-85 — JSON values not escaped for special characters

The heredoc JSON embeds `$WINDOW_INDEX`, `$PANE_INDEX`, `$STATUS` without JSON escaping. If any contained double quotes or backslashes, the JSON would be malformed. Currently safe (values are constrained).

### [LOW] on-prompt-submit.sh line:30 — `${PROMPT:0:80}` may split multi-byte UTF-8 characters

Substring extraction by byte position can split multi-byte characters, producing invalid UTF-8 in the status file. Informational only.

### [LOW] on-pre-tool-use.sh line:28 — `grep -lq` has redundant flags

`-l` (list filenames) is redundant with `-q` (quiet). `-q` alone suffices.

### [LOW] common.sh line:130 — Background notification processes never waited on

`osascript ... &` and `notify-send ... &` create background processes that are never `wait`ed. They become zombies briefly until reaped by init. No practical impact but not clean.

---

## INFO

### [INFO] watchdog-scan.sh lines:329-402 — Redundant `case "$i" in *[!0-9]*) continue;;` guards

The `is_numeric "$i"` check at the loop top already validates `$i`. The `case "$i" in *[!0-9]*)` pattern appears **15+ times** in the loop body. Defensive but heavily duplicated.

### [INFO] watchdog-scan.sh — Overall complexity (593 lines, single file)

This file handles pane scanning, crash detection, boot detection, anomaly detection, CPU monitoring, hash comparison, state transitions, wave completion, snapshot writing, heartbeat, JSON state, anomaly escalation, and context pressure. Consider extracting helper functions to improve maintainability.

### [INFO] post-tool-lint.sh line:78 — Exit code 0 with `{"decision": "block"}` is correct

PostToolUse hooks use JSON output for blocking decisions, not exit codes. This differs from pre-tool-use convention (exit 2 = block) and should be documented for clarity.

### [INFO] on-pre-compact.sh — Well-structured context preservation

Good separation of worker/manager/watchdog state output. The stat-format detection (GNU vs BSD) on lines 19-22 is correctly handled for cross-platform support.

---

## Cross-Cutting Observations

### Atomic Writes
Hooks consistently use `mktemp + mv` for atomic writes, with fallback logging when mktemp fails (on-prompt-submit.sh, stop-status.sh, stop-results.sh). The `_atomic_write` helper in watchdog-scan.sh is a good pattern.

### Error Handling
Most hooks guard against missing files and failed tmux commands with `|| true` or `|| exit 0`. The grep-without-`|| true` bug in watchdog-scan.sh (line 521) is the critical exception.

### Bash 3.2 Compatibility
No violations detected. `printf -v`, `+=`, `<<<`, `${var//pat/rep}` are all bash 3.2 compatible. The post-tool-lint.sh hook correctly enforces this for future edits.

### Performance Hot Paths
- **on-pre-tool-use.sh** (runs before every tool call): Has a good fast path for managers/session_managers but workers still pay full init_hook cost.
- **watchdog-scan.sh** (runs every cycle): Has 2-3 redundant tmux captures per worker per cycle, plus the unused `pane_output` variable.

### Positive Patterns
1. Atomic writes via tmp+mv used consistently
2. jq-with-fallback pattern for JSON parsing
3. Role caching in `is_watchdog()`/`is_manager()`
4. Proper trap cleanup in stop-results.sh
5. Early exits for non-Doey sessions
6. Full bash 3.2 compliance maintained
