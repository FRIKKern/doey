# Shell Script Audit — 2026-03-23 (Full Re-audit)

**Scope:** `shell/doey.sh` (3081 lines), `shell/info-panel.sh` (398 lines), `shell/context-audit.sh` (109 lines), `shell/pane-border-status.sh` (45 lines), `shell/tmux-statusbar.sh` (29 lines)

**Baseline:** bash 3.2 on macOS. Forbidden: `declare -A/-n/-l/-u`, `printf '%(%s)T'`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `BASH_REMATCH` capture groups.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0     |
| HIGH     | 3     |
| MEDIUM   | 8     |
| LOW      | 9     |

**No bash 3.2 compatibility violations found.** The codebase is clean of all forbidden constructs.

---

## HIGH

### [HIGH] doey.sh:2880 — Operator precedence bug in `run_test`

```bash
[[ "$open" == true ]] && open "${project_dir}/index.html" 2>/dev/null || true
```

Due to left-to-right evaluation of `&&`/`||`, if `$open` is `true` but the `open` command fails, `|| true` silently swallows the error. More importantly, if `$open` is `false`, `|| true` still runs (making it look like something happened). Under `set -e`, the `|| true` prevents the script from exiting on `open` failure, which masks errors.

**Suggested:**
```bash
if [[ "$open" == true ]]; then
  open "${project_dir}/index.html" 2>/dev/null || true
fi
```

### [HIGH] doey.sh:2568-2571 — Race condition in `add_dynamic_team_window`

```bash
tmux new-window -t "$session" -c "$dir"
sleep 0.3
local window_index
window_index=$(tmux display-message -t "$session" -p '#{window_index}')
```

If two `add_dynamic_team_window` calls run concurrently (e.g., lines 2061-2063 launch them in parallel via `( ... ) &`), both could create windows simultaneously. The `tmux display-message -p '#{window_index}'` returns the *active* window index, not necessarily the one just created. Two parallel invocations could get the same index.

**Suggested:** Use `tmux new-window -P -F '#{window_index}'` to capture the created window index directly:
```bash
window_index=$(tmux new-window -t "$session" -c "$dir" -P -F '#{window_index}')
```

### [HIGH] doey.sh:2627-2630 — Same race condition in `add_team_window`

Same pattern as above — `tmux new-window` followed by `tmux display-message` to get the window index. Same fix applies.

---

## MEDIUM

### [MEDIUM] doey.sh:92,324,356,368,382-384,402,416-420,437,518,538,etc — printf format string injection

Dozens of `printf` calls use variables in the format string position:
```bash
printf "${indent}${DIM}Doey hooks + skills installed${RESET}\n"
printf "  ${WARN}Fixing malformed session.env (unquoted paths with spaces)${RESET}\n" >&2
```

While the injected variables are usually color codes or static strings, the pattern is fragile. If any variable contained `%s`, `%d`, or `%n`, it would be interpreted as a format specifier.

**Suggested:** Use `%b` for variables containing escape sequences:
```bash
printf '%b%bDoey hooks + skills installed%b\n' "$indent" "$DIM" "$RESET"
```

### [MEDIUM] doey.sh:1081 — Global variable `PROJECT_DIR` leaked from `doey_purge`

```bash
PROJECT_DIR="$dir"
```

This sets a global `PROJECT_DIR` that is later used in `_purge_audit_context` (line 899). If `doey_purge` is called before other functions that depend on `PROJECT_DIR`, the global state persists. The same pattern appears at line 1771 in `check_doctor`.

**Suggested:** Pass `PROJECT_DIR` as a parameter to `_purge_audit_context` and `_purge_audit_hooks` instead of relying on global state.

### [MEDIUM] doey.sh:2429 — Lock force-break in `_set_session_env` can corrupt data

```bash
while ! mkdir "$_lock" 2>/dev/null; do
    _retries=$((_retries + 1))
    if [ "$_retries" -gt 20 ]; then
      rmdir "$_lock" 2>/dev/null   # Force-break the lock
      break
    fi
    sleep 0.1
done
```

After 20 retries (2 seconds), the lock is force-removed. If the holding process is still writing `session.env`, a concurrent write could produce a corrupt file. Consider using a PID-based stale lock check instead of a fixed retry count.

### [MEDIUM] doey.sh:564 — Nested function `_menu_select` leaks to global scope

```bash
show_menu() {
  ...
  _menu_select() {
    ...
  }
```

Bash doesn't have lexical scoping for functions — `_menu_select` becomes globally defined after `show_menu` is first called. If another function later defines `_menu_select`, it could conflict.

**Suggested:** Move `_menu_select` to top level with a descriptive name like `_show_menu_select`, or inline it.

### [MEDIUM] doey.sh:1354 — Trap handler uses `xargs kill` without `-r`

```bash
trap 'jobs -p | xargs kill 2>/dev/null; git worktree prune 2>/dev/null' EXIT INT TERM
```

On macOS, `xargs` without `-r` will still run `kill` with no arguments if `jobs -p` produces empty output. The `kill` with no args just prints usage to stderr (harmless but noisy, though stderr is redirected). On GNU systems, `xargs` without `-r` behaves differently.

**Suggested:** `jobs -p | xargs -I{} kill {} 2>/dev/null`

### [MEDIUM] doey.sh:2438 — sed field name not escaped in `_set_session_env`

