# Shell Scripts Audit Report

Auditor: Worker 1 (R&D Audit Team)
Date: 2026-03-23
Scope: All files in `shell/` directory

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2     |
| HIGH     | 8     |
| MEDIUM   | 16    |
| LOW      | 12    |

---

## CRITICAL

### [CRITICAL] file:doey.sh line:2329 — Unquoted variable expansion in IFS-split can glob-expand

```bash
IFS=','; set -- $_ts_worker_panes; IFS="$_old_ifs"
```

`$_ts_worker_panes` is unquoted. If a pane value ever contains glob characters (`*`, `?`, `[`), the shell will expand them against the filesystem. Should be `set -- ${_ts_worker_panes}` (intentionally unquoted for splitting) but the variable should be validated to contain only digits and commas before this point, or use a safer splitting approach.

### [CRITICAL] file:doey.sh line:488 — `kill -- -"$pane_pid"` sends SIGTERM to process group, may kill unrelated processes

In `_kill_doey_session`, `kill -- -"$pane_pid"` sends a signal to the entire process group led by `$pane_pid`. If the shell's PID happens to be PID 1 of a process group that includes other processes (e.g., in containers or certain tmux configurations), this could kill unrelated processes. The same pattern appears at lines 2719 and 2729.

---

## HIGH

### [HIGH] file:doey.sh line:206 — `_worktree_safe_remove` short-circuit logic bug

```bash
[ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ] && return 0
```

Due to operator precedence, this evaluates as `( -z || ! -d ) && return`. If `worktree_dir` is non-empty but the directory does not exist, it returns 0 (success) silently. However, if `worktree_dir` is empty, the `[ ! -d "" ]` test is never reached due to short-circuit, so the `return 0` depends on `&&` binding. This works correctly by accident but is fragile and non-obvious. Should use explicit grouping: `{ [ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ]; } && return 0`.

### [HIGH] file:doey.sh line:1354 — Trap overrides itself, earlier trap from caller lost

```bash
trap 'jobs -p | xargs kill 2>/dev/null; git worktree prune 2>/dev/null' EXIT INT TERM
```

Then at line 1375:
```bash
trap - EXIT INT TERM
```

This clears the trap entirely. If any background jobs from `_brief_team` (line 1346) are still running when the trap is cleared, they become orphaned. The `sleep 15` background job at line 1349 will almost certainly still be alive.

### [HIGH] file:doey.sh line:1081 — `PROJECT_DIR` set as global in `doey_purge`, leaks into other functions

```bash
PROJECT_DIR="$dir"
```

This sets a global variable that is later referenced in `_purge_audit_context` (line 899). However, `PROJECT_DIR` could also be set by `safe_source_session_env` in other code paths, leading to conflicts if functions are called in unexpected order.

### [HIGH] file:doey.sh line:2437 — Incomplete sed metacharacter escaping

```bash
_escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
```

The character class `[&/\]` does not escape newlines or the sed delimiter in all edge cases. If `value` contains a newline, the sed replacement will fail. Also, backslash escaping within the character class is itself fragile across sed implementations.

### [HIGH] file:doey.sh line:2740-2741 — Incorrect compound test with `||` and `&&`

```bash
[ "$_pane_idx" = "0" ] || [ "$_pane_idx" = "1" ] && continue
```

This reads as `( idx=0 ) || ( ( idx=1 ) && continue )`, meaning it only skips pane index 1, not pane index 0. To skip both 0 and 1, should be:
```bash
{ [ "$_pane_idx" = "0" ] || [ "$_pane_idx" = "1" ]; } && continue
```

### [HIGH] file:doey.sh line:899 — `PROJECT_DIR` used in `_purge_audit_context` but only set in `doey_purge`

The function references `$PROJECT_DIR` for skill file paths but this variable is set as a side effect in the calling function `doey_purge`. If `_purge_audit_context` were ever called independently, `PROJECT_DIR` would be uninitialized or stale.

### [HIGH] file:info-panel.sh line:319 — `eval` with user-controlled data

