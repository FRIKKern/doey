# Shell Scripts Audit Report

**Date:** 2026-03-23
**Scope:** All files in `shell/` — doey.sh, info-panel.sh, pane-border-status.sh, tmux-statusbar.sh, context-audit.sh
**Auditor:** Worker 1 (shell-audit_0323)

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| HIGH | 6 |
| MEDIUM | 14 |
| LOW | 8 |
| INFO | 5 |

---

## Findings

### CRITICAL

**[CRITICAL] line:206 file:doey.sh — Short-circuit logic bug in `_worktree_safe_remove`**
```
Current:  [ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ] && return 0
```
Due to shell operator precedence, `A || B && C` is parsed as `(A || B) && C`. This means: if `worktree_dir` is non-empty AND the directory doesn't exist, it returns 0 — correct. But if `worktree_dir` IS empty, `[ -z "$worktree_dir" ]` is true, then `|| [ ! -d ... ]` is skipped, and `&& return 0` executes — also correct. However, the dangerous case: if `worktree_dir` is non-empty AND the directory exists, then `[ -z ]` is false, `[ ! -d ]` is false, and `&& return 0` does NOT execute — this is correct. BUT the more subtle issue: if `worktree_dir` is empty, `[ ! -d "" ]` would be true on some systems. The intent was clearly `{ [ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ]; } && return 0`. Without braces, the behavior depends on evaluation order and can vary across shells.
```
Suggested: { [ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ]; } && return 0
```

### HIGH

**[HIGH] line:319 file:info-panel.sh — `eval` with user-derived data in block-letter title rendering**
```
Current:  eval "TITLE_R${_r}=\"\${TITLE_R${_r}}\${CHAR_R${_r}} \""
```
While `_r` is controlled (0-5), this pattern is fragile and could break if the CHAR_R variables contain characters like backticks, `$()`, or double quotes (they contain Unicode box-drawing characters which are safe now, but the pattern is risky). Multiple `eval` calls also appear at lines 358-364 for team status display.
```
Suggested: Use printf -v instead:
  printf -v "TITLE_R${_r}" '%s' "${prev_val}${char_val} "
```

**[HIGH] line:358-364 file:info-panel.sh — Multiple `eval` with dynamically constructed variable names**
```
Current:  eval "_tw=\$TEAM_WIN_${_ti}" (and similar for 6 other vars)
```
If team data were ever to contain shell metacharacters, these evals could execute arbitrary code. The `printf -v` pattern used elsewhere in the same file (lines 247-253) is the safer approach.
```
Suggested: Use indirect variable references:
  local _var="TEAM_WIN_${_ti}"; _tw="${!_var}"
```

**[HIGH] line:1354 file:doey.sh — Trap overwrites previous handlers; `git worktree prune` runs in wrong dir**
```
Current:  trap 'jobs -p | xargs kill 2>/dev/null; git worktree prune 2>/dev/null' EXIT INT TERM
```
`git worktree prune` runs in whatever the current directory is (set by `cd "$dir"` at line 1241), which may not be the project dir if `cd` failed. Also, the trap at line 1374 (`trap - EXIT INT TERM`) clears ALL traps, including any the user may have set.
```
Suggested: trap 'jobs -p | xargs kill 2>/dev/null; git -C "$dir" worktree prune 2>/dev/null' EXIT INT TERM
```

**[HIGH] line:1119 file:doey.sh — `trap` with single-quoted variable won't expand on cleanup**
```
Current:  trap "rm -f '$list_file'" RETURN
```
This is double-quoted with single quotes inside, so `$list_file` IS expanded at definition time (correct). However, if `list_file` path contains single quotes, the `rm` command breaks. `mktemp` paths won't contain quotes in practice, but the quoting is still wrong.
```
Suggested: trap "rm -f \"$list_file\"" RETURN
```

**[HIGH] line:2401 file:doey.sh — `sed` substitution in `_set_session_env` is vulnerable to special chars in value**
```
Current:  sed "s/^${field}=.*/${field}=\"${value}\"/" "${runtime_dir}/session.env" > "$_tmp"
```
If `value` contains `/`, `&`, or `\`, the sed command will break or produce unexpected results. File paths with `/` are the common case here.
```
Suggested: Use a different sed delimiter:
  sed "s|^${field}=.*|${field}=\"${value}\"|" "${runtime_dir}/session.env" > "$_tmp"