```bash
_escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
sed "s/^${field}=.*/${field}=\"${_escaped_value}\"/" "${runtime_dir}/session.env" > "$_tmp"
```

The `field` variable is interpolated directly into the sed regex without escaping. If `field` contained regex metacharacters like `.` or `*`, the match could be wrong. In practice, field names are hardcoded (e.g., `TEAM_WINDOWS`), so this is unlikely to cause issues.

### [MEDIUM] doey.sh:809 — Unquoted glob expansion in `_purge_collect_stale`

```bash
for f in $glob; do
```

The `$glob` variable is intentionally unquoted for glob expansion, but if file paths contain spaces, word splitting will break the loop. Files in `/tmp/doey/` are unlikely to have spaces, but it's worth noting.

### [MEDIUM] info-panel.sh:1 — Inconsistent shebang

```bash
#!/bin/bash
```

All other scripts use `#!/usr/bin/env bash`. This one hardcodes `/bin/bash`. On macOS this is fine (points to bash 3.2), but it's inconsistent with the rest of the codebase.

**Suggested:** Change to `#!/usr/bin/env bash` for consistency.

---

## LOW

### [LOW] doey.sh:40-41 — Unconditional `mkdir`/`touch` on every invocation

```bash
mkdir -p "$(dirname "$PROJECTS_FILE")"
touch "$PROJECTS_FILE"
```

These run even for `--help`, `version`, `doctor`, etc. Minor performance cost.

### [LOW] doey.sh:1616-1618 — macOS-specific `sed -i ''`

```bash
sed -i '' 's/^WATCHDOG_PANE=.*/WATCHDOG_PANE="0.2"/' "${runtime_dir}/session.env"
```

`sed -i ''` is macOS BSD sed syntax. On GNU/Linux, this would need `sed -i` without the empty string. Since the project targets macOS bash 3.2, this is fine but limits portability.

Also appears at lines 2736, 2749.

### [LOW] doey.sh:488 — Process group kill may affect unrelated processes

```bash
kill -- -"$pane_pid" 2>/dev/null || true
```

Sending SIGTERM to the process group (`-PID`) could theoretically kill unrelated processes if the PID has been reused. This is extremely unlikely in practice.

### [LOW] info-panel.sh:319,358-364 — `eval` for dynamic variable construction

```bash
eval "TITLE_R${_r}=\"\${TITLE_R${_r}}\${CHAR_R${_r}} \""
```

```bash
eval "_tw=\$TEAM_WIN_${_ti}"
eval "_twc=\$TEAM_WCNT_${_ti}"
```

Uses `eval` for building dynamic variable names. While variables are controlled loop counters, `eval` is inherently fragile and hard to reason about.

### [LOW] doey.sh:1354,2096 — Background subshells without cleanup

Background subshells are launched with `( ... ) &` for delayed `send-keys`. Line 1354 adds a trap to kill backgrounded jobs, but the trap is cleared at line 1375. Any jobs started after line 1375 (or in other functions) are orphaned.

### [LOW] doey.sh:1913 — `grep -c '.'` counts non-blank lines

```bash
project_count="$(grep -c '.' "$PROJECTS_FILE" 2>/dev/null || echo 0)"
```

`grep -c '.'` counts non-empty lines — this is correct behavior for counting projects, but could be clearer with `grep -c '[^[:space:]]'`.

### [LOW] doey.sh:2337,2346-2347 — `eval` for indirect positional parameter access

```bash
eval "remove_top=\${$(( $# - 1 ))}"
eval "remove_bottom=\${$#}"
```

Uses `eval` for accessing positional parameters by computed index. This is bash 3.2 compatible (can't use `${!n}` on positional params in 3.2), but the eval makes it harder to reason about.

### [LOW] doey.sh:1119 — Trap uses `RETURN` which may not fire on `exit`

```bash
trap "rm -f '$list_file'" RETURN
```

The `RETURN` trap fires when the function returns normally but NOT if the script exits via `exit` or receives a signal. If `doey_purge` fails mid-execution due to `set -e`, the temp file won't be cleaned up. Consider using `EXIT` instead, or both.

### [LOW] context-audit.sh:102 — IFS delimiter may not work with all field content

```bash
IFS="$DELIM" read -r category file lnum pattern_desc risk_desc <<< "$issue"
```

`DELIM=$'\x1f'` (Unit Separator). The `<<<` here-string adds a trailing newline. If any of the last fields contain embedded newlines, parsing could break. In practice the fields are sanitized to 80 chars, so this is fine.

---

## Dead Code / Unused

No significant dead code found. All functions are reachable from the main dispatch.

## Bash 3.2 Compatibility

**All clear.** No violations of the forbidden construct list found across any script:
- No `declare -A/-n/-l/-u`
- No `printf '%(%s)T'`
- No `mapfile`/`readarray`
- No `|&` or `&>>`
- No `coproc`
- `[[ =~ ]]` is used but without `BASH_REMATCH` capture groups

## Security Notes

- `--dangerously-skip-permissions` is used for all Claude instances (intentional for autonomous operation)
- `rm -rf` usage is limited to controlled paths under `/tmp/doey/`
- `eval` usage is limited to controlled variables (loop counters, known keys)
- No command injection vectors found — all user input goes through `project_name_from_dir` sanitization

---

*Audit performed on doey.sh commit ed1f877*
