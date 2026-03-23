# Shell Audit Report — doey.sh & supporting shell scripts

**Date:** 2026-03-23
**Auditor:** R&D Worker (shell-audit_0323)
**Scope:** shell/doey.sh, shell/info-panel.sh, shell/context-audit.sh, shell/pane-border-status.sh, shell/tmux-statusbar.sh
**Method:** Full read + static analysis. No fixes applied.

---

## shell/doey.sh

### HIGH

**[HIGH] line:2748 — Logic bug in `kill_team_window` pane re-enumeration**

```bash
[ "$_pane_idx" = "0" ] || [ "$_pane_idx" = "1" ] && continue
```

Shell operator precedence: `||` binds tighter than `&&`, so this parses as:
```
[ pane = "0" ] || ([ pane = "1" ] && continue)
```
When `_pane_idx = "0"`: the `||` short-circuits to true, `continue` is **never reached** — pane 0 is processed when it should be skipped. Only pane "1" reliably triggers `continue`. This means pane 0 (Info Panel) gets a `WDG_SLOT_N` entry written for it after a `kill-team` operation, corrupting session.env.

Suggested fix: `if [ "$_pane_idx" = "0" ] || [ "$_pane_idx" = "1" ]; then continue; fi`

---

**[HIGH] line:1623, line:1626 — `sed -i ''` is macOS-only (portability)**

```bash
sed -i '' 's/^WATCHDOG_PANE=.*/WATCHDOG_PANE="0.2"/' "${runtime_dir}/session.env"
sed -i '' '/^MGR_SLOT_/d' "${runtime_dir}/session.env"
```

BSD `sed` (macOS) requires the empty string backup suffix: `sed -i ''`. GNU `sed` (Linux) does not accept the empty string — it interprets it as the next argument. Both usages appear in `reload_session`. All other in-place edits in doey.sh correctly use a temp file + `mv` pattern. These two are the only occurrences of `sed -i ''`.

---

**[HIGH] line:495-496, line:2726, line:2736 — `kill -- -"$pane_pid"` without PID safety check**

```bash
kill -- -"$pane_pid" 2>/dev/null || true
```

`kill -- -N` sends SIGKILL to process group N. If `pane_pid` is `0` or `1`, this would kill all processes in the session's process group (0) or attempt to signal PID 1 (launchd/init). Only an empty-string guard exists (`[ -n "$pane_pid" ]`); there is no check that `pane_pid` is a safe numeric value > 1. tmux can return unexpected pane_pid values on detached sessions.

---

### MEDIUM

**[MEDIUM] line:349-353 — `safe_source_session_env` executes arbitrary code from /tmp/**

```bash
safe_source_session_env() {
  validate_session_env "$1"
  source "$1"
}
```

`/tmp/doey/<project>/session.env` is sourced (code execution). On shared systems, `/tmp` is often world-writable. A malicious actor could write a crafted `session.env` containing arbitrary shell code. `validate_session_env` only checks whether the file parses without error in a subshell — it does not sanitize content. This is a code-injection vector.

---

**[MEDIUM] line:1125-1126 — `mktemp` temp file from `trap RETURN` with single-quoted path**

```bash
list_file="$(mktemp /tmp/doey_purge_XXXXXX)"
trap "rm -f '$list_file'" RETURN
```

The `RETURN` pseudo-signal is not portable to bash 3.2 — it exists in bash 3.x but only fires when set inside a function. This is used inside `doey_purge()` and works correctly in practice. However if `list_file` path contains a single quote, the `trap "rm -f '...'"` string would be malformed. `mktemp` output won't contain quotes, so actual risk is low, but pattern is fragile.

---

**[MEDIUM] line:996 — `_purge_execute` IFS=`:` split breaks on file paths containing colons**

```bash
while IFS=: read -r size path; do
```

The purge list is written as `"${size}:${file}"` (one colon). File paths containing `:` (valid on Unix/macOS) would cause `$path` to contain only the portion before the second `:`. The file would be silently skipped or a wrong path would be passed to `rm -f`. Low real-world probability but a correctness issue.

---

**[MEDIUM] line:816 — Unquoted glob in `_purge_collect_stale`**

```bash
for f in $glob; do
    [[ -f "$f" ]] || continue
```

`$glob` is unquoted. When the glob matches nothing and `nullglob` is not set, bash passes the literal pattern string to the loop body. The `[[ -f "$f" ]]` guard prevents incorrect processing, but any glob containing spaces in the pattern itself would split on IFS. The function is called with hardcoded patterns (no spaces), so current risk is low.

---

**[MEDIUM] line:2406 — `add_dashboard_watchdog_slot` derives new pane slot from slot count, not actual tmux indices**

```bash
local new_slot="0.$((new_slot_num + 1))"
```

This assumes pane indices in window 0 are contiguous from `0.2` upward. After panes are killed and re-split (e.g., after `kill-team`), tmux re-numbers panes sequentially, so this arithmetic may produce an index that doesn't match the actual newly created pane. The correct approach is to query tmux for the index of the new pane after `split-window`.

---

**[MEDIUM] line:159 — `generate_team_agent` sed substitution without escaping**

```bash
sed "s/name: ${base_name}/name: ${new_name}/" "$dst" > "${dst}.tmp"
```

If `base_name` or `new_name` contain sed metacharacters (`/`, `&`, `\`, `.`, `*`), the substitution would be malformed or silently wrong. Agent names come from `doey-manager` / `doey-watchdog` (safe), but this function does no input sanitization. If agent naming conventions change, this is a latent bug.

---

**[MEDIUM] line:1209-1217, line:1789-1794 — Fragile JSON parsing via grep/sed, duplicated**

```bash
if echo "$auth_json" | grep -q '"loggedIn": true'; then
  method=$(echo "$auth_json" | grep '"authMethod"' | sed 's/.*: *"//;s/".*//')
