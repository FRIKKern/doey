---
name: doey-kill-window
description: Kill a team window — stop processes, remove tmux window, clean runtime files.
---

## Usage
`/doey-kill-window [window_index]` — kill specific or current team window

## Context

Session config:
!`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Current windows:
!`tmux list-windows -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{window_index} #{window_name}' 2>/dev/null|| true`

Team environments:
!`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done || true`

## Prompt

## Step 1: Validate target window
bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); _sv() { grep "^$1=" "${RUNTIME_DIR}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }; SESSION_NAME=$(_sv SESSION_NAME); PROJECT_DIR=$(_sv PROJECT_DIR); WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"; TARGET_WIN="${1:-$WINDOW_INDEX}"; [ "$TARGET_WIN" = "0" ] && echo "ERROR: Cannot kill window 0 (Dashboard). Use /doey-kill-session." && exit 1; tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' | grep -qx "$TARGET_WIN" || { echo "ERROR: Window ${TARGET_WIN} not found"; exit 1; }; echo "Target: window ${TARGET_WIN}"
Expected: "Target: window N" printed with the window index

**If this fails with "ERROR: Cannot kill window 0":** Window 0 is the Dashboard. Use `/doey-kill-session` to kill the entire session instead.
**If this fails with "ERROR: Window N not found":** The window does not exist. Run `tmux list-windows` to see available windows.

## Step 2: Kill all processes (SIGTERM then SIGKILL)
bash: KILLED=0; for pane_pid in $(tmux list-panes -t "${SESSION_NAME}:${TARGET_WIN}" -F '#{pane_pid}' 2>/dev/null); do CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null); [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null && KILLED=$((KILLED + 1)); done; echo "Sent SIGTERM to ${KILLED} processes"; sleep 3; for pane_pid in $(tmux list-panes -t "${SESSION_NAME}:${TARGET_WIN}" -F '#{pane_pid}' 2>/dev/null); do CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null); [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null; done; sleep 1
Expected: "Sent SIGTERM to N processes" — all child processes terminated

**If this fails with "no such process":** Process already exited — safe to continue.

## Step 3: Worktree cleanup (before deleting team env)
bash: env_val() { grep "^${1}=" "${RUNTIME_DIR}/team_${TARGET_WIN}.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }; _wt_dir=$(env_val WORKTREE_DIR); _wt_branch=$(env_val WORKTREE_BRANCH); if [ -n "$_wt_dir" ] && [ -d "$_wt_dir" ]; then echo "Worktree detected: $_wt_dir (branch: $_wt_branch)"; if [ -n "$(git -C "$_wt_dir" status --porcelain 2>/dev/null)" ]; then git -C "$_wt_dir" add -A 2>/dev/null || true; git -C "$_wt_dir" commit -m "doey: auto-save before teardown $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true; echo "  Auto-saved to branch: $_wt_branch"; fi; if [ -n "$_wt_branch" ]; then _ahead=$(git -C "$PROJECT_DIR" rev-list --count "HEAD..${_wt_branch}" 2>/dev/null || echo "0"); [ "$_ahead" -gt 0 ] 2>/dev/null && echo "  Branch $_wt_branch has $_ahead commit(s). Merge with: git merge $_wt_branch"; fi; git -C "$PROJECT_DIR" worktree remove "$_wt_dir" --force 2>/dev/null || true; git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true; echo "  Worktree removed."; fi
Expected: If worktree exists — auto-save, removal, and prune. If no worktree — no output (skip).

**If this fails with "fatal: not a git repository":** The worktree directory is corrupt. Remove it manually with `rm -rf` and run `git worktree prune`.

## Step 4: Kill tmux window and clean runtime files
bash: tmux kill-window -t "${SESSION_NAME}:${TARGET_WIN}"; echo "Window ${TARGET_WIN} killed"; rm -f "${RUNTIME_DIR}/team_${TARGET_WIN}.env"; SESSION_SAFE=$(echo "$SESSION_NAME" | tr ':.' '_'); for pattern in "${RUNTIME_DIR}/status/${SESSION_SAFE}_${TARGET_WIN}_"* "${RUNTIME_DIR}/results/pane_${TARGET_WIN}_"*.json "${RUNTIME_DIR}/status/completion_pane_${TARGET_WIN}_"* "${RUNTIME_DIR}/status/crash_pane_${TARGET_WIN}_"*; do for f in $pattern; do [ -f "$f" ] && rm -f "$f"; done; done; rm -f "${RUNTIME_DIR}/status/watchdog_pane_states_W${TARGET_WIN}.json"; rm -f "${RUNTIME_DIR}/status/watchdog_W${TARGET_WIN}.heartbeat"
Expected: "Window N killed" — tmux window gone, all status/result/team env files removed

**If this fails with "can't find window":** Window was already killed in a prior step — safe to continue with file cleanup.

## Step 5: Update TEAM_WINDOWS in session.env
bash: CURRENT_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"'); NEW_WINDOWS=$(echo "$CURRENT_WINDOWS" | tr ',' '\n' | grep -v "^${TARGET_WIN}$" | tr '\n' ',' | sed 's/,$//'); TMPENV=$(mktemp "${RUNTIME_DIR}/session.env.tmp_XXXXXX"); sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NEW_WINDOWS}/" "${RUNTIME_DIR}/session.env" > "$TMPENV"; mv "$TMPENV" "${RUNTIME_DIR}/session.env"; echo "Runtime files cleaned"
Expected: "Runtime files cleaned" — session.env updated with window removed from TEAM_WINDOWS

**If this fails with "No such file or directory":** session.env is missing — the session may already be dead.

## Step 6: Report
Output: `Window ${TARGET_WIN} killed. Processes: ${KILLED}. TEAM_WINDOWS: ${NEW_WINDOWS}`

## Gotchas
- Do NOT kill window 0 — that is the Dashboard. Use `/doey-kill-session` instead.
- Do NOT kill the tmux window before killing processes — this creates orphan processes.
- Do NOT use `source` on runtime env files — `/tmp` is world-writable; use safe reads only.
- Do NOT skip worktree cleanup — uncommitted changes will be lost.

Total: 5 commands, 0 errors expected.

### Rules
- Never kill window 0 — use `/doey-kill-session`
- Kill processes before window (prevents orphans), by PID only
- Clean runtime files + update TEAM_WINDOWS (atomic write)
- Bash 3.2 compatible
