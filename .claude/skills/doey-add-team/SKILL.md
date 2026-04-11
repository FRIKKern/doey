---
name: doey-add-team
description: Spawn a team from a .team.md definition file. Usage: /doey-add-team <name>
---

## Context

- Session config: !`cat /tmp/doey/*/session.env 2>/dev/null | head -20 || true`
- Current windows: !`tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null || true`
- Available team defs: !`ls -1 .team.md *.team.md .doey/*.team.md ~/.config/doey/teams/*.team.md 2>/dev/null || echo "(none found in common locations)"`

## Prompt

Spawn a team from a `.team.md` file. **No confirmation. Taskmaster/Subtaskmaster only.**

### .team.md Format

```markdown
---
name: team-name
description: What this team does
---
## Panes
| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | manager | doey-subtaskmaster | Subtaskmaster | opus |
| 1 | reviewer | - | Reviewer | opus |

## Workflows
| Trigger | From | To | Subject |
|---------|------|----|---------|
| stop | reviewer | manager | review_complete |
```

### Step 1: Load session, try CLI first

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
TEAM_NAME="${1:?Usage: /doey-add-team <name>}"

if command -v doey >/dev/null 2>&1 && doey add-team "$TEAM_NAME" 2>/dev/null; then
  echo "Team spawned via doey CLI"; exit 0
fi
```

### Step 2: Find and parse .team.md

```bash
TEAM_DEF=""
for _search_dir in "$PROJECT_DIR" "$PROJECT_DIR/.doey" "${HOME}/.config/doey/teams" "$(dirname "$(command -v doey 2>/dev/null || echo /dev/null)")/../../share/doey/teams"; do
  for _candidate in "${_search_dir}/${TEAM_NAME}.team.md" "${_search_dir}/${TEAM_NAME}"; do
    [ -f "$_candidate" ] && { TEAM_DEF="$_candidate"; break 2; }
  done
done
[ -z "$TEAM_DEF" ] && { echo "ERROR: '${TEAM_NAME}' not found"; exit 1; }
```

```bash
TEAMDEF_FILE="${RUNTIME_DIR}/teamdef_${TEAM_NAME}.env"
TEAM_DESC=$(sed -n '/^---$/,/^---$/{ /^description:/{ s/^description:[[:space:]]*//; p; }; }' "$TEAM_DEF")

