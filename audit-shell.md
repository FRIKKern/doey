# Shell Script Audit

Audited: 2026-03-22
Files: shell/doey.sh (3018 lines), shell/info-panel.sh (399 lines), shell/context-audit.sh (110 lines), shell/pane-border-status.sh (46 lines), shell/tmux-statusbar.sh (30 lines)

---

## shell/doey.sh

### HIGH

- [HIGH] line:1460-1462 — `_cleanup_old_session` deletes ALL `doey/team-*` branches globally, not just ones belonging to the current session. If multiple doey projects share a repo, this nukes branches from other sessions.
  Current: `git for-each-ref --format='%(refname:short)' 'refs/heads/doey/team-*' | while read -r b; do git branch -D "$b" 2>/dev/null || true; done`
  Suggested: Filter by project name or session, e.g. `refs/heads/doey/team-${window_index_prefix}-*`

- [HIGH] line:2378-2380 — Race condition in `_set_session_env`: concurrent callers read session.env and write to the same `.tmp` file. Last writer wins; intermediate changes are silently dropped. Same issue with `write_team_env` (line 136-148) using `team_${window_index}.env.tmp`.
  Current: `sed "..." "$file" > "$file.tmp" && mv "$file.tmp" "$file"`
  Suggested: Use unique temp files via `mktemp` or PID-suffixed names: `"${file}.tmp.$$"`

- [HIGH] line:1353 — Trap set in `_launch_session_core` runs `git worktree prune` on EXIT/INT/TERM, but background jobs from lines 1347-1351 are orphaned if the function exits abnormally before the trap is cleared on line 1373. The `jobs -p | xargs kill` in the trap should be sufficient but `disown` is never called so signals may propagate unpredictably.
  Suggested: Use explicit PIDs rather than `jobs -p`, and ensure the background subshell PID is captured.

### MEDIUM

- [MEDIUM] line:205 — Ambiguous short-circuit logic in `_worktree_safe_remove`. The expression `[ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ] && return 0` relies on left-to-right evaluation of `||` and `&&` (equal precedence, left-associative). While correct in bash, it's a maintenance trap — a reader might expect `||` to bind looser.
  Suggested: `{ [ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ]; } && return 0`

- [MEDIUM] line:1240 — `cd "$dir"` in `_launch_session_core` permanently changes the shell's working directory. Any code running after this function (e.g., `attach_or_switch`, `check_for_updates`) inherits the changed directory. This works by coincidence since `dir=$(pwd)` is usually the same, but breaks if invoked from a different directory.
  Suggested: Use `pushd/popd` or run in a subshell.

- [MEDIUM] line:898 — `_purge_audit_context` references `$PROJECT_DIR` which was set as a shell variable (not exported) in `doey_purge` at line 1080. This implicit global coupling means the function silently fails or scans the wrong directory if called from any other context.
  Suggested: Pass `$PROJECT_DIR` as a function parameter.

- [MEDIUM] line:1604,1606,2379,2673-2674,2685-2686 — All `sed -i ''` calls use macOS (BSD) sed syntax. GNU sed interprets `sed -i '' 's/...'` differently (empty string becomes backup suffix, next arg becomes the script). Cross-platform portability is broken.
  Suggested: Use a temp file + mv pattern, or detect sed flavor at startup.

- [MEDIUM] line:2816 — `[[ "$open" == true ]] && open "${project_dir}/index.html" 2>/dev/null || true` — The `|| true` applies to the entire chain, not just the `open` command. If `$open` is false, `|| true` silences the false return. Functionally harmless here but misleading.
  Suggested: `if [[ "$open" == true ]]; then open "${project_dir}/index.html" 2>/dev/null || true; fi`

- [MEDIUM] line:1118 — `trap "rm -f '$list_file'" RETURN` uses single quotes inside double quotes. If `mktemp` ever returns a path with single quotes, the trap breaks. Unlikely but defensive coding would use `$()` with proper escaping.
  Suggested: `trap "rm -f $(printf '%q' "$list_file")" RETURN`

### LOW

- [LOW] line:487,2657,2667 — `kill -- -"$pane_pid"` sends SIGTERM to the entire process group. If the PID has been recycled, this kills an unrelated process group. The `2>/dev/null || true` suppresses errors but doesn't prevent damage.
  Suggested: Verify the process is still a tmux child before killing.

- [LOW] line:490,1311,2037,2217-2218 — Hardcoded `sleep` values (1, 2, 3 seconds) used for synchronization. In slow environments (CI, loaded machines), these may be insufficient; in fast environments, they waste time.
  Suggested: Poll for readiness instead of sleeping fixed durations.

