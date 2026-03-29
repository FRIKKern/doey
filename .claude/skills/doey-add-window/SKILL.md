---
name: doey-add-window
description: Add a new team window (Manager + Workers), optionally in a git worktree or as a freelancer pool.
---

## Usage
`/doey-add-window [grid] [--worktree] [--freelancer]` — default grid: 4x2

## Context

Session config:
!`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Current windows:
!`tmux list-windows -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{window_index} #{window_name}' 2>/dev/null|| true`

## Prompt

Add a new team window. **Do NOT ask for confirmation — just do it.**

## Step 1: Parse and validate
bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && _sv() { grep "^$1=" "${RUNTIME_DIR}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; } && SESSION_NAME=$(_sv SESSION_NAME) && PROJECT_DIR=$(_sv PROJECT_DIR) && PROJECT_NAME=$(_sv PROJECT_NAME) && GRID="${USER_GRID:-4x2}" && COLS=$(echo "$GRID" | cut -dx -f1) && ROWS=$(echo "$GRID" | cut -dx -f2) && case "$COLS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid cols: $COLS"; exit 1 ;; esac && case "$ROWS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid rows: $ROWS"; exit 1 ;; esac && TOTAL=$((COLS * ROWS)) && WORKTREE_MODE="false" && FREELANCER_MODE="false" && for _aw_arg in "$@"; do [ "$_aw_arg" = "--worktree" ] && WORKTREE_MODE="true"; [ "$_aw_arg" = "--freelancer" ] && FREELANCER_MODE="true"; done && if [ "$FREELANCER_MODE" = "true" ]; then WORKER_COUNT=$TOTAL; else [ "$TOTAL" -lt 2 ] && { echo "ERROR: Need at least 2 panes"; exit 1; } || true; WORKER_COUNT=$((TOTAL - 1)); fi && echo "Grid=${GRID} Total=${TOTAL} Workers=${WORKER_COUNT} Worktree=${WORKTREE_MODE} Freelancer=${FREELANCER_MODE}"

## Step 2: Create window, build grid, name panes
bash: tmux new-window -t "$SESSION_NAME" -c "$PROJECT_DIR" && sleep 0.5 && NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}') && for _s in $(seq 1 $((TOTAL - 1))); do tmux split-window -t "${SESSION_NAME}:${NEW_WIN}" -c "$PROJECT_DIR"; done && tmux select-layout -t "${SESSION_NAME}:${NEW_WIN}" tiled && sleep 0.5 && WORKER_PANES_LIST="" && if [ "$FREELANCER_MODE" = "true" ]; then for i in $(seq 0 $((WORKER_COUNT - 1))); do tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -T "T${NEW_WIN} F${i}"; [ -n "$WORKER_PANES_LIST" ] && WORKER_PANES_LIST="${WORKER_PANES_LIST},${i}" || WORKER_PANES_LIST="${i}"; done; else tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.0" -T "T${NEW_WIN} Window Manager"; for i in $(seq 1 $WORKER_COUNT); do tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -T "T${NEW_WIN} W${i}"; [ -n "$WORKER_PANES_LIST" ] && WORKER_PANES_LIST="${WORKER_PANES_LIST},${i}" || WORKER_PANES_LIST="${i}"; done; fi && echo "Window ${NEW_WIN} created with ${TOTAL} panes (freelancer=${FREELANCER_MODE})"

If "create pane failed": terminal too small — reduce grid or maximize.

## Step 3: Write team env and update session
bash: TEAM_FILE="${RUNTIME_DIR}/team_${NEW_WIN}.env" && MGR_PANE="0" && TEAM_TYPE_VAL="" && [ "$FREELANCER_MODE" = "true" ] && { MGR_PANE=""; TEAM_TYPE_VAL="freelancer"; } && cat > "${TEAM_FILE}.tmp" << TEAM_EOF
SESSION_NAME=${SESSION_NAME}
PROJECT_DIR=${PROJECT_DIR}
PROJECT_NAME=${PROJECT_NAME}
WINDOW_INDEX=${NEW_WIN}
GRID=${GRID}
TOTAL_PANES=${TOTAL}
MANAGER_PANE=${MGR_PANE}
WORKER_PANES=${WORKER_PANES_LIST}
WORKER_COUNT=${WORKER_COUNT}
TEAM_TYPE=${TEAM_TYPE_VAL}
TEAM_NAME=${FREELANCER_MODE:+Freelancers}
TEAM_EOF
mv "${TEAM_FILE}.tmp" "$TEAM_FILE" && CURRENT_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"') && { [ -n "$CURRENT_WINDOWS" ] && NEW_WINDOWS="${CURRENT_WINDOWS},${NEW_WIN}" || NEW_WINDOWS="${NEW_WIN}"; } && TMPENV=$(mktemp "${RUNTIME_DIR}/session.env.tmp_XXXXXX") && if grep -q '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env"; then sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NEW_WINDOWS}/" "${RUNTIME_DIR}/session.env" > "$TMPENV"; else cat "${RUNTIME_DIR}/session.env" > "$TMPENV"; echo "TEAM_WINDOWS=${NEW_WINDOWS}" >> "$TMPENV"; fi && mv "$TMPENV" "${RUNTIME_DIR}/session.env" && echo "team_${NEW_WIN}.env written, TEAM_WINDOWS=${NEW_WINDOWS}"