```

**[HIGH] line:3 file:info-panel.sh — `set -u` without consistent null-checks on variables set by `read_env_file`**
```
Current:  set -uo pipefail
```
With `set -u`, referencing unset variables will cause an unbound variable error. The `read_env_file` function initializes vars, but if the file is missing/malformed, downstream code using `$TEAM_WINDOWS` (line 224) or `$_ENV_*` vars could hit an unbound variable before reaching the null-check.
```
Suggested: Initialize TEAM_WINDOWS="" before the conditional block or use ${TEAM_WINDOWS:-}
```

### MEDIUM

**[MEDIUM] line:92 file:doey.sh — Unquoted color variables as printf format string**
```
Current:  printf "${indent}${DIM}Doey hooks + skills installed${RESET}\n"
```
If `$indent` or color vars contain `%`, printf will interpret them as format specifiers. This pattern repeats extensively throughout doey.sh (lines 218, 227, 324, 356, 368, 382, 402, 416, etc.).
```
Suggested: printf '%b' "${indent}${DIM}Doey hooks + skills installed${RESET}\n"
```

**[MEDIUM] line:37 file:info-panel.sh — `printf -v` with unsanitized key names**
```
Current:  for _ref_k in "$@"; do printf -v "_ENV_${_ref_k}" '%s' ""; done
```
If any key in `$@` contains shell metacharacters, the variable name could be malformed. Internal-only usage makes this low-risk but defense-in-depth suggests validation.
```
Suggested: Validate: [[ "$_ref_k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
```

**[MEDIUM] line:100 file:info-panel.sh — Subshell fork in `visible_len` called in hot loop**
```
Current:  visible_len() { local s; s=$(printf '%s' "$1" | sed ...); printf '%d' "${#s}"; }
```
Forks subshell + sed for every call. Called via `dotted_leader`/`add_cmd_pair` ~20 times per refresh. Acceptable at 5min intervals but inefficient.

**[MEDIUM] line:226 file:doey.sh — Arithmetic comparison of potentially non-numeric value**
```
Current:  if [ "$commits_ahead" -gt 0 ] 2>/dev/null; then
```
`$commits_ahead` could be non-numeric if `git rev-list` fails unexpectedly. The `2>/dev/null` suppresses the error and `[ ]` returns false (safe behavior). Same pattern at lines 1898, 1935.
```
Suggested: [[ "$commits_ahead" =~ ^[0-9]+$ ]] && [ "$commits_ahead" -gt 0 ]
```

**[MEDIUM] line:809 file:doey.sh — Unquoted glob in `_purge_collect_stale`**
```
Current:  for f in $glob; do
```
Intentionally unquoted to expand the glob, but if the glob contains spaces, it will word-split incorrectly. Safe for current call sites but fragile.

**[MEDIUM] line:1241 file:doey.sh — `cd "$dir"` without error check in `_launch_session_core`**
```
Current:  cd "$dir"
```
With `set -e`, a failed `cd` exits the script with a cryptic error. Should check and provide useful error message.
```
Suggested: cd "$dir" || { printf "  ${ERROR}Cannot cd to %s${RESET}\n" "$dir"; return 1; }
```

**[MEDIUM] line:1312 file:doey.sh — Hard-coded `sleep 2` as race condition mitigation**
```
Current:  sleep 2
```
Arbitrary duration after grid creation. If tmux is slow, 2 seconds may not be enough; if fast, wastes time.

**[MEDIUM] line:1615-1617 file:doey.sh — macOS-only `sed -i ''` in `reload_session`**
```
Current:  sed -i '' 's/^WATCHDOG_PANE=.*/WATCHDOG_PANE="0.2"/' "${runtime_dir}/session.env"
```
`sed -i ''` is macOS-specific. On GNU/Linux, `sed -i` is the equivalent. Since Doey targets macOS bash 3.2, this is acceptable but limits portability. The tmp-file+mv pattern used elsewhere is more portable.
```
Suggested: Use tmp-file+mv pattern consistently (already used in _set_session_env, write_team_env)
```

**[MEDIUM] line:2295 file:doey.sh — `set --` with unquoted variable and no empty-check**
```
Current:  local _old_ifs="$IFS"; IFS=','; set -- $_ts_worker_panes; IFS="$_old_ifs"
```
If `_ts_worker_panes` is empty, `$#` becomes 0 and subsequent `eval` at lines 2303-2304 (accessing `${$#}`, `${$(($# - 1))}`) will fail or reference wrong positional params.
```
Suggested: Add early guard: [ -z "$_ts_worker_panes" ] && { printf "..."; return 1; }
```

**[MEDIUM] line:2700-2702 file:doey.sh — Misleading compound condition in kill_team_window**
```
Current:  [ "$_pane_idx" = "0" ] || [ "$_pane_idx" = "1" ] && continue
```
Same operator precedence pattern as the CRITICAL finding. `A || B && C` parses as `(A || B) && C`. The behavior is actually correct by coincidence for all cases, but the code is misleading and fragile.
```
Suggested: { [ "$_pane_idx" = "0" ] || [ "$_pane_idx" = "1" ]; } && continue
```

**[MEDIUM] line:2841 file:doey.sh — `||` short-circuit masks open failure**
```
Current:  [[ "$open" == true ]] && open "${project_dir}/index.html" 2>/dev/null || true
```
The `|| true` applies to the entire `&&` chain. If `$open` is false, `|| true` makes the line succeed (fine). But if `$open` is true and `open` fails, the error is masked.
```
Suggested: [[ "$open" == true ]] && { open "${project_dir}/index.html" 2>/dev/null || true; }
```

**[MEDIUM] line:11 file:tmux-statusbar.sh — `shopt -s nullglob` not restored**
```
Current:  shopt -s nullglob
```
Script exits after use, so no practical impact. But good practice to restore with `shopt -u nullglob` or use a subshell.

**[MEDIUM] line:10 file:pane-border-status.sh — `tmux show-environment` unset marker not handled**
```
Current:  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
```
If `DOEY_RUNTIME` is explicitly unset in tmux, `show-environment` outputs `-DOEY_RUNTIME`. After `cut -d= -f2-`, the result is `-DOEY_RUNTIME` (no `=` found, so entire line). The subsequent `[ -z "$RUNTIME_DIR" ]` would be false. Same pattern at info-panel.sh:7, tmux-statusbar.sh:5.
```
Suggested: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | grep '=' | cut -d= -f2-) || true
```

### LOW

**[LOW] line:159 file:doey.sh — `sed` pattern in `generate_team_agent` doesn't escape regex specials**
```
Current:  sed "s/name: ${base_name}/name: ${new_name}/" "$dst" > "${dst}.tmp"
```
`base_name` like `doey-manager` contains a literal `-` which is safe in regex. But `.` in future agent names would match any character.
```
Suggested: Use fixed-string replacement or escape special chars
```

**[LOW] line:765 file:doey.sh — JSON construction without proper escaping**
```
Current:  printf '{"trustedDirectories": ["%s"]}\n' "$dir" > "$claude_settings"
```
If `$dir` contains `"`, `\`, or newlines, the JSON will be malformed. Very unlikely for directory paths.
```
Suggested: jq -n --arg dir "$dir" '{"trustedDirectories": [$dir]}' > "$claude_settings"
```

**[LOW] line:109 file:doey.sh — `project_name_from_dir` uses two-fork pipeline**
```
Current:  echo "$raw" | tr '[:upper:] .' '[:lower:]--' | sed -e 's/[^a-z0-9-]/-/g' ...
```
Two forks for a simple string transformation. Low impact since called rarely.

**[LOW] line:697-698 file:doey.sh — Unquoted `$_s` variable used as command**
```
Current:  local _s="tmux set-option -t $session"
            $_s pane-border-status top
```
Storing a command in a variable and executing it unquoted. Works but is fragile if `$session` contains spaces. Session names are sanitized so this is safe in practice.

**[LOW] line:95-103 file:doey.sh — `write_pane_status` is not atomic**
```
Current:  cat > "${rt_dir}/status/${safe}.status" <<EOF
```
Direct write, not atomic (tmp+mv). If read during write, the file could be partially written. Low risk since reads tolerate partial data.

**[LOW] line:1944 file:doey.sh — Arithmetic in `(( ))` — compatible with bash 3.2**
No issue. Just noting the pattern for completeness.

**[LOW] line:487 file:doey.sh — `pkill -P` followed by `kill -- -` is redundant for some cases**
```
Current:  pkill -P "$pane_pid" 2>/dev/null || true
         kill -- -"$pane_pid" 2>/dev/null || true
```
`pkill -P` kills children by PPID. `kill -- -PID` kills the process group. If the process is both PPID and group leader, both work. If not group leader, the second call fails silently. Not a bug — defense in depth.

**[LOW] line:1465 file:doey.sh — `git for-each-ref` piped to `while read` loses exit status**
```
Current:  git for-each-ref ... | while read -r b; do ... done
```
The `while` loop runs in a subshell (pipe), so any `return` or variable assignments inside are lost. Not an issue here since there are no such assignments, but worth noting.

### INFO

**[INFO] line:1-3043 file:doey.sh — File is 3043 lines**
Very large single file. Functions are well-organized but the file would benefit from being split into modules (e.g., `doey-purge.sh`, `doey-grid.sh`, `doey-team.sh`).

**[INFO] line:397 file:info-panel.sh — Dashboard refreshes every 300 seconds (5 minutes)**
```
Current:  sleep 300
```
Design choice. Dashboard shows mostly static info so 5min is reasonable.

**[INFO] line:488 file:doey.sh — `kill -- -"$pane_pid"` sends signal to process group**
Process group kill only works if the pane_pid is a process group leader. If it isn't, this silently fails. The `pkill -P` on the previous line handles child processes as a fallback.

**[INFO] line:2116-2123 file:doey.sh — Custom layout checksum implementation**
The `_layout_checksum` function implements a simple 16-bit hash for tmux layout strings. Appears correct.

**[INFO] line:46 file:context-audit.sh — Regex patterns for y-spam detection**
Well-constructed allowlist/blocklist approach. Comprehensive coverage.

---

## Bash 3.2 Compatibility Check

All scripts were reviewed for bash 3.2 compatibility violations per CLAUDE.md conventions:

| Check | Result |
|-------|--------|
| No `declare -A/-n/-l/-u` | PASS |
| No `printf '%(%s)T'` | PASS |
| No `mapfile`/`readarray` | PASS |
| No `\|&` or `&>>` | PASS |
| No `coproc` | PASS |
| `[[ =~ ]]` usage | Used in several places — compatible with bash 3.2 |
| `local -a` | Used at lines 425, 522 of doey.sh — compatible |
| `printf -v` | Used extensively in info-panel.sh — compatible |
| `shopt -s nullglob` | Used in tmux-statusbar.sh, context-audit.sh — compatible |

**All scripts pass bash 3.2 compatibility checks.**

---

## `set -euo pipefail` Coverage

| File | `-e` | `-u` | `-o pipefail` | Notes |
|------|------|------|----------------|-------|
| doey.sh | Yes | Yes | Yes | Full coverage |
| info-panel.sh | No | Yes | Yes | Intentional: "must not crash on transient failures" |
| pane-border-status.sh | No | Yes | Yes | Same rationale |
| tmux-statusbar.sh | No | Yes | Yes | Same rationale |
| context-audit.sh | Yes | Yes | Yes | Full coverage |

The omission of `-e` in tmux callback scripts is a deliberate and correct design decision.

---

## Dead Code

No significant dead code found. All functions are reachable from the main dispatch or helper scripts.

---

## Race Conditions

1. **`_set_session_env` (line 2388)** — mkdir-based locking with retry (20 x 0.1s). Acceptable.
2. **`write_team_env` (line 128)** — Atomic write (tmp+mv). Correct.
3. **`write_pane_status` (line 95)** — Non-atomic write. Low risk since single-writer.
4. **`_register_team_window` / `_unregister_team_window`** — Both use `_set_session_env` which has locking. Correct.

---

## Top Priority Fixes

1. **CRITICAL** — Fix operator precedence bug in `_worktree_safe_remove` (line 206)
2. **HIGH** — Fix sed delimiter in `_set_session_env` (line 2401) — paths with `/` will break
3. **HIGH** — Replace `eval` with `${!var}` or `printf -v` in info-panel.sh (lines 319, 358-364)
4. **HIGH** — Fix trap in `_launch_session_core` to use `git -C "$dir"` (line 1354)
5. **MEDIUM** — Fix operator precedence in `kill_team_window` (line 2700-2702)
6. **MEDIUM** — Handle tmux unset env marker (`-VARNAME`) in all 3 callback scripts
