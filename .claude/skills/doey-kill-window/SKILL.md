---
name: doey-kill-window
description: Kill a team window — stop processes, remove tmux window, clean runtime files.
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Windows: !`tmux list-windows -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{window_index} #{window_name}' 2>/dev/null|| true`

### 1. Validate
bash: RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); _sv() { grep "^$1=" "${RD}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }; SESSION_NAME=$(_sv SESSION_NAME); PROJECT_DIR=$(_sv PROJECT_DIR); TARGET_WIN="${1:-${DOEY_WINDOW_INDEX:-0}}"; [ "$TARGET_WIN" = "0" ] && { echo "ERROR: Cannot kill window 0. Use /doey-kill-session."; exit 1; }; tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' | grep -qx "$TARGET_WIN" || { echo "ERROR: Not found"; exit 1; }

### 2. Kill processes (SIGTERM → SIGKILL)
bash: KILLED=0; for pp in $(tmux list-panes -t "${SESSION_NAME}:${TARGET_WIN}" -F '#{pane_pid}' 2>/dev/null); do C=$(pgrep -P "$pp" 2>/dev/null); [ -n "$C" ] && kill "$C" 2>/dev/null && KILLED=$((KILLED + 1)); done; sleep 3; for pp in $(tmux list-panes -t "${SESSION_NAME}:${TARGET_WIN}" -F '#{pane_pid}' 2>/dev/null); do C=$(pgrep -P "$pp" 2>/dev/null); [ -n "$C" ] && kill -9 "$C" 2>/dev/null; done; sleep 1

### 3. Optional worktree teardown (only if window opted into `/doey-worktree`)
bash: _ev() { grep "^${1}=" "${RD}/team_${TARGET_WIN}.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }; _wd=$(_ev WORKTREE_DIR); _wb=$(_ev WORKTREE_BRANCH); if [ -n "$_wd" ] && [ -d "$_wd" ]; then [ -n "$(git -C "$_wd" status --porcelain 2>/dev/null)" ] && git -C "$_wd" add -A 2>/dev/null && git -C "$_wd" commit -m "doey: auto-save before teardown" 2>/dev/null; [ -n "$_wb" ] && { _a=$(git -C "$PROJECT_DIR" rev-list --count "HEAD..${_wb}" 2>/dev/null || echo 0); [ "$_a" -gt 0 ] 2>/dev/null && echo "Branch $_wb has $_a commit(s). Merge: git merge $_wb"; }; git -C "$PROJECT_DIR" worktree remove "$_wd" --force 2>/dev/null; git -C "$PROJECT_DIR" worktree prune 2>/dev/null; fi

### 4. Kill window + clean runtime
bash: tmux kill-window -t "${SESSION_NAME}:${TARGET_WIN}"; rm -f "${RD}/team_${TARGET_WIN}.env"; SS=$(echo "$SESSION_NAME" | tr ':.-' '_'); for p in "${RD}/status/${SS}_${TARGET_WIN}_"* "${RD}/results/pane_${TARGET_WIN}_"*.json "${RD}/status/crash_pane_${TARGET_WIN}_"*; do for f in $p; do [ -f "$f" ] && rm -f "$f"; done; done

### 5. Update TEAM_WINDOWS
bash: CUR=$(grep '^TEAM_WINDOWS=' "${RD}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"'); NW=$(echo "$CUR" | tr ',' '\n' | grep -v "^${TARGET_WIN}$" | tr '\n' ',' | sed 's/,$//'); TMPENV=$(mktemp "${RD}/session.env.tmp_XXXXXX"); sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NW}/" "${RD}/session.env" > "$TMPENV"; mv "$TMPENV" "${RD}/session.env"

Never kill window 0. Kill processes before window.