```

JSON field parsing with line-by-line grep+sed is fragile: breaks if the JSON is compacted onto one line, if key order changes, or if nested objects appear. Logic is also duplicated between `check_claude_auth` (line 1206) and `check_doctor` (line 1777). The project already requires `jq` for `ensure_project_trusted` — `jq` should be used here too, with a fallback for when it's absent.

---

**[MEDIUM] line:2433-2447 — `_set_session_env` lock race: forced removal could overlap live writers**

```bash
while ! mkdir "$_lock" 2>/dev/null; do
  _retries=$((_retries + 1))
  if [ "$_retries" -gt 20 ]; then
    rmdir "$_lock" 2>/dev/null
    break
  fi
  sleep 0.1
done
```

After 20 retries (~2 seconds), the lock is forcibly removed with `rmdir`. If the original lock holder is still actively writing (e.g., on a slow/busy system), this allows two processes to simultaneously write `session.env`, causing corruption. `mkdir`-based locks have no ownership tracking, so there is no way to distinguish a stale lock from a live one.

---

### LOW

**[LOW] line:1361 — Trap in `_launch_session_core` may kill brief-team background jobs on INT**

```bash
(
  sleep 15
  tmux send-keys -t "$session:${SM_PANE}" "Session online..." Enter
) &

trap 'jobs -p | xargs kill 2>/dev/null; git worktree prune 2>/dev/null' EXIT INT TERM
```

Background jobs started by `_brief_team` (sleeping 8-20 seconds before sending initial context to Manager/Watchdog) are in-flight when the INT trap is set. If the user hits Ctrl-C during worker booting, the trap kills these jobs, and the Manager/Watchdog never receive their startup briefings. Workers launch but have no orientation context. The trap is cleared at line 1382 before returning, so this window is narrow but non-zero.

---

**[LOW] line:1552 — Hardcoded GitHub URL in `update_system`**

```bash
git clone --depth 1 "https://github.com/FRIKKern/doey.git" "$install_dir"
```

URL is hardcoded. If the repo is renamed, moved, or mirrored, the fallback clone path silently breaks. Should be a configurable constant or read from `repo-path`.

---

**[LOW] line:1088, line:928 — `PROJECT_DIR` global set inside `doey_purge`, consumed by `_purge_audit_context`**

```bash
# In doey_purge:
PROJECT_DIR="$dir"
...
# In _purge_audit_context (called later):
for f in "$PROJECT_DIR"/.claude/skills/doey-*/SKILL.md; do
```

`_purge_audit_context` reads `$PROJECT_DIR` from the global environment set by `doey_purge`. If `_purge_audit_context` is ever called outside of `doey_purge`, `$PROJECT_DIR` could be stale or empty, causing the skill audit to scan the wrong location silently.

---

**[LOW] line:1473-1481 — `_cleanup_old_session` deletes all orphaned `doey/team-*` branches regardless of session**

```bash
git for-each-ref --format='%(refname:short)' 'refs/heads/doey/team-*' | while read -r b; do
  if git worktree list --porcelain 2>/dev/null | grep -q "branch refs/heads/${b}$"; then
    continue
  fi
  git branch -D "$b" 2>/dev/null || true
