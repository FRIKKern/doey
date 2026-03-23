# Shell Audit Report — 2026-03-23 (Worker 1 Deep Audit)

Audited: `shell/doey.sh` (3084 lines), `shell/info-panel.sh` (401 lines), `shell/context-audit.sh` (109 lines), `shell/pane-border-status.sh` (45 lines), `shell/tmux-statusbar.sh` (29 lines).

All files pass `bash -n` syntax check. No forbidden bash 3.2 constructs found (`declare -A/-n/-l/-u`, `mapfile`, `readarray`, `|&`, `&>>`, `coproc`, `printf '%(%s)T'`, `BASH_REMATCH` capture groups).

---

## Findings

### MEDIUM

**[MEDIUM] doey.sh:2069 — Race condition in parallel `add_dynamic_team_window` calls**
```
Current: ( add_dynamic_team_window "$session" "$runtime_dir" "$dir" ) &
```
Running in subshells means concurrent writes to `session.env`. `_set_session_env` uses a mkdir-based lock, but `_register_team_window` does a read-modify-write of `TEAM_WINDOWS` — two processes can read the same value before either writes, losing a team registration.
```
Suggested: Serialize team window creation or use atomic append instead of read-modify-write.
```

**[MEDIUM] doey.sh:2443-2444 — Incomplete sed escape in `_set_session_env`**
```
Current: _escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
```
The character class `[&/\]` should be `[&/\\]` to properly escape literal backslashes. Values with backslashes in paths (unlikely but possible on some systems) would produce corrupt sed replacements.
```
Suggested: _escaped_value=$(printf '%s' "$value" | sed 's/[&/\\]/\\&/g')
```

**[MEDIUM] doey.sh:330 — `source` in subshell for validation executes side effects**
```
Current: if ! (source "$session_env") 2>/dev/null; then
```
If `session_env` contains command substitutions, they execute during validation. The fallback parser (`IFS='='` read loop) also drops values containing multiple `=` signs. Low risk since files are self-generated.
```
Suggested: Use `bash -n "$session_env"` for syntax-only validation.
```

**[MEDIUM] doey.sh:1361 — Trap in `_launch_session_core` clobbers caller traps**
```
Current: trap 'jobs -p | xargs kill 2>/dev/null; git worktree prune 2>/dev/null' EXIT INT TERM
```
At line 1382: `trap - EXIT INT TERM` clears all EXIT/INT/TERM traps. If a caller had set its own traps, they're now gone. No current callers set traps before this, but fragile for future changes.

**[MEDIUM] doey.sh:906 — `PROJECT_DIR` used in `_purge_audit_context` without parameter**
```
Current: for f in "$PROJECT_DIR"/.claude/skills/doey-*/SKILL.md; do
```
Relies on `PROJECT_DIR` being set by `doey_purge` at line 1088. Tight coupling — if `_purge_audit_context` were called from elsewhere, it would use stale or empty `PROJECT_DIR`.
```
Suggested: Pass PROJECT_DIR as a parameter to _purge_audit_context.
```

**[MEDIUM] doey.sh:1623-1625 — `sed -i ''` is macOS-only (not portable to Linux)**
```
Current: sed -i '' 's/^WATCHDOG_PANE=.*/WATCHDOG_PANE="0.2"/' "${runtime_dir}/session.env"
```
BSD `sed -i ''` vs GNU `sed -i`. Since the project targets macOS bash 3.2, this is intentional but limits portability. All other file rewrites use the portable `sed > tmp && mv` pattern (e.g., line 2445).
```
Suggested: Use the same sed > tmp && mv pattern used elsewhere for consistency.
```

**[MEDIUM] doey.sh:571 — Nested function `_menu_select` inside `show_menu` leaks to global scope**
```
Current: _menu_select() { ... }  # defined inside show_menu
```
In bash, functions defined inside other functions are global. Not a bug, but the function persists after `show_menu` returns, polluting the namespace.

### LOW

**[LOW] doey.sh:704 — Unquoted variable used as command**
```
Current: local _s="tmux set-option -t $session"
         $_s pane-border-status top
```
If `$session` contained spaces, word splitting would break. Session names are sanitized so this is safe in practice but violates defensive coding norms.

**[LOW] doey.sh:2744 — Subtle operator precedence in compound condition**
```
Current: [ "$_pane_idx" = "0" ] || [ "$_pane_idx" = "1" ] && continue
```
Evaluates as `(A || B) && continue` due to shell precedence. The logic is correct for skipping panes 0 and 1, but reads ambiguously. Using `if [ ... ] || [ ... ]; then continue; fi` would be clearer.

**[LOW] info-panel.sh:1 — Shebang inconsistency: `#!/bin/bash` vs `#!/usr/bin/env bash`**
```
Current: #!/bin/bash
```
All other scripts use `#!/usr/bin/env bash`. Minor inconsistency.

**[LOW] info-panel.sh:3 — Missing `-e` flag not fully justified**
```
Current: set -uo pipefail
         # No -e: tmux callbacks must not crash on transient failures
```
`info-panel.sh` is a long-running dashboard loop, not a tmux callback. Missing `-e` means subcommand errors are silently swallowed. The `while true` + `continue` structure mitigates this but errors inside rendering logic would be hidden.

**[LOW] doey.sh:40-41 — Side effects at module load time**
```
Current: mkdir -p "$(dirname "$PROJECTS_FILE")"
         touch "$PROJECTS_FILE"
```
These run on every invocation including `doey --help`. Minor performance cost, no functional issue.

**[LOW] doey.sh:1248 — `cd "$dir"` changes global working directory**
```
Current: cd "$dir"  # in _launch_session_core
```
Also at line 1991 in `launch_session_dynamic`. Changes cwd for the rest of the script. Not a bug since launch is the final action, but could cause issues if code is added after launch.

**[LOW] doey.sh:498/2856 — Hard-coded sleep durations for process synchronization**
```
Current: sleep 1   (line 498, after killing processes)
         sleep 30  (line 2856, boot wait in test runner)
```
Fixed durations may be insufficient on slow systems or excessive on fast ones. Polling for readiness would be more robust but adds complexity.

**[LOW] doey.sh:2363 — Missing grouping around compound command**
```
Current: [ -n "$pane_pid" ] && pkill -P "$pane_pid" 2>/dev/null || true
```
Evaluates as `(A && B) || C`. If `pkill` fails (returns non-zero), `|| true` catches it — which is the intent. But if `[ -n "$pane_pid" ]` is false, `|| true` also fires (harmlessly). Correct behavior but confusing to read.

**[LOW] doey.sh:1952 — Arithmetic expression with unvalidated input**
```
Current: (( now - last_ts < 86400 )) && return 0
```
`last_ts` comes from `cat "$last_check_file"`. If the file contains non-numeric data, the arithmetic expression will error. The `set -e` would catch this, but it could produce a confusing error message.

---

## Dead Code

No dead code found. All defined functions are reachable from the main dispatch block (lines 2921-3084). No significant commented-out blocks.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0     |
| HIGH     | 0     |
| MEDIUM   | 7     |
| LOW      | 9     |

**Most actionable:** The race condition in parallel team creation (MEDIUM, line 2069) and the incomplete sed escape (MEDIUM, line 2443) are the only findings that could cause actual bugs in production. The race is triggered during `launch_session_dynamic` when `INITIAL_TEAMS > 1` and `INITIAL_WORKTREE_TEAMS > 0`. The sed escape only matters if paths contain backslashes.

The codebase is well-structured, consistently styled, and avoids all bash 3.2 compatibility pitfalls. No critical or high-severity issues found.
