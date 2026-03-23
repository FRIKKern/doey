---
name: doey-add-window
description: Add a new team window (Manager + Workers + Watchdog), optionally in a git worktree.
---

## Usage
`/doey-add-window [grid] [--worktree]` — default grid: 4x2

## Context

Session config:
!`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Current windows:
!`tmux list-windows -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{window_index} #{window_name}' 2>/dev/null|| true`

## Prompt

Add a new team window to the running Doey session. **Do NOT ask for confirmation — just do it.**

## Step 1: Parse and validate
bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && _sv() { grep "^$1=" "${RUNTIME_DIR}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; } && SESSION_NAME=$(_sv SESSION_NAME) && PROJECT_DIR=$(_sv PROJECT_DIR) && PROJECT_NAME=$(_sv PROJECT_NAME) && GRID="${USER_GRID:-4x2}" && COLS=$(echo "$GRID" | cut -dx -f1) && ROWS=$(echo "$GRID" | cut -dx -f2) && case "$COLS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid cols: $COLS"; exit 1 ;; esac && case "$ROWS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid rows: $ROWS"; exit 1 ;; esac && TOTAL=$((COLS * ROWS)) && [ "$TOTAL" -lt 2 ] && { echo "ERROR: Need at least 2 panes"; exit 1; } || true && WORKER_COUNT=$((TOTAL - 1)) && WORKTREE_MODE="false" && for _aw_arg in "$@"; do [ "$_aw_arg" = "--worktree" ] && WORKTREE_MODE="true"; done && echo "Grid=${GRID} Total=${TOTAL} Workers=${WORKER_COUNT} Worktree=${WORKTREE_MODE}"
Expected: `Grid=4x2 Total=8 Workers=7 Worktree=false` (or matching user args)

**If this fails with "DOEY_RUNTIME: not set":** You are not inside a Doey tmux session. Attach first with `tmux attach -t doey-<project>`.

## Step 2: Create window, build grid, name panes
bash: tmux new-window -t "$SESSION_NAME" -c "$PROJECT_DIR" && sleep 0.5 && NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}') && for _s in $(seq 1 $((TOTAL - 1))); do tmux split-window -t "${SESSION_NAME}:${NEW_WIN}" -c "$PROJECT_DIR"; done && tmux select-layout -t "${SESSION_NAME}:${NEW_WIN}" tiled && sleep 0.5 && tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.0" -T "T${NEW_WIN} Window Manager" && WORKER_PANES_LIST="" && for i in $(seq 1 $WORKER_COUNT); do tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -T "T${NEW_WIN} W${i}"; [ -n "$WORKER_PANES_LIST" ] && WORKER_PANES_LIST="${WORKER_PANES_LIST},${i}" || WORKER_PANES_LIST="${i}"; done && echo "Window ${NEW_WIN} created with ${TOTAL} panes"
Expected: `Window N created with 8 panes` — tmux window visible with tiled layout

**If this fails with "can't find session":** Session `$SESSION_NAME` not running. Check `tmux ls`.
**If this fails with "create pane failed":** Terminal too small for requested grid. Reduce grid size or maximize terminal.

## Step 3: Write team env and update session
bash: TEAM_FILE="${RUNTIME_DIR}/team_${NEW_WIN}.env" && cat > "${TEAM_FILE}.tmp" << TEAM_EOF
SESSION_NAME=${SESSION_NAME}
PROJECT_DIR=${PROJECT_DIR}
PROJECT_NAME=${PROJECT_NAME}
WINDOW_INDEX=${NEW_WIN}
GRID=${GRID}
TOTAL_PANES=${TOTAL}
MANAGER_PANE=0
WORKER_PANES=${WORKER_PANES_LIST}
WORKER_COUNT=${WORKER_COUNT}
WATCHDOG_PANE=
TEAM_EOF
mv "${TEAM_FILE}.tmp" "$TEAM_FILE" && CURRENT_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"') && { [ -n "$CURRENT_WINDOWS" ] && NEW_WINDOWS="${CURRENT_WINDOWS},${NEW_WIN}" || NEW_WINDOWS="${NEW_WIN}"; } && TMPENV=$(mktemp "${RUNTIME_DIR}/session.env.tmp_XXXXXX") && if grep -q '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env"; then sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NEW_WINDOWS}/" "${RUNTIME_DIR}/session.env" > "$TMPENV"; else cat "${RUNTIME_DIR}/session.env" > "$TMPENV"; echo "TEAM_WINDOWS=${NEW_WINDOWS}" >> "$TMPENV"; fi && mv "$TMPENV" "${RUNTIME_DIR}/session.env" && echo "team_${NEW_WIN}.env written, TEAM_WINDOWS=${NEW_WINDOWS}"
Expected: `team_N.env written, TEAM_WINDOWS=1,N` — env file exists and session.env updated

**If this fails with "No such file or directory":** Runtime dir missing. Check `$RUNTIME_DIR` exists.

