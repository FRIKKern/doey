# Shell Script Audit — 2026-03-23

Audited: `shell/doey.sh`, `shell/info-panel.sh`, `shell/context-audit.sh`, `shell/pane-border-status.sh`, `shell/tmux-statusbar.sh`

---

## doey.sh (3031 lines)

### Bash 3.2 Compatibility

[MEDIUM] doey.sh:307 — `printf -v` with dynamic variable name
  Current: `printf -v "WDG_SLOT_${_wd_i}" '%s' "$_pane"`
  Note: `printf -v` itself is bash 3.1+, but dynamic variable names in printf -v (`printf -v "$varname"`) work in bash 3.2. This is safe but worth noting — some minimal shells don't support it. Low practical risk on macOS.

[LOW] doey.sh:425,522 — `local -a` array declaration
  Current: `local -a running_sessions=()` and `local -a names=() paths=() statuses=()`
  Note: `local -a` works in bash 3.2. Not a violation, just flagging for awareness.

[MEDIUM] doey.sh:737-739 — `&>/dev/null` used in 8 places
  Current: `if command -v pbcopy &>/dev/null; then ...`
  Note: `&>` is technically bash 4.0+ syntax. In practice, bash 3.2 on macOS supports it as an extension, but it's not POSIX and could fail on strict shells. Safer: `>/dev/null 2>&1`
  Suggested: Replace all `&>/dev/null` with `>/dev/null 2>&1`

### Security / Injection Risks

[HIGH] info-panel.sh:247-253 — eval with env file data susceptible to injection
  Current: `eval "TEAM_WIN_${TEAM_LINE_COUNT}=\"${W}\""` (and similar for _ENV_WORKTREE_DIR, etc.)
  Risk: If a team env file contains a maliciously crafted value (e.g., `WORKTREE_DIR="$(rm -rf /)"`) the eval will execute it. The env files are written by doey itself, so the risk is low in practice, but defense-in-depth says sanitize before eval.
  Suggested: Validate/sanitize values before eval, or use `printf -v` instead of eval where possible.