## Step 4: Launch Claude in all panes
bash: if [ "$FREELANCER_MODE" = "true" ]; then for i in $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do WORKER_PROMPT=$(grep -rl "pane ${NEW_WIN}\.${i} " "${RUNTIME_DIR}"/worker-system-prompt-*.md 2>/dev/null | head -1); CMD="claude --dangerously-skip-permissions --model opus --name \"T${NEW_WIN} F${i}\""; [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""; tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" "$CMD" Enter; sleep 0.5; done; echo "Launched: ${WORKER_COUNT} freelancers"; else tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.0" "claude --dangerously-skip-permissions --name \"T${NEW_WIN} Window Manager\" --agent \"t${NEW_WIN}-manager\"" Enter && sleep 1; for i in $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do WORKER_PROMPT=$(grep -rl "pane ${NEW_WIN}\.${i} " "${RUNTIME_DIR}"/worker-system-prompt-*.md 2>/dev/null | head -1); CMD="claude --dangerously-skip-permissions --model opus --name \"T${NEW_WIN} W${i}\""; [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""; tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" "$CMD" Enter; sleep 0.5; done; echo "Launched: Manager + ${WORKER_COUNT} workers"; fi

## Step 5: Apply standard manager-left layout
bash: bash -c "eval \"\$(sed -n '/^_env_val()/,/^}/p' '${PROJECT_DIR}/shell/doey.sh')\" && eval \"\$(sed -n '/^_layout_checksum()/,/^}/p' '${PROJECT_DIR}/shell/doey.sh')\" && eval \"\$(sed -n '/^rebalance_grid_layout()/,/^}/p' '${PROJECT_DIR}/shell/doey.sh')\" && rebalance_grid_layout '${SESSION_NAME}' '${NEW_WIN}' '${RUNTIME_DIR}'"

## Step 6: Create worktree (if --worktree)
Best-effort — team still created if worktree fails.

bash: WT_DIR="" && WT_BRANCH="" && if [ "$WORKTREE_MODE" = "true" ]; then WT_BRANCH="doey/team-${NEW_WIN}-$(date +%m%d-%H%M)"; WT_DIR="/tmp/doey/${PROJECT_NAME}/worktrees/team-${NEW_WIN}"; mkdir -p "$(dirname "$WT_DIR")"; if ! git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$WT_BRANCH" 2>&1; then echo "WARNING: Worktree failed. Team created without isolation."; WT_DIR=""; WT_BRANCH=""; else [ -f "${PROJECT_DIR}/.claude/settings.local.json" ] && mkdir -p "${WT_DIR}/.claude" && cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/settings.local.json"; _tmp_env=$(mktemp "${RUNTIME_DIR}/team_env_XXXXXX"); cat "${RUNTIME_DIR}/team_${NEW_WIN}.env" > "$_tmp_env"; printf 'WORKTREE_DIR="%s"\nWORKTREE_BRANCH="%s"\n' "$WT_DIR" "$WT_BRANCH" >> "$_tmp_env"; mv "$_tmp_env" "${RUNTIME_DIR}/team_${NEW_WIN}.env"; echo "Worktree created: ${WT_DIR} on branch ${WT_BRANCH}"; fi; else echo "Skipped (--worktree not set)"; fi

## Step 7: Verify boot and report
bash: sleep 8 && NOT_READY=0 && DOWN_PANES="" && for i in 0 $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p '#{pane_pid}')" 2>/dev/null); OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p 2>/dev/null); if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${NEW_WIN}.$i"; fi; done && [ "$NOT_READY" -eq 0 ] && echo "All panes booted" || echo "WARNING: ${NOT_READY} not ready:${DOWN_PANES}"

If not ready: check listed panes with `tmux capture-pane -t <pane> -p`, retry send-keys.

Rename window if worktree succeeded. Output summary: grid, manager, worker range, worktree info.

### Rules
- Standard team: pane 0 = Manager, 1+ = Workers. Freelancer: all panes = Workers.
- Write team_W.env before launching.
- Never hardcode window indices — derive from `tmux display-message`. Bash 3.2 compatible.
- Agent names: `t${WIN}-manager`. Worktree path: `/tmp/doey/${PROJECT_NAME}/worktrees/team-${WIN}`
- Copy `.claude/settings.local.json` into worktrees (gitignored)