```bash
eval "TITLE_R${_r}=\"\${TITLE_R${_r}}\${CHAR_R${_r}} \""
```

While `_r` is constrained to 0-5, `TITLE_R` and `CHAR_R` variables contain block-art characters that could theoretically contain shell metacharacters. The `eval` is safe in practice because the values are hardcoded in `get_block_char`, but this pattern is fragile.

### [HIGH] file:doey.sh line:2880 — `open` command precedence issue

```bash
[[ "$open" == true ]] && open "${project_dir}/index.html" 2>/dev/null || true
```

Due to `||` precedence, this evaluates as `( [[ open == true ]] && open ... ) || true`. The `|| true` means the entire expression always succeeds, which is fine, but if the intent is to only suppress errors from the `open` command, it should be: `[[ "$open" == true ]] && { open "${project_dir}/index.html" 2>/dev/null || true; }`.

---

## MEDIUM

### [MEDIUM] file:doey.sh line:307 — `printf -v` for dynamic variable names

```bash
printf -v "WDG_SLOT_${_wd_i}" '%s' "$_pane"
```

`printf -v` with dynamic variable names is supported in bash 3.2 but is less common. This is fine for compatibility but should be documented as an intentional pattern. Used extensively throughout.

### [MEDIUM] file:doey.sh line:92 — Unquoted variables in printf format string

```bash
printf "${indent}${DIM}Doey hooks + skills installed${RESET}\n"
```

Variables used directly in `printf` format strings throughout the file (lines 92, 368, 402, 518, 761, etc.). If any of these variables contained `%` characters, they would be interpreted as format specifiers. Should use `printf '%b' "..."` or `printf '%s' "..."`. This pattern is pervasive (50+ occurrences).

### [MEDIUM] file:doey.sh line:564 — Nested function `_menu_select` defined inside `show_menu`

```bash
_menu_select() {
```

While bash supports nested function definitions, the function `_menu_select` is actually defined in the global scope (bash does not have true lexical scoping for functions). This could be confusing and the function pollutes the global namespace.

### [MEDIUM] file:doey.sh line:1241 — `cd "$dir"` changes working directory permanently

In `_launch_session_core`, `cd "$dir"` at line 1241 changes the script's working directory. This could affect subsequent operations if the function returns and the caller expects to be in the original directory.

### [MEDIUM] file:doey.sh line:1466-1474 — Branch deletion in pipeline may delete wrong branches

```bash
git for-each-ref --format='%(refname:short)' 'refs/heads/doey/team-*' | while read -r b; do
    ...
    git branch -D "$b" 2>/dev/null || true
done
```

The `while` loop runs in a subshell due to the pipe, so any variables set inside are lost. More importantly, the comment says "only delete if the branch name could belong to this project" but there is no actual project-specific filtering -- `_project_name` is computed but never used in the condition.

### [MEDIUM] file:doey.sh line:1616 — `sed -i ''` is macOS-only

```bash
sed -i '' 's/^WATCHDOG_PANE=.*/WATCHDOG_PANE="0.2"/' "${runtime_dir}/session.env"
```

`sed -i ''` (with empty string) is macOS/BSD syntax. On GNU/Linux, `sed -i` requires no argument or `sed -i''` (no space). This appears at lines 1616, 1618, 2736. While the project targets macOS, the CLAUDE.md says "bash 3.2 compatible" which implies broader portability.

### [MEDIUM] file:doey.sh line:1944 — Arithmetic expression in `(( ))` without error handling

```bash
(( now - last_ts < 86400 )) && return 0
```

If `last_ts` contains non-numeric data (e.g., empty file or corrupted timestamp), this will error. Under `set -e`, this would cause the script to exit.

### [MEDIUM] file:doey.sh line:2356 — Missing quotes on `|| true`

```bash
[ -n "$pane_pid" ] && pkill -P "$pane_pid" 2>/dev/null || true
```

Due to precedence: `( -n && pkill ) || true`. If `pane_pid` is empty, the `|| true` runs. This works but is misleading -- it looks like `|| true` only applies to `pkill` but it actually applies to the entire chain.