[MEDIUM] doey.sh:2391 — sed-based _set_session_env vulnerable to value injection
  Current: `sed "s/^${field}=.*/${field}=\"${value}\"/" ...`
  Risk: If `$value` contains sed metacharacters (`/`, `&`, `\`), the sed command will break or inject. Values like worktree paths could contain these characters.
  Suggested: Escape sed special chars in `$value`, or use awk, or write a proper key=value update function.

[MEDIUM] doey.sh:765 — JSON injection in ensure_project_trusted
  Current: `printf '{"trustedDirectories": ["%s"]}\n' "$dir" > "$claude_settings"`
  Risk: If `$dir` contains `"` or `\`, the JSON output is malformed. Unlikely for real paths but not impossible (e.g., user creates a dir with special chars).
  Suggested: Escape JSON special characters in `$dir`, or only use the jq path.

### Error Handling

[HIGH] doey.sh:1354 — EXIT trap set mid-function, never properly cleaned up
  Current: `trap 'jobs -p | xargs kill 2>/dev/null; git worktree prune 2>/dev/null' EXIT INT TERM`
  Then at line 1374: `trap - EXIT INT TERM`
  Risk: If the script errors between these lines (due to `set -e`), the trap will fire and `git worktree prune` runs in whatever directory happens to be current. Also, `jobs -p | xargs kill` may kill unrelated background jobs if the script is sourced.

[MEDIUM] doey.sh:1241 — `cd "$dir"` changes global working directory
  Current: `cd "$dir"` inside `_launch_session_core`
  Risk: This changes the cwd for the rest of the script. If any subsequent function assumes the original cwd, it will break silently. Should use a subshell or pushd/popd.

[MEDIUM] doey.sh:1983 — Same `cd "$dir"` issue in `launch_session_dynamic`

[LOW] doey.sh:1081 — Global variable `PROJECT_DIR` set inside `doey_purge`
  Current: `PROJECT_DIR="$dir"`
  Risk: Leaks state to `_purge_audit_context` (line 899 uses it). Works, but fragile coupling through a global.

### Race Conditions

[MEDIUM] doey.sh:2389-2392 — Non-atomic session.env updates in _set_session_env
  Current: `sed ... > "$_tmp" && mv "$_tmp" ...`
  Risk: Uses PID in temp filename (`$$`) which is unique per-process, but if two concurrent `_set_session_env` calls run (e.g., from parallel team additions), they read the same original file and the second `mv` overwrites the first's changes. The `mv` itself is atomic, but the read-modify-write cycle is not.
  Suggested: Use a lock file or flock.

[MEDIUM] doey.sh:2028-2029 — Appending to session.env without locking
  Current: `echo "WDG_SLOT_${_si}=..." >> "${runtime_dir}/session.env"`
  Risk: Multiple concurrent appends could interleave. Low risk during initial setup (single-threaded), but the function is also called from `add_dashboard_watchdog_slot` which could race.

[LOW] doey.sh:367 — Appending to PROJECTS_FILE without locking
  Current: `echo "${name}:${dir}" >> "$PROJECTS_FILE"`
  Risk: Two concurrent `doey init` calls could both pass the duplicate check and append.

### Dead Code / Unused Functions

[LOW] doey.sh:2125-2177 — `rebalance_grid_layout` + `_layout_checksum` are complex (50+ lines) but only called from `doey_add_column` and `doey_remove_column`. Not dead, but the custom layout checksum function duplicates what `tmux select-layout tiled` could approximate.

[LOW] doey.sh:1967-1975 — `launch_session_headless` is only called from `run_test`. If E2E testing is removed, this becomes dead code.

### Logic Issues

[HIGH] doey.sh:206 — `_worktree_safe_remove` short-circuit logic bug
  Current: `[ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ] && return 0`
  Risk: Due to operator precedence, this is parsed as `[ -z "$worktree_dir" ] || ([ ! -d "$worktree_dir" ] && return 0)`. If `$worktree_dir` is non-empty but the directory doesn't exist, only the `return 0` is conditional on the second test — but if `$worktree_dir` is empty, it returns 0 correctly. The OR grouping means: if worktree_dir is empty, the first test is true so the whole line short-circuits to `&& return 0`. Actually this works because `||` and `&&` have equal precedence in shell and associate left-to-right: `A || B && C` = `(A || B) && C`. So if A is true, `(A || B)` is true, then `C` runs. If A is false and B is true, same. If both false, C doesn't run. This is **correct but confusing** — the intent is "if either condition, return 0" and it works, but it's fragile and non-obvious.
  Suggested: Use `{ [ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ]; } && return 0` for clarity.

[MEDIUM] doey.sh:2691 — Pane index filtering logic may skip valid panes
  Current: `[ "$_pane_idx" = "0" ] || [ "$_pane_idx" = "1" ] && continue`
  Same precedence issue as above: `A || B && C` = `(A || B) && C`. This means pane 0 AND pane 1 are both skipped (which is the intent — skip info panel and session manager). Works correctly but is confusing.

[MEDIUM] doey.sh:2830 — Incorrect `|| true` grouping
  Current: `[[ "$open" == true ]] && open "${project_dir}/index.html" 2>/dev/null || true`
  Risk: The `|| true` applies to the entire `[[ ]] && open ...` chain, not just the `open` command. If `$open` is false, the `&&` short-circuits, and `|| true` runs (harmless). If `$open` is true and `open` fails, `|| true` prevents error exit. Works correctly for the intended purpose but the grouping is misleading.

[MEDIUM] doey.sh:2322 — Missing quotes around `||` in pkill line
  Current: `[ -n "$pane_pid" ] && pkill -P "$pane_pid" 2>/dev/null || true`
  Risk: Same precedence issue. If `$pane_pid` is non-empty and pkill fails, `|| true` catches it. If `$pane_pid` is empty, `|| true` runs (harmless). Works but reads as "either pkill or true" rather than "try pkill, ignore failure".

### Missing Error Handling

[MEDIUM] doey.sh:1533 — `git pull` failure doesn't abort update
  Current: `git -C "$repo_dir" pull || printf "  ${WARN}git pull failed...${RESET}\n"`
  Risk: If pull fails (e.g., merge conflict), the script continues with reinstall from stale code. The warning is printed but easy to miss.

[LOW] doey.sh:2521 — `tmux new-window` failure not checked
  Current: `tmux new-window -t "$session" -c "$dir"` (in `add_dynamic_team_window`)
  Risk: If tmux new-window fails (e.g., session killed), the function continues and `tmux display-message` on next line will fail with a confusing error.

[LOW] doey.sh:491 — `sleep 1` in _kill_doey_session is a heuristic
  Current: After sending kills, `sleep 1` before killing the tmux session.
  Risk: On slow systems or with many panes, processes may not have exited yet. Not a bug but can cause "pane still running" warnings.

### Style / Maintainability

[LOW] doey.sh:1636,1711 — Variable `team_env` declared with `local` inside a for loop
  Current: `local team_env=...` inside `for tw in $team_windows`
  Note: In bash, `local` inside a loop still scopes to the function, not the loop iteration. Works but is misleading — the `local` declaration only needs to happen once.

[LOW] doey.sh:899 — `_purge_audit_context` uses `PROJECT_DIR` global set by caller
  Current: References `$PROJECT_DIR` which is set in `doey_purge` at line 1081.
  Suggested: Pass as a parameter for clarity.

---

## info-panel.sh (398 lines)

[LOW] info-panel.sh:1 — Uses `#!/bin/bash` instead of `#!/usr/bin/env bash`
  Note: Minor inconsistency. All other scripts use `#!/usr/bin/env bash`. Not a bug — `/bin/bash` is always available on macOS.

[LOW] info-panel.sh:3 — Missing `set -e` (only `set -uo pipefail`)
  Note: Intentional per comment "No -e: tmux callbacks must not crash on transient failures" — but this is the info-panel, not a tmux callback. It's a long-running dashboard loop. Omitting `-e` is arguably fine here since the loop should be resilient.

[MEDIUM] info-panel.sh:247-253 — eval injection risk with env file values (described above)
  Current: Values from env files are interpolated into eval strings without sanitization.
  Suggested: Sanitize or use indirect references.

[LOW] info-panel.sh:100 — sed ANSI strip regex may miss some sequences
  Current: `sed $'s/\033\\[[0-9;]*m//g'`
  Note: Doesn't handle `\033[38;2;R;G;Bm` (24-bit color) or `\033[K` (clear line). Fine for current usage since doey only uses basic ANSI codes.

[LOW] info-panel.sh:397 — `sleep 300` (5 minutes) between refreshes
  Note: Documented behavior. Could miss status changes for several minutes. Consider making configurable.

---

## context-audit.sh (109 lines)

[LOW] context-audit.sh:69 — `[[ =~ ]]` regex match used
  Current: `[[ "$content" =~ $ALLOWLIST_RE ]] && continue`
  Note: Uses `=~` but does NOT use capture groups (`BASH_REMATCH`), so this is bash 3.2 compatible. The regex variable is unquoted on the right side of `=~` which is correct (quoted would match literally).

No significant issues found. Clean, well-structured script.

---

## pane-border-status.sh (45 lines)

[LOW] pane-border-status.sh:3 — Missing `set -e` (only `set -uo pipefail`)
  Note: Intentional — tmux callbacks must not crash.

No other issues. Clean script.

---

## tmux-statusbar.sh (29 lines)

[LOW] tmux-statusbar.sh:11 — Uses `shopt -s nullglob`
  Note: This is a bashism, not available in pure POSIX sh. Fine since the shebang is `#!/usr/bin/env bash`.

No other issues. Clean script.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0     |
| HIGH     | 3     |
| MEDIUM   | 13    |
| LOW      | 14    |
| **Total**| **30**|

### Top Priority Fixes

1. **[HIGH] eval injection in info-panel.sh** — Sanitize env file values before eval, or switch to `printf -v`.
2. **[HIGH] EXIT trap in _launch_session_core** — Scope the trap more tightly or use a subshell.
3. **[HIGH] _worktree_safe_remove precedence confusion** — Add braces for clarity: `{ A || B; } && C`.
4. **[MEDIUM] &>/dev/null bash 3.2 compat** — Replace with `>/dev/null 2>&1` (8 occurrences).
5. **[MEDIUM] sed injection in _set_session_env** — Escape special chars in sed replacement strings.
6. **[MEDIUM] Race conditions in session.env updates** — Consider flock or atomic write patterns.