done
```

This deletes any `doey/team-*` branch that has no registered worktree, including branches from other concurrent Doey sessions on the same repo. Multiple parallel Doey sessions (e.g., testing in one window, development in another) could have their worktree branches deleted when one session restarts.

---

**[LOW] line:1014-1026 — `_purge_write_report` JSON generated by heredoc without escaping**

```bash
cat > "$rt/results/purge_report_$(date '+%Y%m%d_%H%M%S').json" << REPORT_EOF
{
  "project": "$project",
  ...
}
REPORT_EOF
```

`$project` (the project name) and `$scope` are embedded directly. If a project name contains `"` or `\`, the output is invalid JSON. Project names go through `project_name_from_dir` which strips to `[a-z0-9-]`, so `$project` is always safe. `$scope` is validated against a whitelist. Currently safe, but fragile by construction.

---

**[LOW] line:706-717 — `apply_doey_theme` builds `$_s` alias string, not array**

```bash
local _s="tmux set-option -t $session"
$_s pane-border-status top
```

`$_s` is a string containing `tmux set-option -t <session>`. If `$session` contains spaces, word splitting causes the tmux call to fail. Session names are derived from project names which are sanitized to `[a-z0-9-]`, so currently safe. The pattern itself (unquoted string-as-command) is a code smell that could fail for new callers.

---

**[LOW] line:2244 — `_boot_worker` and `_batch_boot_workers` both `sleep 0.3`/`sleep 3` unconditionally**

`_boot_worker` sleeps 0.3s per worker. `_batch_boot_workers` sleeps 3s flat after sending all commands. These are empirical delays with no verification that Claude has actually started. Combined with the `sleep 0.5` in `_launch_session_core` (line 1319), these hardcoded delays add up on slow systems and are insufficient on very slow systems.

---

**[LOW] line:2336 — `doey_remove_column` uses `eval` with positional parameters**

```bash
local _old_ifs="$IFS"; IFS=','; set -- $_ts_worker_panes; IFS="$_old_ifs"
...
eval "remove_top=\${$(( $# - 1 ))}"
eval "remove_bottom=\${$#}"
```

`eval` is used to access positional parameters by computed index. While `$#` and the arithmetic are internal integers and safe in practice, the `eval` pattern is fragile and unnecessary — a portable loop or `shift` approach would avoid it.

---

## shell/info-panel.sh

### MEDIUM

**[MEDIUM] line:37 — `printf -v` with user-controlled key names from session.env**

```bash
for _ref_k in "$@"; do printf -v "_ENV_${_ref_k}" '%s' ""; done
```