- [LOW] line:2311 — `[ -n "$pane_pid" ] && pkill -P "$pane_pid" 2>/dev/null || true` — Same ambiguous precedence as line 205. The `|| true` catches failures from both the test and pkill.
  Suggested: `if [ -n "$pane_pid" ]; then pkill -P "$pane_pid" 2>/dev/null || true; fi`

- [LOW] line:92 — `printf "${indent}${DIM}Doey hooks + skills installed${RESET}\n"` — Format string contains variables. If `$indent` contained `%s` or similar, printf would interpret them. Use `printf '%b' "..."` or `printf '%s' "$var"`.
  Suggested: `printf '%b\n' "${indent}${DIM}Doey hooks + skills installed${RESET}"`

- [LOW] line:1933 — `(( now - last_ts < 86400 ))` — Arithmetic evaluation. If `last_ts` contains non-numeric content (corrupted file), this produces a confusing error.
  Suggested: Validate `last_ts` is numeric before arithmetic.

- [LOW] line:2762 — `local last8="${test_id: -8}"` — Note the space before `-8`. This is required to avoid ambiguity with `${var:-default}`. Correct but fragile — removing the space changes meaning silently.

---

## shell/info-panel.sh

### MEDIUM

- [MEDIUM] line:37,43 — `eval "_ENV_${_ref_k}=''"` and `eval "_ENV_${_ref_k}=\"\$_ref_val\""` use `eval` with key names read from env files. If a malformed env file contains a key like `FOO;rm -rf /`, the eval executes it. The files are controlled by Doey, but defense-in-depth would validate key names.
  Suggested: Validate `_ref_k` matches `[A-Z_][A-Z0-9_]*` before eval.

- [MEDIUM] line:247-253 — `eval "TEAM_WT_DIR_${TEAM_LINE_COUNT}=\"${_ENV_WORKTREE_DIR}\""` — If `_ENV_WORKTREE_DIR` contains double quotes or shell metacharacters (e.g., paths with spaces and quotes), the eval breaks or executes unintended code.
  Suggested: Use `printf -v` instead: `printf -v "TEAM_WT_DIR_${TEAM_LINE_COUNT}" '%s' "$_ENV_WORKTREE_DIR"`

### LOW

- [LOW] line:1 — Shebang is `#!/bin/bash` while all other scripts use `#!/usr/bin/env bash`. Minor inconsistency.
  Suggested: Use `#!/usr/bin/env bash` for consistency.

- [LOW] line:100 — `visible_len()` forks a `sed` subprocess per call. Called multiple times per render cycle (every 5 minutes), causing unnecessary process spawning.
  Suggested: Use bash parameter expansion to strip ANSI codes if performance matters: `s="${1//$'\033['[0-9;]*m/}"; printf '%d' "${#s}"`

- [LOW] line:323 — `_color_idx=$((RANDOM % 6))` — Random title color changes every 5 minutes. Cosmetic but potentially distracting in production.

---

## shell/context-audit.sh

### LOW

- [LOW] line:22 — `if $USE_COLOR && [[ -t 1 ]]; then` expands `$USE_COLOR` as a bare command (`true` or `false`). While functional, it's an anti-pattern — if `USE_COLOR` were set to an unexpected value, it would execute as a command.
  Suggested: `if [ "$USE_COLOR" = "true" ] && [[ -t 1 ]]; then`

- [LOW] line:42,95,99,103-106 — `printf "${WARN}..."` and similar use variables in the format string. If any variable contains `%`, printf interprets it. Use `%b` format specifier.
  Suggested: `printf '%b\n' "${WARN}...${RESET}"`

---

## shell/pane-border-status.sh

No issues found. Clean, defensive code with proper error handling.

---

## shell/tmux-statusbar.sh

No issues found. Clean and efficient (single awk pass for counting).

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0     |
| HIGH     | 3     |
| MEDIUM   | 9     |
| LOW      | 11    |
| **Total**| **23**|

### Top priorities:
1. **Branch deletion scope** (HIGH) — `_cleanup_old_session` deletes branches from all sessions
2. **Race condition in env file writes** (HIGH) — concurrent writes to `.tmp` files collide
3. **eval injection in info-panel.sh** (MEDIUM) — switch to `printf -v` for dynamic variable assignment
4. **sed -i portability** (MEDIUM) — macOS-only syntax in 6 locations