### [MEDIUM] file:doey.sh line:1945 — `(( ))` returns exit code 1 when expression is 0, interacts with `set -e`

When `now - last_ts` equals exactly 86400, the `(( ))` expression evaluates to 0 (false), which under `set -e` could cause the script to exit since the line is not the last command in a conditional chain. The `&& return 0` saves it in most cases, but edge cases exist.

### [MEDIUM] file:info-panel.sh line:3 — Missing `set -e` (intentional but undocumented)

The script uses `set -uo pipefail` but explicitly omits `-e`. While the comment says the panel must not crash, the lack of `-e` means errors in critical setup code (lines 1-16) are silently ignored.

### [MEDIUM] file:info-panel.sh line:314 — `${TITLE_NAME:0:9}` substring syntax

```bash
TITLE_NAME="${TITLE_NAME:0:9}"
```

This `${var:offset:length}` syntax works in bash 3.2 but is worth noting as a potential portability concern if the script were ever run under a strict POSIX shell.

### [MEDIUM] file:doey.sh line:809 — Unquoted glob in `for f in $glob`

```bash
for f in $glob; do
```

In `_purge_collect_stale`, the `$glob` variable is intentionally unquoted to allow glob expansion, but if the glob pattern matches no files and `nullglob` is not set, the literal pattern string is iterated. The `[[ -f "$f" ]]` guard handles this, but it is inefficient.

### [MEDIUM] file:doey.sh line:1119 — Trap uses single-quoted path that may contain spaces

```bash
trap "rm -f '$list_file'" RETURN
```

If `mktemp` returns a path with spaces (unlikely with `/tmp/doey_purge_XXXXXX` but possible on some systems), the single quotes inside the double-quoted trap string would not protect the path correctly.

### [MEDIUM] file:tmux-statusbar.sh line:11 — `shopt -s nullglob` is bash-specific

While the shebang is `#!/usr/bin/env bash`, if this script were ever sourced from a non-bash shell, `shopt` would fail. Not a real risk given the shebang, but worth noting.

### [MEDIUM] file:doey.sh line:1826 — `_env_val` used for version file that may not have standard format

```bash
_doc_check ok "Version" "$(_env_val "$version_file" version) ($(_env_val "$version_file" date))"
```

If the version file format ever changes or has non-standard quoting, `_env_val` may return empty strings or partial data.

### [MEDIUM] file:context-audit.sh line:69 — Regex match with `=~` uses unquoted variable

```bash
[[ "$content" =~ $ALLOWLIST_RE ]]
```

While this is the correct way to use `=~` in bash (quoting the regex would make it a literal string match), the regex in `$ALLOWLIST_RE` contains `|` pipes that could interact with shell globbing if the variable were empty. The variable is always set, so this is safe in practice.

---

## LOW

### [LOW] file:doey.sh line:645 — `STEP_TOTAL=6` is hardcoded, overridden in multiple places

`STEP_TOTAL` is set to 6 at line 645, then overridden to 7 at line 1995 (in `launch_session_dynamic`), to 5/2 at lines 1112-1113 (in `doey_purge`). This global mutable state is fragile.

### [LOW] file:doey.sh line:159 — `sed` modifies file in place via temp file, no error check on sed

```bash
sed "s/name: ${base_name}/name: ${new_name}/" "$dst" > "${dst}.tmp"
```