## Step 4: Launch Claude in all panes
bash: tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.0" "claude --dangerously-skip-permissions --name \"T${NEW_WIN} Window Manager\" --agent \"t${NEW_WIN}-manager\"" Enter && sleep 1 && for i in $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do WORKER_PROMPT=$(grep -rl "pane ${NEW_WIN}\.${i} " "${RUNTIME_DIR}"/worker-system-prompt-*.md 2>/dev/null | head -1); CMD="claude --dangerously-skip-permissions --model opus --name \"T${NEW_WIN} W${i}\""; [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""; tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" "$CMD" Enter; sleep 0.5; done && WDG_SLOT="" && for slot in 2 3 4 5 6 7; do SLOT_CHILD=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:0.${slot}" -p '#{pane_pid}' 2>/dev/null || echo 0)" 2>/dev/null || true); [ -z "$SLOT_CHILD" ] && { WDG_SLOT="$slot"; break; }; done && if [ -n "$WDG_SLOT" ]; then tmux select-pane -t "${SESSION_NAME}:0.${WDG_SLOT}" -T "T${NEW_WIN} Watchdog"; tmux send-keys -t "${SESSION_NAME}:0.${WDG_SLOT}" "claude --dangerously-skip-permissions --model haiku --name \"T${NEW_WIN} Watchdog\" --agent \"t${NEW_WIN}-watchdog\"" Enter; sed "s/^WATCHDOG_PANE=.*/WATCHDOG_PANE=0.${WDG_SLOT}/" "${RUNTIME_DIR}/team_${NEW_WIN}.env" > "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" && mv "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" "${RUNTIME_DIR}/team_${NEW_WIN}.env"; echo "Launched: Manager + ${WORKER_COUNT} workers + Watchdog at 0.${WDG_SLOT}"; else echo "WARNING: No available Dashboard slot for Watchdog — launched Manager + ${WORKER_COUNT} workers only"; fi
Expected: `Launched: Manager + 7 workers + Watchdog at 0.N` — all panes show Claude starting

**If this fails with "No available Dashboard slot":** All Dashboard slots 0.2-0.7 occupied. Team works without Watchdog.
**If this fails with "can't find pane":** Pane indices shifted. Re-check with `tmux list-panes -t ${SESSION_NAME}:${NEW_WIN}`.

## Step 5: Create worktree (if --worktree)
Best-effort — team is still created if worktree fails.

bash: WT_DIR="" && WT_BRANCH="" && if [ "$WORKTREE_MODE" = "true" ]; then WT_BRANCH="doey/team-${NEW_WIN}-$(date +%m%d-%H%M)"; WT_DIR="/tmp/doey/${PROJECT_NAME}/worktrees/team-${NEW_WIN}"; mkdir -p "$(dirname "$WT_DIR")"; if ! git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$WT_BRANCH" 2>&1; then echo "WARNING: Worktree failed. Team created without isolation."; WT_DIR=""; WT_BRANCH=""; else [ -f "${PROJECT_DIR}/.claude/settings.local.json" ] && mkdir -p "${WT_DIR}/.claude" && cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/settings.local.json"; _tmp_env=$(mktemp "${RUNTIME_DIR}/team_env_XXXXXX"); cat "${RUNTIME_DIR}/team_${NEW_WIN}.env" > "$_tmp_env"; printf 'WORKTREE_DIR="%s"\nWORKTREE_BRANCH="%s"\n' "$WT_DIR" "$WT_BRANCH" >> "$_tmp_env"; mv "$_tmp_env" "${RUNTIME_DIR}/team_${NEW_WIN}.env"; echo "Worktree created: ${WT_DIR} on branch ${WT_BRANCH}"; fi; else echo "Skipped (--worktree not set)"; fi
Expected: `Worktree created: /tmp/doey/<project>/worktrees/team-N on branch doey/team-N-MMDD-HHMM` or `Skipped (--worktree not set)`

**If this fails with "already exists":** Branch or path already in use. Remove stale worktree with `git worktree remove /tmp/doey/<project>/worktrees/team-N`.
**If this fails with "not a git repository":** PROJECT_DIR is not a git repo. Worktree requires git.

## Step 6: Verify boot and report
bash: sleep 8 && NOT_READY=0 && DOWN_PANES="" && for i in 0 $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p '#{pane_pid}')" 2>/dev/null); OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p 2>/dev/null); if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${NEW_WIN}.$i"; fi; done && if [ -n "$WDG_SLOT" ]; then WDG_CHILD=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:0.${WDG_SLOT}" -p '#{pane_pid}')" 2>/dev/null); WDG_OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:0.${WDG_SLOT}" -p 2>/dev/null); if [ -z "$WDG_CHILD" ] || ! echo "$WDG_OUTPUT" | grep -q "bypass permissions"; then NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES 0.$WDG_SLOT"; fi; fi && [ "$NOT_READY" -eq 0 ] && echo "All panes booted" || echo "WARNING: ${NOT_READY} not ready:${DOWN_PANES}"
Expected: `All panes booted` — all Claude instances running with bypass permissions

**If this fails with "N not ready":** Some panes didn't start. Check the listed panes with `tmux capture-pane -t <pane> -p` and retry `send-keys` for failed ones.

Rename window if worktree succeeded, then output summary: grid, manager pane, worker range, watchdog slot, worktree info if applicable.

Total: 6 commands, 0 errors expected.

## Gotchas
- Do NOT hardcode window indices — always derive from `tmux display-message`
- Do NOT use bash 3.2 incompatible features (`declare -A`, `mapfile`, `|&`, `&>>`)
- Do NOT skip writing team_W.env before launching Claude instances
- Do NOT launch Watchdog outside Dashboard slots 0.2-0.7
- Do NOT assume `$WORKER_PANES_LIST` order — always derive from grid math

### Rules
- Pane 0 = Manager, 1+ = Workers; Watchdog in Dashboard 0.2-0.7
- Write team_W.env before launching; update TEAM_WINDOWS atomically
- Never hardcode window indices. Bash 3.2 compatible.
- Copy `.claude/settings.local.json` into worktrees (gitignored)
- Agent names: `t${WIN}-manager`, `t${WIN}-watchdog` (matches doey.sh `generate_team_agent`)
- Worktree path: `/tmp/doey/${PROJECT_NAME}/worktrees/team-${WIN}` (matches doey.sh canonical path)