PANE_COUNT=0
PANE_DEFS=""
_in_panes=false
while IFS= read -r line; do
  case "$line" in
    "## Panes"*) _in_panes=true; continue ;;
    "## "*) _in_panes=false; continue ;;
  esac
  [ "$_in_panes" = "false" ] && continue
  echo "$line" | grep -q '^|[[:space:]]*Pane' && continue
  echo "$line" | grep -q '^|[[:space:]]*-' && continue
  echo "$line" | grep -q '^|' || continue
  _pane=$(echo "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  _role=$(echo "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  _agent=$(echo "$line" | cut -d'|' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  _name=$(echo "$line" | cut -d'|' -f5 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  _model=$(echo "$line" | cut -d'|' -f6 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$_pane" ] && continue
  [ "$_agent" = "-" ] && _agent=""
  PANE_DEFS="${PANE_DEFS}${_pane}|${_role}|${_agent}|${_name}|${_model}
"
  PANE_COUNT=$(( PANE_COUNT + 1 ))
done < "$TEAM_DEF"

[ "$PANE_COUNT" -eq 0 ] && { echo "ERROR: No pane definitions found in $TEAM_DEF"; exit 1; }
echo "Parsed ${PANE_COUNT} panes from team definition"

# Parse workflows
WORKFLOWS=""
_in_workflows=false
while IFS= read -r line; do
  case "$line" in
    "## Workflows"*) _in_workflows=true; continue ;;
    "## "*) _in_workflows=false; continue ;;
  esac
  [ "$_in_workflows" = "false" ] && continue
  echo "$line" | grep -q '^|[[:space:]]*Trigger' && continue
  echo "$line" | grep -q '^|[[:space:]]*-' && continue
  echo "$line" | grep -q '^|' || continue
  _trigger=$(echo "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  _from=$(echo "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  _to=$(echo "$line" | cut -d'|' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  _subject=$(echo "$line" | cut -d'|' -f5 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$_trigger" ] && continue
  WORKFLOWS="${WORKFLOWS}${_trigger}|${_from}|${_to}|${_subject}
"
done < "$TEAM_DEF"

# Write teamdef env
cat > "${TEAMDEF_FILE}.tmp" << TDEF_EOF
TEAM_DEF_NAME=${TEAM_NAME}
TEAM_DEF_DESC=${TEAM_DESC}
TEAM_DEF_FILE=${TEAM_DEF}
TEAM_DEF_PANE_COUNT=${PANE_COUNT}
TEAM_DEF_PANES=$(printf '%s' "$PANE_DEFS" | sed '$d' | tr '\n' ';')
TEAM_DEF_WORKFLOWS=$(printf '%s' "$WORKFLOWS" | sed '$d' | tr '\n' ';')
TDEF_EOF
mv "${TEAMDEF_FILE}.tmp" "$TEAMDEF_FILE"
echo "Teamdef written to $TEAMDEF_FILE"
```

### Step 3: Create tmux window and split panes

```bash
tmux new-window -t "$SESSION_NAME" -n "$TEAM_NAME" -c "$PROJECT_DIR"
sleep 0.5
NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')

for _s in $(seq 1 $((PANE_COUNT - 1))); do
  tmux split-window -t "${SESSION_NAME}:${NEW_WIN}" -c "$PROJECT_DIR"
done
tmux select-layout -t "${SESSION_NAME}:${NEW_WIN}" tiled
sleep 0.5

MANAGER_PANE_IDX=""
WORKER_PANES_LIST=""
while IFS='|' read -r _pane _role _agent _name _model; do
  [ -z "$_pane" ] && continue
  tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${_pane}" -T "T${NEW_WIN} ${_name}"
  case "$_role" in
    manager) MANAGER_PANE_IDX="$_pane" ;;
    *) [ -n "$WORKER_PANES_LIST" ] && WORKER_PANES_LIST="${WORKER_PANES_LIST},${_pane}" || WORKER_PANES_LIST="${_pane}" ;;
  esac
done << PANE_INPUT
$(echo "$PANE_DEFS")
PANE_INPUT
WORKER_COUNT=$(echo "$WORKER_PANES_LIST" | tr ',' '\n' | grep -c .)
```

### Step 4: Write team env, update TEAM_WINDOWS

```bash
TEAM_FILE="${RUNTIME_DIR}/team_${NEW_WIN}.env"
cat > "${TEAM_FILE}.tmp" << TEAM_EOF
SESSION_NAME=${SESSION_NAME}
PROJECT_DIR=${PROJECT_DIR}
PROJECT_NAME=${PROJECT_NAME}
WINDOW_INDEX=${NEW_WIN}
GRID=custom
TOTAL_PANES=${PANE_COUNT}
MANAGER_PANE=${MANAGER_PANE_IDX}
WORKER_PANES=${WORKER_PANES_LIST}
WORKER_COUNT=${WORKER_COUNT}
WORKTREE_DIR=
WORKTREE_BRANCH=
TEAM_DEF=${TEAM_NAME}
TEAM_NAME=${TEAM_NAME}
TEAM_DESC=${TEAM_DESC}
TEAM_EOF
mv "${TEAM_FILE}.tmp" "$TEAM_FILE"

CURRENT_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
[ -n "$CURRENT_WINDOWS" ] && NEW_WINDOWS="${CURRENT_WINDOWS},${NEW_WIN}" || NEW_WINDOWS="${NEW_WIN}"
TMPENV=$(mktemp "${RUNTIME_DIR}/session.env.tmp_XXXXXX")
if grep -q '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env"; then
  sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NEW_WINDOWS}/" "${RUNTIME_DIR}/session.env" > "$TMPENV"
else
  cat "${RUNTIME_DIR}/session.env" > "$TMPENV"
  echo "TEAM_WINDOWS=${NEW_WINDOWS}" >> "$TMPENV"
fi
mv "$TMPENV" "${RUNTIME_DIR}/session.env"
```

### Step 5: Launch Claude instances (3s stagger)

```bash
while IFS='|' read -r _pane _role _agent _name _model; do
  [ -z "$_pane" ] && continue
  _model_flag=""
  [ -n "$_model" ] && _model_flag="--model $_model"
  _agent_flag=""
  [ -n "$_agent" ] && _agent_flag="--agent \"$_agent\""
  _cmd="claude --dangerously-skip-permissions ${_model_flag} --name \"T${NEW_WIN} ${_name}\" ${_agent_flag}"
  source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true
  doey_send_command "${SESSION_NAME}:${NEW_WIN}.${_pane}" "$_cmd"
  sleep 3
done << LAUNCH_INPUT
$(echo "$PANE_DEFS")
LAUNCH_INPUT
echo "All ${PANE_COUNT} Claude instances launched"

bash -c "
  eval \"\$(sed -n '/^_env_val()/,/^}/p' '${PROJECT_DIR}/shell/doey.sh')\"
  eval \"\$(sed -n '/^_layout_checksum()/,/^}/p' '${PROJECT_DIR}/shell/doey.sh')\"
  eval \"\$(sed -n '/^rebalance_grid_layout()/,/^}/p' '${PROJECT_DIR}/shell/doey.sh')\"
  rebalance_grid_layout '${SESSION_NAME}' '${NEW_WIN}' '${RUNTIME_DIR}'
"
```

### Step 6: Brief the Subtaskmaster with team context

```bash
if [ -n "$MANAGER_PANE_IDX" ]; then
  sleep 8
  MGR_PANE="${SESSION_NAME}:${NEW_WIN}.${MANAGER_PANE_IDX}"
  BRIEFING=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
  cat > "$BRIEFING" << BRIEF_EOF
You are leading team "${TEAM_NAME}": ${TEAM_DESC}

Your panes (from ${TEAM_DEF}):
$(echo "$PANE_DEFS" | while IFS='|' read -r _p _r _a _n _m; do [ -n "$_p" ] && echo "- Pane $_p: $_n (role: $_r, agent: ${_a:-none}, model: $_m)"; done)

Workflows:
$(echo "$WORKFLOWS" | while IFS='|' read -r _t _f _to _s; do [ -n "$_t" ] && echo "- On $_t from $_f -> notify $_to (subject: $_s)"; done)

Coordinate your team. Dispatch initial tasks to workers based on the team definition.
BRIEF_EOF

  source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true
  BRIEFING_CONTENT=$(cat "$BRIEFING")
  doey_send_verified "$MGR_PANE" "$BRIEFING_CONTENT" && echo "Subtaskmaster briefed" || echo "Subtaskmaster briefing delivery failed"
  rm -f "$BRIEFING"
fi
```

### Step 7: Verify boot and report

```bash
sleep 5
NOT_READY=0; DOWN_PANES=""
while IFS='|' read -r _pane _role _agent _name _model; do
  [ -z "$_pane" ] && continue
  CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${NEW_WIN}.${_pane}" -p '#{pane_pid}')" 2>/dev/null)
  OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${NEW_WIN}.${_pane}" -p 2>/dev/null)
  if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
    NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${NEW_WIN}.$_pane"
  fi
done << VERIFY_INPUT
$(echo "$PANE_DEFS")
VERIFY_INPUT
if [ "$NOT_READY" -eq 0 ]; then echo "All panes booted"; else echo "WARNING: ${NOT_READY} not ready:${DOWN_PANES}"; fi
```

Output: team name, window, layout, boot status. Teardown: `/doey-kill-window ${NEW_WIN}`. Bash 3.2. 3s stagger. Search: root → `.doey/` → `~/.config/doey/teams/` → share. Missing `## Workflows` = skip. Agent `-` = no flag.
