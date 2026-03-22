# Hook Audit

Audited 12 files in `.claude/hooks/` on 2026-03-22.

---

## .claude/hooks/stop-notify.sh
- [HIGH] line:12 — **Hardcoded manager pane index `.0`**. Worker notification targets `$SESSION_NAME:$WINDOW_INDEX.0` but the actual manager pane is configurable via `MANAGER_PANE` in `team_*.env`. If `MANAGER_PANE != 0`, notifications go to the wrong pane.
  ```
  Current:  MGR_PANE="$SESSION_NAME:$WINDOW_INDEX.0"
  Suggested: Read MANAGER_PANE from team env file, e.g.:
    _mgr_idx=$(_read_team_key "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" MANAGER_PANE)
    MGR_PANE="$SESSION_NAME:$WINDOW_INDEX.${_mgr_idx:-0}"
  ```

## .claude/hooks/on-pre-tool-use.sh
- [HIGH] line:78-89 — **Command blocking uses simple substring matching**, bypassable with whitespace tricks (`git  push`), tab characters, backtick/variable expansion (`g"it" push`), or aliases. Defense-in-depth is limited.
  ```
  Current:  *"git push"*|*"git commit"*|...
  Suggested: Normalize whitespace before matching, or use regex with \s+
  ```
- [LOW] line:21 — **Redundant grep flags**: `grep -lq` combines `-l` (list filenames) with `-q` (suppress output). `-q` alone suffices since we only check exit code.
  ```
  Current:  grep -lq "^WATCHDOG_PANE=..."
  Suggested: grep -q "^WATCHDOG_PANE=..."
  ```

## .claude/hooks/watchdog-scan.sh
- [MEDIUM] overall — **Performance: heavy subprocess usage in hot path**. Each scan cycle spawns 5+ subprocesses per worker pane (`tmux display-message`, `tmux capture-pane`, `pgrep`, `ps`, `md5`/`md5sum`). With 6 workers, that's 30+ forks per cycle (every ~5-30s). Consider batching tmux queries via `tmux list-panes -F` for multiple fields at once.
- [MEDIUM] line:119 — **Fragile JSON parsing with sed/tr**. Strips all `{}",` then splits on commas. Safe only because state values are from a known enum, but will break silently if the format ever includes nested objects or commas in values.
  ```
  Current:  PREV_PAIRS=$(echo "$PREV_JSON" | sed 's/[{}"]//g' | tr ',' '\n')
  Suggested: Use jq when available with sed fallback, consistent with other hooks
  ```
- [MEDIUM] line:174 — **Non-atomic write to manager prev state file**. `echo "$PANE_STATE_0" > "$MGR_PREV_FILE"` could be read partially by another process. Other writes in this script use the `_atomic_write` helper — this one doesn't.
  ```
  Current:  echo "$PANE_STATE_0" > "$MGR_PREV_FILE"
  Suggested: _atomic_write "$MGR_PREV_FILE" "$PANE_STATE_0"
  ```
- [LOW] line:462-464 — **Fragile context percentage parsing**. Parses `Ctx` line from terminal capture with sed. Depends on Claude Code's exact output format — any format change will silently break the 60% threshold detection.

## .claude/hooks/common.sh
- [MEDIUM] line:113-120 — **Race condition in notification cooldown**. Two concurrent hooks could both read the old timestamp, both pass the 60s check, both send a notification, then both write the new timestamp. In practice unlikely since only the Session Manager calls this, but not formally synchronized.
  ```
  Current:  last_sent=$(cat "$cooldown_file" ...); now=$(date +%s); [ "$((now - last_sent))" -lt 60 ] && return 0; echo "$now" > "$cooldown_file"
  Suggested: Accept as cosmetic (duplicate desktop notification is harmless) or use a lockfile
  ```
- [LOW] line:38 — **`_read_team_key` returns all matching lines concatenated**. If a key appears multiple times in an env file, `grep "^$2="` returns all matches and `cut` processes all of them, producing concatenated values.
  ```
  Current:  val=$(grep "^$2=" "$1" | cut -d= -f2)
  Suggested: val=$(grep -m1 "^$2=" "$1" | cut -d= -f2)
  ```
- [LOW] line:131-132 — **PowerShell notification: single-quote escaping is incomplete**. The `${ps_body//\'/\'\'}` substitution handles `'` but not `$()` or other PowerShell special sequences inside the body. Low severity — local desktop notification, attacker would need control of assistant output text.

