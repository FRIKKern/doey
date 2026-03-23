# Hook Scripts Audit Report

**Date:** 2026-03-23 (second pass)
**Scope:** All 12 files in `.claude/hooks/`
**Auditor:** Worker 3 (hook-audit_0323)

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 2 |
| MEDIUM | 6 |
| LOW | 8 |

---

## HIGH

### [HIGH] common.sh line:44 — `_read_team_key` truncates values containing `=`

`cut -d= -f2` only returns the second field. Values with `=` in them are silently truncated (e.g., `WORKTREE_DIR=/path/to/x=y`). Compare with `_env_val` in `on-session-start.sh:15` which correctly uses `-f2-`.

```bash
# Current:
val=$(grep "^$2=" "$1" | cut -d= -f2)
```

```bash
# Suggested:
val=$(grep "^$2=" "$1" | cut -d= -f2-)
```

This function is called by `is_watchdog`, `is_manager`, `get_sm_pane`, and `stop-notify.sh`. Any env value with `=` causes silent data corruption.

---

### [HIGH] on-pre-tool-use.sh line:53 — `rm -rf $HOME` check matches literal string only

The case pattern `*'rm -rf $HOME'*` uses single quotes, matching only the literal text `$HOME`. The AI tool input JSON contains the command before shell expansion, so this might match when the AI literally writes `$HOME`. However, if the AI writes the expanded path (e.g., `rm -rf /Users/pelle`), all three destructive-rm patterns are bypassed.

```bash
# Current:
*"rm -rf /"*|*"rm -rf ~"*|*'rm -rf $HOME'*)
```

```bash
# Suggested: Add expanded home directory patterns
*"rm -rf /"*|*"rm -rf ~"*|*'rm -rf $HOME'*|*"rm -rf /Users/"*|*"rm -rf /home/"*)
```

---

## MEDIUM

### [MEDIUM] watchdog-scan.sh line:200 — `pane_output` captured but never used

Line 200 captures `tmux capture-pane -S -30` into `pane_output`, but this variable is never referenced anywhere. Separate captures are done on lines 232 (`_boot_capture`, `-S -5`), 322 (`CAPTURE`, `-S -5`), and 528 (anomaly snippet, `-S -3`). This wastes one tmux IPC call per worker pane per scan cycle.

```bash
# Current (line 200):
pane_output=$(tmux capture-pane -t "$PANE_REF" -p -S -30 2>/dev/null) || pane_output=""
```

```
Suggested: Remove line 200 entirely, or consolidate captures:
capture once with -S -30 and derive shorter subsets via tail.
```

---

### [MEDIUM] common.sh line:36-38 — `parse_field` grep fallback doesn't handle escaped quotes

The grep-based fallback matches `"field":"value"` but breaks on values containing `\"` (escaped quotes). For example, a tool input with `"command": "echo \"hello\""` would truncate at the first `\"`.

```bash
# Current:
echo "$INPUT" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
```

No easy fix without jq. Mitigated by jq being the primary path — this only fires when jq is unavailable.

---

### [MEDIUM] on-session-start.sh line:63 — DOEY_ROLE set at session level, races between panes

`tmux set-environment -t "$SESSION_NAME" DOEY_ROLE "$ROLE"` sets the role in session-wide tmux environment. When multiple panes start simultaneously (during grid launch), the last pane to execute overwrites the session-level value. The per-process CLAUDE_ENV_FILE export on line 98 is correct per-pane, so the practical impact is limited to any code reading DOEY_ROLE from tmux env.

```
Suggested: Remove line 63 — DOEY_ROLE is already correctly exported
per-pane via CLAUDE_ENV_FILE on line 98.
```

---

### [MEDIUM] stop-results.sh line:33-41 — `_tmpfile` not covered by EXIT trap

The non-`timeout` fallback creates `_tmpfile=$(mktemp)` for git diff output. If the script is killed between lines 33 and 41, this file leaks. The EXIT trap on line 14 only cleans `$TMPFILE`, not `$_tmpfile`.

```bash
# Suggested: Add to trap or use a deterministic temp path in RUNTIME_DIR.
```

---

### [MEDIUM] session-manager-wait.sh line:6 — Sourcing session.env as executable shell code

`source "${RUNTIME_DIR}/session.env"` executes file contents as shell commands. If corrupted or tampered with, arbitrary code runs. The file is doey-generated so risk is low, but `on-session-start.sh` correctly uses `while IFS='=' read` for the same file — inconsistent patterns.

```bash
# Suggested: Use read-loop parsing (like on-session-start.sh line:19-26):
while IFS='=' read -r key value; do
  value="${value%\"}"; value="${value#\"}"
  case "$key" in
    SESSION_NAME) SESSION_NAME="$value" ;;
    SM_PANE) SM_PANE="$value" ;;
  esac
done < "${RUNTIME_DIR}/session.env"
```

---

### [MEDIUM] watchdog-scan.sh line:528 — Extra tmux capture-pane per anomaly event

For each anomaly event in the post-scan persistence block, `tmux capture-pane` is called again even though the pane was already captured during the scan loop (line 232). The captures could be cached during the scan phase.

