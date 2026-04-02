---
name: doey-add-window
description: Add a new team window (Manager + Workers), optionally in a git worktree or as a reserved freelancer pool.
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Windows: !`tmux list-windows -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{window_index} #{window_name}' 2>/dev/null|| true`

`/doey-add-window [grid] [--worktree] [--freelancer]` (default 4x2). **No confirmation.**

### 1. Parse + validate
bash: RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && _sv() { grep "^$1=" "${RD}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; } && SESSION_NAME=$(_sv SESSION_NAME) && PROJECT_DIR=$(_sv PROJECT_DIR) && PROJECT_NAME=$(_sv PROJECT_NAME) && GRID="${USER_GRID:-4x2}" && COLS=$(echo "$GRID" | cut -dx -f1) && ROWS=$(echo "$GRID" | cut -dx -f2) && TOTAL=$((COLS * ROWS)) && WORKTREE_MODE="false" && FREELANCER_MODE="false" && for _a in "$@"; do [ "$_a" = "--worktree" ] && WORKTREE_MODE="true"; [ "$_a" = "--freelancer" ] && FREELANCER_MODE="true"; done && if [ "$FREELANCER_MODE" = "true" ]; then WORKER_COUNT=$TOTAL; else [ "$TOTAL" -lt 2 ] && { echo "ERROR: Need ≥2 panes"; exit 1; } || true; WORKER_COUNT=$((TOTAL - 1)); fi

### 2. Create window + grid
bash: tmux new-window -t "$SESSION_NAME" -c "$PROJECT_DIR" && sleep 0.5 && NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}') && for _s in $(seq 1 $((TOTAL - 1))); do tmux split-window -t "${SESSION_NAME}:${NEW_WIN}" -c "$PROJECT_DIR"; done && tmux select-layout -t "${SESSION_NAME}:${NEW_WIN}" tiled && sleep 0.5 && WORKER_PANES_LIST="" && if [ "$FREELANCER_MODE" = "true" ]; then for i in $(seq 0 $((WORKER_COUNT - 1))); do tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -T "T${NEW_WIN} F${i}"; [ -n "$WORKER_PANES_LIST" ] && WORKER_PANES_LIST="${WORKER_PANES_LIST},${i}" || WORKER_PANES_LIST="${i}"; done; else tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.0" -T "T${NEW_WIN} Subtaskmaster"; for i in $(seq 1 $WORKER_COUNT); do tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -T "T${NEW_WIN} W${i}"; [ -n "$WORKER_PANES_LIST" ] && WORKER_PANES_LIST="${WORKER_PANES_LIST},${i}" || WORKER_PANES_LIST="${i}"; done; fi

"create pane failed" = terminal too small.

### 3. Write team env + update session
bash: MGR_PANE="0" && TT="" && [ "$FREELANCER_MODE" = "true" ] && { MGR_PANE=""; TT="freelancer"; } && cat > "${RD}/team_${NEW_WIN}.env.tmp" << TEAM_EOF
SESSION_NAME=${SESSION_NAME}
PROJECT_DIR=${PROJECT_DIR}
PROJECT_NAME=${PROJECT_NAME}
WINDOW_INDEX=${NEW_WIN}
GRID=${GRID}
TOTAL_PANES=${TOTAL}
MANAGER_PANE=${MGR_PANE}
WORKER_PANES=${WORKER_PANES_LIST}
WORKER_COUNT=${WORKER_COUNT}
TEAM_TYPE=${TT}
TEAM_NAME=${FREELANCER_MODE:+Freelancers}
TEAM_EOF
mv "${RD}/team_${NEW_WIN}.env.tmp" "${RD}/team_${NEW_WIN}.env" && CUR=$(grep '^TEAM_WINDOWS=' "${RD}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"') && { [ -n "$CUR" ] && NW="${CUR},${NEW_WIN}" || NW="${NEW_WIN}"; } && TMPENV=$(mktemp "${RD}/session.env.tmp_XXXXXX") && if grep -q '^TEAM_WINDOWS=' "${RD}/session.env"; then sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NW}/" "${RD}/session.env" > "$TMPENV"; else cat "${RD}/session.env" > "$TMPENV"; echo "TEAM_WINDOWS=${NW}" >> "$TMPENV"; fi && mv "$TMPENV" "${RD}/session.env"

### 4. Launch Claude
bash: if [ "$FREELANCER_MODE" = "true" ]; then for i in $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do WP=$(grep -rl "pane ${NEW_WIN}\.${i} " "${RD}"/worker-system-prompt-*.md 2>/dev/null | head -1); CMD="claude --dangerously-skip-permissions --model opus --name \"T${NEW_WIN} F${i}\""; [ -n "$WP" ] && CMD="${CMD} --append-system-prompt-file \"${WP}\""; tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" "$CMD" Enter; sleep 0.5; done; else tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.0" "claude --dangerously-skip-permissions --name \"T${NEW_WIN} Subtaskmaster\" --agent \"t${NEW_WIN}-manager\"" Enter && sleep 1; for i in $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do WP=$(grep -rl "pane ${NEW_WIN}\.${i} " "${RD}"/worker-system-prompt-*.md 2>/dev/null | head -1); CMD="claude --dangerously-skip-permissions --model opus --name \"T${NEW_WIN} W${i}\""; [ -n "$WP" ] && CMD="${CMD} --append-system-prompt-file \"${WP}\""; tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" "$CMD" Enter; sleep 0.5; done; fi

### 5. Layout
bash: bash -c "eval \"\$(sed -n '/^_env_val()/,/^}/p' '${PROJECT_DIR}/shell/doey.sh')\" && eval \"\$(sed -n '/^_layout_checksum()/,/^}/p' '${PROJECT_DIR}/shell/doey.sh')\" && eval \"\$(sed -n '/^rebalance_grid_layout()/,/^}/p' '${PROJECT_DIR}/shell/doey.sh')\" && rebalance_grid_layout '${SESSION_NAME}' '${NEW_WIN}' '${RD}'"

### 6. Worktree (if --worktree, best-effort)
bash: if [ "$WORKTREE_MODE" = "true" ]; then WT_BRANCH="doey/team-${NEW_WIN}-$(date +%m%d-%H%M)"; WT_DIR="/tmp/doey/${PROJECT_NAME}/worktrees/team-${NEW_WIN}"; mkdir -p "$(dirname "$WT_DIR")"; if git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$WT_BRANCH" 2>&1; then [ -f "${PROJECT_DIR}/.claude/settings.local.json" ] && mkdir -p "${WT_DIR}/.claude" && cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/"; _t=$(mktemp "${RD}/team_env_XXXXXX"); cat "${RD}/team_${NEW_WIN}.env" > "$_t"; printf 'WORKTREE_DIR="%s"\nWORKTREE_BRANCH="%s"\n' "$WT_DIR" "$WT_BRANCH" >> "$_t"; mv "$_t" "${RD}/team_${NEW_WIN}.env"; else echo "WARNING: Worktree failed."; fi; fi

### 7. Verify boot
bash: sleep 8 && NOT_READY=0 && DOWN="" && for i in 0 $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do CHILD=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p '#{pane_pid}')" 2>/dev/null); OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p 2>/dev/null); if [ -z "$CHILD" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then NOT_READY=$((NOT_READY + 1)); DOWN="$DOWN ${NEW_WIN}.$i"; fi; done; [ "$NOT_READY" -eq 0 ] && echo "All booted" || echo "WARNING: ${NOT_READY} not ready:${DOWN}"

Pane 0 = Manager (freelancer: all workers). Write team env before launch. Copy `.claude/settings.local.json` into worktrees.