`printf -v` writes to a variable named `_ENV_<key>`. If `SESSION_ENV` is corrupted and contains a key like `PATH` or `IFS`, `printf -v "_ENV_PATH"` is safe (doesn't overwrite `PATH`). But `printf -v` with a key containing special characters (e.g., `[`, `]`) would cause a bash error. Low real-world risk given controlled keys.

---

### LOW

**[LOW] line:100 — `visible_len` forks a subshell + `sed` for every call**

```bash
visible_len() { local s; s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'); printf '%d' "${#s}"; }
```

Called multiple times per render cycle for each command in the help section. Each call forks a subshell and a `sed` process. On a 300-second refresh loop this is fine, but on terminals where pane-border-status.sh calls this indirectly, the forking overhead could be noticeable.

---

**[LOW] line:199-208 — Session name/project name cached from first render, never refreshed**

```bash
if [ -z "$_CACHED_SESSION_NAME" ]; then
  read_env_file "$SESSION_ENV" SESSION_NAME PROJECT_NAME PROJECT_DIR TEAM_WINDOWS
  _CACHED_SESSION_NAME="$_ENV_SESSION_NAME"
  ...
else
  read_env_file "$SESSION_ENV" TEAM_WINDOWS
fi
```

PROJECT_NAME, PROJECT_DIR, and SESSION_NAME are read only once (first render). If the project is renamed or session.env is regenerated, these fields never update. TEAM_WINDOWS is re-read correctly on every cycle.

---

**[LOW] line:326 — `$RANDOM` used for color cycling**

```bash
_color_idx=$((RANDOM % 6))
```

`$RANDOM` is a bash extension (not POSIX sh). Fine since this script is bash, but if it were ever sourced in a `#!/bin/sh` context, it would produce 0 every time. Not a current concern.

---

## shell/pane-border-status.sh

### LOW

**[LOW] line:39, line:45 — `echo "$TITLE"` may interpret escape sequences**

```bash
echo "$TITLE"; exit 0
```

`echo` behavior with escape sequences varies by platform and shell configuration (`xpg_echo`, `echo -e`, etc.). If `$TITLE` contains backslash sequences (e.g., `\n`, `\t`), some echo implementations expand them. `printf '%s\n' "$TITLE"` is the safe alternative.

---

**[LOW] line:31-37 — Watchdog pane lookup iterates all team_*.env files per border render**

```bash
for team_file in "${RUNTIME_DIR}"/team_*.env; do
  [ -f "$team_file" ] || continue
  WDG_PANE=$(env_val "$team_file" WATCHDOG_PANE)
  ...
done
```

`pane-border-status.sh` is invoked by tmux for **every pane border** on every redraw. With many teams and status files, this iterates all team_*.env files synchronously. On a session with 10 teams, this is 10 file reads per pane border per redraw cycle. Performance degrades with scale.

---

## shell/tmux-statusbar.sh

### LOW

**[LOW] line:14 — `awk` via array requires `shopt -s nullglob` to be set before**

```bash
shopt -s nullglob
status_files=("$RUNTIME_DIR/status/"*.status)
if [ ${#status_files[@]} -gt 0 ]; then
  read -r BUSY READY FINISHED RESERVED <<< "$(awk ... "${status_files[@]}")"
```

`nullglob` is correctly set before the glob. If `nullglob` were not set and no `.status` files existed, `status_files` would contain the literal pattern string, and `awk` would try to open a file named `"$RUNTIME_DIR/status/*.status"`, failing silently (the `|| true` in a different form here would save it, but the fallback `BUSY=0 READY=0 FINISHED=0 RESERVED=0` block handles it correctly). Current implementation is correct.

---

## shell/context-audit.sh

### LOW

**[LOW] line:19 — `[[ ]]` used for mode check (bash-specific)**

```bash
[[ -z "$MODE" ]] && { echo "Error: must specify --installed or --repo" >&2; exit 2; }
```

File has `#!/usr/bin/env bash` shebang. The `[[` usage is consistent throughout. However, the mix of POSIX `[ ]` and bash `[[ ]]` within the same file could confuse contributors. Not a bug.

---

**[LOW] line:101-106 — `IFS="$DELIM" read -r ... <<< "$issue"` depends on $'\x1f' not appearing in content**

```bash
IFS="$DELIM" read -r category file lnum pattern_desc risk_desc <<< "$issue"
```

`DELIM=$'\x1f'` (ASCII unit separator). If scanned file content contains the `\x1f` byte (unusual but valid in binary files or some encodings), `add_issue` would split incorrectly. Not a practical concern for Markdown files.

---

## Summary Table

| Severity | Count | Files |
|----------|-------|-------|
| HIGH     | 3     | doey.sh |
| MEDIUM   | 6     | doey.sh |
| LOW      | 12    | doey.sh, info-panel.sh, pane-border-status.sh, tmux-statusbar.sh, context-audit.sh |

### Priority Fix Order
1. `kill_team_window` logic bug (line 2748) — silent data corruption on kill-team
2. `sed -i ''` portability (lines 1623, 1626) — breaks on Linux
3. `kill -- -"$pane_pid"` without PID > 1 guard (lines 495, 2726, 2736)
4. `_purge_execute` colon-split on paths with colons (line 996)
5. `_set_session_env` lock forced removal race (line 2433)