If `$base_name` or `$new_name` contain sed metacharacters (`/`, `&`, `\`), the sed command will fail or produce incorrect output.

### [LOW] file:doey.sh line:1534 — `git pull` without `--rebase` may create merge commits

```bash
git -C "$repo_dir" pull || printf "..."
```

In `update_system`, a bare `git pull` may create merge commits. Consider `git pull --ff-only` for a cleaner update path.

### [LOW] file:doey.sh line:2062 — Background subshell for `add_dynamic_team_window` may have race conditions

Multiple team windows are created in parallel via `( add_dynamic_team_window ... ) &`. These subshells all call `_register_team_window` which uses `_set_session_env` with a mkdir-based lock. The lock is reasonable but could deadlock if a subshell crashes while holding the lock (the lock directory would remain). The 20-retry timeout at line 2429 mitigates this but is a potential issue.

### [LOW] file:doey.sh line:2826 — `${test_id: -8}` negative offset syntax

```bash
local last8="${test_id: -8}"
```

The space before `-8` is required to distinguish from `${var:-default}`. This works in bash 3.2 but is a subtle syntax trap.

### [LOW] file:doey.sh line:108 — `project_name_from_dir` uses `tr` ranges that depend on locale

```bash
echo "$raw" | tr '[:upper:] .' '[:lower:]--' | sed ...
```

The `tr` command maps uppercase to lowercase and spaces/dots to hyphens. The POSIX character classes `[:upper:]` and `[:lower:]` are locale-dependent. Under non-C/POSIX locales, this could produce unexpected results.

### [LOW] file:doey.sh line:437 — ANSI escape codes in `read -rp` prompt

```bash
read -rp "  Stop ${BOLD}${running_sessions[0]}${RESET}? (y/N) " confirm
```

The `$BOLD` and `$RESET` variables contain raw escape codes. In `read -rp`, bash does not interpret `\033` sequences -- they are printed literally by some terminals. This may display garbage characters. Should wrap in `$'\033[1m'` or use `printf` for the prompt.

### [LOW] file:pane-border-status.sh line:43 — Unicode emoji in script output

```bash
echo "${TITLE} 🔒"
```

The lock emoji may not render correctly in all terminal emulators or tmux configurations.

### [LOW] file:info-panel.sh line:358-363 — `eval` used for variable indirection

```bash
eval "_tw=\$TEAM_WIN_${_ti}"
```

Multiple `eval` statements are used for variable indirection. While safe here (the index `_ti` is controlled), `printf -v` and `${!var}` indirect expansion would be cleaner alternatives.

### [LOW] file:doey.sh line:87 — `local` declaration inside for loop

```bash
local name
name="$(basename "$d")"
```

Inside the `for d in ...` loop in `install_doey_hooks`, `local` is used. While `local` works anywhere inside a function in bash, it is a no-op if the same variable was already declared `local` in the same scope. Not a bug but slightly unusual.

### [LOW] file:doey.sh line:1913 — `grep -c '.'` counts non-empty lines, not projects

```bash
project_count="$(grep -c '.' "$PROJECTS_FILE" 2>/dev/null || echo 0)"
```

This counts all non-empty lines, including any that might be malformed. Using `grep -c '^[^:]*:'` would be more precise.

### [LOW] file:doey.sh — Multiple functions defined but only used in specific code paths

Functions like `launch_session_headless` (line 1968), `add_team_window` (line 2616), `list_team_windows` (line 2773) are defined at the top level but only called from specific CLI subcommands. This is standard practice for a CLI script but means all functions are parsed on every invocation even when not needed.

---

## Bash 3.2 Compatibility

No violations of the prohibited constructs were found:
- No `declare -A` (associative arrays)
- No `declare -n` (namerefs)
- No `declare -l` or `declare -u`
- No `printf '%(%s)T'` (time format)
- No `mapfile` or `readarray`
- No `|&` (pipe stderr)
- No `&>>` (append both)
- No `coproc`
- BASH_REMATCH is used only via `[[ =~ ]]` without capture groups (allowed)

The scripts correctly use `printf -v` for dynamic variable assignment and `for (( ))` loops, both of which are supported in bash 3.2.

---

## Dead Code / Unused Functions

None identified. All defined functions appear to be reachable from the main dispatch at the bottom of `doey.sh`, or from the other shell scripts.

---

## Files Audited

| File | Lines | Findings |
|------|-------|----------|
| `shell/doey.sh` | 3082 | 30 |
| `shell/info-panel.sh` | 399 | 5 |
| `shell/pane-border-status.sh` | 46 | 1 |
| `shell/tmux-statusbar.sh` | 30 | 1 |
| `shell/context-audit.sh` | 110 | 1 |