```bash
# Current:
_a_capture_snippet=$(tmux capture-pane -t "${SESSION_NAME}:${TARGET_WINDOW}.${_a_pane}" -p -S -3 ...)
```

---

## LOW

### [LOW] watchdog-scan.sh lines:223,329,381,400-402,406,486-494 — Redundant numeric guards

Throughout the worker scan loop, `$i` is validated by `is_numeric "$i" || continue` at line 183/399. The repeated `case "$i" in *[!0-9]*) continue ;; esac` guards (~15 instances) are dead code.

```
Suggested: Remove redundant guards; the loop-top is_numeric check is sufficient.
```

---

### [LOW] on-session-start.sh line:20 / watchdog-scan.sh line:86,103,457 — Misleading `&&` between assignments

Pattern `value="${value%\"}" && value="${value#\"}"` uses `&&` where `;` is more appropriate. Parameter expansion never fails, so both sides always execute. Reads as if the second is conditional on the first.

```
Suggested: Use `;` or separate lines instead of `&&`.
```

---

### [LOW] on-pre-tool-use.sh line:28 — `grep -lq` flags are redundant

`-l` (list matching files) output is suppressed by `-q` (quiet). `-q` alone suffices and is marginally faster.

```bash
# Current:  grep -lq "^WATCHDOG_PANE=..." "${RUNTIME_DIR}"/team_*.env
# Suggested: grep -q "^WATCHDOG_PANE=..." "${RUNTIME_DIR}"/team_*.env
```

---

### [LOW] on-prompt-submit.sh line:11-15 / stop-status.sh line:21-25 — No trap for mktemp cleanup

Both hooks use `mktemp` for atomic writes but set no EXIT trap. If killed between mktemp and mv, temp files leak in `$RUNTIME_DIR/status/`.

```
Suggested: Add trap, or use deterministic temp name (e.g., ${STATUS_FILE}.tmp).
```

---

### [LOW] common.sh line:130-136 — Background notification processes not waited

`osascript` and `notify-send` are launched with `&` but never waited or reaped. Harmless for one-shot notifications but creates brief zombie entries.

---

### [LOW] stop-results.sh line:20-24 — Tool count from screen scraping is unreliable

Counting tool calls by pattern-matching captured output (looking for `Read(`, `Edit(`) is fragile. Undercounts if output scrolls beyond the 80-line capture window.

---

### [LOW] on-pre-tool-use.sh line:57 — Worker tmux error message is misleading

Error says "Only the Window Manager can do this" but Watchdog can also use limited send-keys. Minor UX issue.

---

### [LOW] watchdog-scan.sh line:120-131 — JSON parsing via sed is fragile

`sed 's/[{}"]//g' | tr ',' '\n'` works only for the specific `{"N":"STATE"}` format. Currently safe because the JSON is self-generated (line 507-516), but any format change would break silently.

---

## Bash 3.2 Compatibility

All 12 hook scripts checked. **No violations found.**

Features verified absent:
- `declare -A/-n/-l/-u` — not used
- `printf '%(%s)T'` — not used
- `mapfile`/`readarray` — not used
- `|&` / `&>>` — not used
- `coproc` — not used
- `BASH_REMATCH` — not used
- `printf -v` — used in watchdog-scan.sh (available since bash 3.1, safe)
- `+=` string concatenation — used in watchdog-scan.sh (available since bash 3.1, safe)

---

## Exit Code Correctness

| Hook | Expected Exit | Actual | Correct? |
|------|---------------|--------|----------|
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
| Directory lock (mkdir) | on-session-start (skill sync) | Correct, minor stale-lock risk on kill |
| File-based triggers | watchdog-wait, session-manager-wait | Correct, TOCTOU gap is benign |
| Status file reads without locking | All hooks reading `.status` files | Acceptable — atomic writes ensure no partial reads |
| Session-level tmux env | on-session-start DOEY_ROLE | Race exists but mitigated by per-process env |

---

## Performance Notes

1. **on-pre-tool-use.sh** is well-optimized for the hot path: cached DOEY_ROLE avoids tmux calls, worker fast path skips `init_hook` entirely.
2. **watchdog-scan.sh** has 3-4 `tmux capture-pane` calls per worker pane per cycle (lines 200, 232, 322, plus 528 for anomalies). Consolidating to 1 capture per pane would reduce tmux IPC overhead significantly on large grids.
3. **common.sh `_ensure_dirs`** correctly uses a sentinel file (`.dirs_created`) to skip directory checks after first run.
4. **common.sh `init_hook`** makes 2 tmux calls (show-environment + display-message) — unavoidable for pane identity.

---

## Positive Patterns Observed

1. **Atomic writes** via tmp+mv used consistently across hooks
2. **Graceful degradation**: jq-with-grep-fallback pattern throughout
3. **Role caching**: `is_watchdog()`/`is_manager()` cache results in `_DOEY_IS_WD`/`_DOEY_IS_MGR`
4. **Trap cleanup**: stop-results.sh properly cleans temp files on EXIT
5. **Early exits**: Non-Doey sessions exit immediately (`[ -z "${TMUX_PANE:-}" ] && exit 0`)
6. **Bash 3.2 compliance**: Zero violations across all 12 scripts
7. **Hot path optimization**: on-pre-tool-use.sh has dedicated fast paths for workers and managers