## .claude/hooks/on-session-start.sh
- [MEDIUM] line:81 — **Appends to CLAUDE_ENV_FILE without duplicate guard**. If this hook fires multiple times (e.g., session restart), the env file accumulates duplicate `export` lines. Functionally correct (last export wins) but wastes file size.
  ```
  Current:  cat >> "$CLAUDE_ENV_FILE" << EOF
  Suggested: Check for existing DOEY_RUNTIME export first, or use > instead of >>
  ```
- [LOW] line:70-78 — **Skill sync orphan cleanup could delete user-created `doey-*` directories**. Any skill directory matching `.claude/skills/doey-*/` in the target that doesn't exist in the source repo gets `rm -rf`'d. If a user creates a custom `doey-*` skill, it would be silently deleted on next session start.
- [LOW] line:20 — **Unusual `&&` as statement separator**: `value="${value%\"}" && value="${value#\"}"`. This works (assignment always succeeds) but is unconventional and could confuse readers.

## .claude/hooks/session-manager-wait.sh
- [LOW] line:6 — **Sources session.env directly**. `source "${RUNTIME_DIR}/session.env"` executes the file as bash code. If session.env is malformed or tampered, arbitrary code could run. Low risk since Doey generates this file.
- [LOW] line:17 — **TOCTOU on trigger file**. Between `[ -f "$TRIGGER" ]` and `rm -f "$TRIGGER"`, another process could also detect the trigger. Harmless since only one Session Manager should exist.

## .claude/hooks/watchdog-wait.sh
- [LOW] line:5 — **Default team window fallback to `1`**. `${1:-${DOEY_TEAM_WINDOW:-1}}` defaults to window 1 if no argument and no env var. Could watch the wrong team's trigger file in edge cases.

## .claude/hooks/on-prompt-submit.sh
- No significant issues found. Clean implementation with atomic writes via mktemp+mv pattern.

## .claude/hooks/on-pre-compact.sh
- No significant issues found. Properly handles missing files and empty state. Good use of `|| true` guards.

## .claude/hooks/post-tool-lint.sh
- No significant issues found. Comprehensive bash 3.2 compatibility checks. Self-exclusion on line 24 prevents false positives.

## .claude/hooks/stop-results.sh
- No significant issues found. Proper trap-based cleanup, atomic writes, and JSON escaping with jq/python3 fallback.

## .claude/hooks/stop-status.sh
- No significant issues found. Research enforcement is correct (exit 2 = block+feedback). Atomic status writes.

---

## Cross-Cutting Concerns

### Race Conditions Between Hooks
- **stop-status.sh + stop-results.sh + stop-notify.sh** all fire on worker stop. They write to different files (`*.status`, `*.json`, completion events, trigger files) so no direct collision. However, `stop-notify.sh` reads `results/pane_*.json` (line 17-22) that `stop-results.sh` writes — the read could see a partially-written file if the hooks run in close succession. In practice the atomic mv pattern in stop-results.sh mitigates this.
- **on-prompt-submit.sh + watchdog-scan.sh** both read/write `*.status` files. The prompt hook writes atomically (mktemp+mv), but the watchdog reads without locking. A read could see a stale value, causing a one-cycle delay in state detection. Acceptable.

### Bash 3.2 Compatibility
- **watchdog-scan.sh:33-36** uses `printf -v` which is bash 3.1+. Confirmed compatible.
- **watchdog-scan.sh:448** uses `+=` string concatenation which is bash 3.1+. Confirmed compatible.
- No instances of `declare -A/-n/-l/-u`, `mapfile`, `readarray`, `|&`, `&>>`, or `coproc` found. All hooks pass bash 3.2 compatibility.

### CLAUDE.md Documentation Drift
- CLAUDE.md lists `stop-notify-manager.sh` and `stop-notify-session-manager.sh` as separate hooks, but they have been merged into the unified `stop-notify.sh`. The documentation should be updated.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH     | 2 |
| MEDIUM   | 5 |
| LOW      | 8 |
| **Total**| **15** |

**Top priority fixes:**
1. `stop-notify.sh:12` — Hardcoded manager pane (could send notifications to wrong pane)
2. `on-pre-tool-use.sh:78-89` — Command blocking bypass via whitespace (security guard weakness)
3. `watchdog-scan.sh` — Performance optimization opportunity (batch tmux queries)
