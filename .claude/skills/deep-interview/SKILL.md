---
name: deep-interview
description: "Spawn a Deep Interview window — structured requirements extraction before complex tasks"
---

- Current windows: !`tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null || true`
- Session config: !`cat /tmp/doey/*/session.env 2>/dev/null | head -20 || true`
- Team def exists: !`bash -c 'for d in . .doey teams "${HOME}/.config/doey/teams"; do [ -f "${d}/interview.team.md" ] && echo "YES: ${d}/interview.team.md" && exit 0; done; echo "NOT FOUND"'`

Spawn a dedicated **Deep Interview** window for structured requirements extraction before complex tasks. Goal from ARGUMENTS (if empty, use AskUserQuestion to ask, then stop).

This is NOT a generic task creator — it spawns a purpose-built interview team with an Interviewer (Masterplanner persona), a Researcher, and a live Brief display. Use `/doey-planned-task` instead if the goal is straightforward.

### Step 1: Validate Goal

The goal MUST come from ARGUMENTS. If ARGUMENTS is empty, use AskUserQuestion to ask the user for their goal, then stop (the user will re-invoke the skill with the goal).

### Step 2: Setup Working Directory

Create the interview working directory and write the goal file so the Interviewer can pick it up on boot:

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null)
INTERVIEW_ID="interview-$(date +%Y%m%d-%H%M%S)"
INTERVIEW_DIR="${RD}/${INTERVIEW_ID}"
mkdir -p "${INTERVIEW_DIR}/research"
echo "Interview ID: ${INTERVIEW_ID}"
echo "Working directory: ${INTERVIEW_DIR}"
```

Write the goal file — this is how the Interviewer discovers what to work on:

```bash
cat > "${INTERVIEW_DIR}/goal.md" << 'GOAL_EOF'
<INSERT THE GOAL FROM ARGUMENTS HERE — the full text the user provided>
GOAL_EOF
echo "Goal written to ${INTERVIEW_DIR}/goal.md"
```

Create a tracked task and export env vars:

```bash
DOEY_TASK_ID=$(doey task create --title "Deep Interview: $(head -1 "${INTERVIEW_DIR}/goal.md")" --type interview --description "Structured clarification interview for: $(head -1 "${INTERVIEW_DIR}/goal.md")" 2>/dev/null) || true
echo "Task ID: ${DOEY_TASK_ID:-none}"

tmux set-environment -t "$SESSION_NAME" DOEY_INTERVIEW_DIR "$INTERVIEW_DIR" 2>/dev/null || true
tmux set-environment -t "$SESSION_NAME" DOEY_INTERVIEW_ID "$INTERVIEW_ID" 2>/dev/null || true
tmux set-environment -t "$SESSION_NAME" DOEY_TASK_ID "${DOEY_TASK_ID:-}" 2>/dev/null || true
```

### Step 3: Spawn the Interview Team Window

Spawn the dedicated interview team window using the CLI. This creates a window with an Interviewer (pane 0), Researcher (pane 1), and live Brief viewer (pane 2):

```bash
doey add-team interview
```

If `doey add-team interview` fails (non-zero exit), report the error and stop — do NOT fall back to manual window creation.

### Step 4: Brief the Interviewer

After the team window spawns, wait for the Interviewer to boot, then send it the goal and context:

```bash
NEW_WIN=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index} #{window_name}' 2>/dev/null | grep -i interview | tail -1 | awk '{print $1}')
if [ -z "$NEW_WIN" ]; then
  echo "ERROR: interview window not found after add-team"
  exit 1
fi
echo "Interview window: ${NEW_WIN}"
```

Wait for the Interviewer to be ready, then send the briefing:

```bash
INTERVIEWER_PANE="${SESSION_NAME}:${NEW_WIN}.0"
sleep "${DOEY_MANAGER_BRIEF_DELAY:-8}"
source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true

BRIEFING="You have a new interview. Goal file: ${INTERVIEW_DIR}/goal.md
Task ID: ${DOEY_TASK_ID:-none}
Interview directory: ${INTERVIEW_DIR}
Read the goal file and begin the interview. The user is in the Boss pane (window 0, pane 1). Use AskUserQuestion to ask questions. Update ${INTERVIEW_DIR}/brief.md after each phase so the live viewer stays current.
Begin with Phase 1: Intent Extraction."

doey_send_verified "$INTERVIEWER_PANE" "$BRIEFING" && echo "Interviewer briefed successfully" || echo "WARNING: Interviewer briefing delivery failed — will discover goal from ${INTERVIEW_DIR}/goal.md"
```

### Step 5: Notify Taskmaster

```bash
TASKMASTER_PANE=$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)
TASKMASTER_PANE="${TASKMASTER_PANE:-1.0}"

doey msg send --to "${SESSION_NAME}:${TASKMASTER_PANE}" --from "${DOEY_PANE_ID}" \
  --subject "interview_spawned" \
  --body "INTERVIEW_ID: ${INTERVIEW_ID}
TASK_ID: ${DOEY_TASK_ID:-}
WINDOW: ${NEW_WIN}
GOAL: $(head -5 "${INTERVIEW_DIR}/goal.md")
DIR: ${INTERVIEW_DIR}"
doey msg trigger --pane "${SESSION_NAME}:${TASKMASTER_PANE}"
echo "Taskmaster notified"
```

### Step 6: Report

Output the final summary:

```
## Deep Interview Spawned

**Interview ID:** ${INTERVIEW_ID}
**Task ID:** ${DOEY_TASK_ID:-none}
**Window:** ${NEW_WIN} (interview)
**Goal file:** ${INTERVIEW_DIR}/goal.md
**Brief file:** ${INTERVIEW_DIR}/brief.md

The interview team is now running in window ${NEW_WIN}:
- **Pane 0** — Interviewer (Masterplanner persona — drives the conversation)
- **Pane 1** — Researcher (codebase lookups on demand)
- **Pane 2** — Brief (live display — updates as interview progresses)

The Interviewer will ask structured questions about intent, scope, non-goals, and success criteria. When complete, the brief will be dispatched to the Taskmaster automatically.

Teardown: `/doey-kill-window ${NEW_WIN}`
```

### Rules
- Always use AskUserQuestion for user interaction — never inline questions
- The skill is a launcher — all interview logic lives in the Interviewer agent within the interview team window
- Use absolute paths only
- If `doey add-team interview` fails, report the error and stop
- Do NOT run any interview phases inline — that is the Interviewer's job
- The goal file at `${INTERVIEW_DIR}/goal.md` is the handoff mechanism — write it before spawning the team
- Works from any caller context (Boss, Taskmaster, or any agent)
