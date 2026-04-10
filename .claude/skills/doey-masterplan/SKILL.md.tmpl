---
name: doey-masterplan
description: Strategic planning with ultrathink research — multi-agent deep analysis, vertical phase design, and verified execution. Usage: /doey-masterplan <goal>
---

- Current tasks: !`doey task list 2>/dev/null || echo "No tasks"`
- Plans dir: !`bash -c 'PD=$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); echo "${PD:-.}/.doey/plans"'`
- Existing plans: !`bash -c 'PD=$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); ls "${PD:-.}/.doey/plans/"*.md 2>/dev/null | head -10 || echo "None"'`
- Team def exists: !`bash -c 'for d in . .doey teams "${HOME}/.config/doey/teams"; do [ -f "${d}/masterplan.team.md" ] && echo "YES: ${d}/masterplan.team.md" && exit 0; done; echo "NOT FOUND"'`

Spawn a dedicated Masterplanner team window for strategic planning. Goal from ARGUMENTS (if empty, use AskUserQuestion to ask, then stop).

This is NOT a quick task planner — it spawns a full team window with a Planner, live plan viewer, and 4 research workers. Use `/doey-planned-task` instead if the goal is a single feature or straightforward change.

### Step 1: Validate Goal

The goal MUST come from ARGUMENTS. If ARGUMENTS is empty, use AskUserQuestion to ask the user for their goal, then stop (the user will re-invoke the skill with the goal).

### Step 2: Setup Working Directory

Create the masterplan working directory and write the goal file so the Planner can pick it up on boot:

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
PROJECT=$(tmux show-environment DOEY_PROJECT 2>/dev/null | cut -d= -f2-)
PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RD}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
PROJECT_DIR="${PROJECT_DIR:-.}"
PLANS_DIR="${PROJECT_DIR}/.doey/plans"
PLAN_ID="masterplan-$(date +%Y%m%d-%H%M%S)"
MP_DIR="/tmp/doey/${PROJECT}/${PLAN_ID}"
SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null)
mkdir -p "${MP_DIR}/research" "${PLANS_DIR}"
echo "Masterplan ID: ${PLAN_ID}"
echo "Working directory: ${MP_DIR}"
```

Write the goal file — this is how the Planner discovers what to work on:

```bash
cat > "${MP_DIR}/goal.md" << 'GOAL_EOF'
<INSERT THE GOAL FROM ARGUMENTS HERE — the full text the user provided>
GOAL_EOF
echo "Goal written to ${MP_DIR}/goal.md"
```

Write the plan file path so the Planner and viewer share the same file:

```bash
PLAN_FILE="${PLANS_DIR}/${PLAN_ID}.md"
GOAL=$(head -1 "${MP_DIR}/goal.md")

# Create tracked task
DOEY_TASK_ID=$(doey task create --title "Masterplan: ${GOAL}" --type feature --description "Masterplan: ${GOAL}" 2>/dev/null) || true
echo "Task ID: ${DOEY_TASK_ID:-none}"

# Create plan in DB for TUI display
PLAN_DB_ID=""
if [ -n "${DOEY_TASK_ID:-}" ]; then
  PLAN_DB_ID=$(doey plan create --task-id "$DOEY_TASK_ID" --title "Masterplan: ${GOAL}" --status active 2>/dev/null | grep -o '[0-9][0-9]*$') || true
  echo "Plan DB ID: ${PLAN_DB_ID:-none}"
fi

# Export to tmux session environment so spawned panes inherit
tmux set-environment -t "$SESSION_NAME" DOEY_TASK_ID "${DOEY_TASK_ID:-}" 2>/dev/null || true
[ -n "${PLAN_DB_ID:-}" ] && tmux set-environment -t "$SESSION_NAME" PLAN_DB_ID "$PLAN_DB_ID" 2>/dev/null || true

cat > "${MP_DIR}/masterplan.env" << ENV_EOF
PLAN_ID=${PLAN_ID}
PLAN_FILE=${PLAN_FILE}
GOAL_FILE=${MP_DIR}/goal.md
MP_DIR=${MP_DIR}
PLANS_DIR=${PLANS_DIR}
DOEY_TASK_ID=${DOEY_TASK_ID:-}
PLAN_DB_ID=${PLAN_DB_ID:-}
ENV_EOF
echo "Masterplan env written to ${MP_DIR}/masterplan.env"
```

### Step 3: Spawn the Masterplanner Team Window

Spawn the dedicated masterplan team window using the CLI. This creates a window with a Planner (pane 0), live plan viewer (pane 1), and 4 workers (panes 2-5):

```bash
doey add-team masterplan
```

If `doey add-team masterplan` fails (non-zero exit), report the error and stop — do NOT fall back to running the planning process inline.

### Step 4: Brief the Planner

After the team window spawns, wait for the Planner to boot, then send it the goal and context. Find the new window index and send the briefing:

```bash
# Find the masterplan window
MP_WIN=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index} #{window_name}' 2>/dev/null | grep 'masterplan' | tail -1 | awk '{print $1}')
if [ -z "$MP_WIN" ]; then
  echo "ERROR: masterplan window not found after add-team"
  exit 1
fi
echo "Masterplan window: ${MP_WIN}"
```

Wait for the Planner to be ready, then send the briefing:

```bash
sleep 10
PLANNER_PANE="${SESSION_NAME}:${MP_WIN}.0"
source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true

BRIEFING="You are the Masterplanner for plan ${PLAN_ID}.

## Goal
$(cat "${MP_DIR}/goal.md")

## Context
- Plan ID: ${PLAN_ID}
- Goal file: ${MP_DIR}/goal.md
- Plan file: ${PLAN_FILE}
- Working directory: ${MP_DIR}
- Research directory: ${MP_DIR}/research/
- Plans directory: ${PLANS_DIR}
- Task ID: ${DOEY_TASK_ID:-none}
- Plan DB ID: ${PLAN_DB_ID:-none}

Read the goal file and begin the masterplan process. Use your workers (panes 2-5) for parallel research. Write the plan to the plan file path above — the TUI (pane 1) will display it.

IMPORTANT: After each major update to the plan file, sync it to the DB so the TUI Plans tab stays current:
doey plan update --id ${PLAN_DB_ID:-0} --body \"\$(cat ${PLAN_FILE})\"
Skip this step if Plan DB ID is 'none' or '0'."

doey_send_verified "$PLANNER_PANE" "$BRIEFING" && echo "Planner briefed successfully" || echo "WARNING: Planner briefing delivery failed — the Planner will still discover the goal from ${MP_DIR}/goal.md on its own"
```

### Step 5: Notify Taskmaster (Informational)

Let the Taskmaster know a masterplan window was spawned so it can track the work:

```bash
TASKMASTER_PANE=$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)
TASKMASTER_PANE="${TASKMASTER_PANE:-1.0}"

doey msg send --to "${SESSION_NAME}:${TASKMASTER_PANE}" --from "${DOEY_PANE_ID}" \
  --subject "masterplan_spawned" \
  --body "MASTERPLAN_ID: ${PLAN_ID}
PLAN_FILE: ${PLAN_FILE}
GOAL_FILE: ${MP_DIR}/goal.md
TASK_ID: ${DOEY_TASK_ID:-}
PLAN_DB_ID: ${PLAN_DB_ID:-}
DISPATCH_MODE: dedicated-window
WINDOW: ${MP_WIN}

Masterplan '${PLAN_ID}' has its own dedicated window (window ${MP_WIN}).
The Planner manages research, synthesis, phase design, and verification internally.
Goal: $(head -5 "${MP_DIR}/goal.md")"
doey msg trigger --pane "${SESSION_NAME}:${TASKMASTER_PANE}"
echo "Taskmaster notified"
```

### Step 6: Report

Output the final summary:

```
## Masterplan Spawned

**Plan ID:** ${PLAN_ID}
**Task ID:** ${DOEY_TASK_ID:-none}
**Plan DB ID:** ${PLAN_DB_ID:-none}
**Window:** ${MP_WIN} (masterplan)
**Goal file:** ${MP_DIR}/goal.md
**Plan file:** ${PLAN_FILE}
**Working dir:** ${MP_DIR}

The Masterplanner team is now running in window ${MP_WIN}:
- **Pane 0** — Planner (orchestrates research and plan writing)
- **Pane 1** — TUI (Plans tab — live plan display)
- **Panes 2-5** — Workers (research swarm, then implementation)

The Planner will:
1. Interrogate intent and confirm with the user
2. Dispatch parallel research to workers
3. Synthesize findings and design vertical phases
4. Present the plan for approval
5. Create tasks and begin phased execution

No further action needed — the masterplan team is autonomous.
```

### Rules
- Always use AskUserQuestion for user interaction — never inline questions
- The skill is a launcher — all planning logic lives in the Planner agent within the masterplan team window
- Use absolute paths only
- If `doey add-team masterplan` fails, report the error and stop
- Do NOT run any planning phases (research, synthesis, etc.) inline — that is the Planner's job
- The goal file at `${MP_DIR}/goal.md` is the handoff mechanism — write it before spawning the team
- The plan file at `${PLAN_FILE}` is the integration point between Planner and viewer
- Works from any caller context (Boss, Taskmaster, or any agent)
