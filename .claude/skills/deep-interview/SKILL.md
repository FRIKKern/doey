---
name: deep-interview
description: "Spawn a Masterplanner interview window — assertive clarification interview before complex tasks. Asks hard questions, pushes back on vagueness, outputs a dispatch-ready brief. Usage: /deep-interview <goal>"
---

- Current windows: !`tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null || true`
- Session config: !`cat /tmp/doey/*/session.env 2>/dev/null | head -20 || true`

Spawn a dedicated **Deep Interview** window with a Masterplanner who drives a structured clarification interview before complex tasks get dispatched. Goal from ARGUMENTS (if empty, use AskUserQuestion to ask, then stop).

This is NOT a generic task creator — it spawns a purpose-built interview window with a Masterplanner, a Researcher, and a live Brief display. The Masterplanner asks all the hard clarifying questions, the Researcher looks up codebase context in real time, and the Brief pane renders the structured output as the interview progresses.

### Step 1: Validate Goal

The goal MUST come from ARGUMENTS. If ARGUMENTS is empty, use AskUserQuestion to ask the user for their goal, then stop (the user will re-invoke the skill with the goal).

### Step 2: Setup Working Directory

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
PROJECT=$(tmux show-environment DOEY_PROJECT 2>/dev/null | cut -d= -f2-)
PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RD}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
PROJECT_DIR="${PROJECT_DIR:-.}"
SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null)
INTERVIEW_ID="interview-$(date +%Y%m%d-%H%M%S)"
DI_DIR="/tmp/doey/${PROJECT}/${INTERVIEW_ID}"
BRIEF_FILE="${DI_DIR}/brief.md"
mkdir -p "${DI_DIR}/research"
echo "Interview ID: ${INTERVIEW_ID}"
echo "Working directory: ${DI_DIR}"
```

Write the goal file — the Interviewer discovers the goal from this:

```bash
cat > "${DI_DIR}/goal.md" << 'GOAL_EOF'
<INSERT THE GOAL FROM ARGUMENTS HERE — the full text the user provided>
GOAL_EOF
echo "Goal written to ${DI_DIR}/goal.md"
```

Write the interview environment file:

```bash
DOEY_TASK_ID=$(doey task create --title "Deep Interview: $(head -1 "${DI_DIR}/goal.md")" --type feature --description "Structured clarification interview before dispatch" 2>/dev/null) || true
echo "Task ID: ${DOEY_TASK_ID:-none}"

cat > "${DI_DIR}/interview.env" << ENV_EOF
INTERVIEW_ID=${INTERVIEW_ID}
DI_DIR=${DI_DIR}
BRIEF_FILE=${BRIEF_FILE}
GOAL_FILE=${DI_DIR}/goal.md
RESEARCH_DIR=${DI_DIR}/research
PROJECT_DIR=${PROJECT_DIR}
DOEY_TASK_ID=${DOEY_TASK_ID:-}
ENV_EOF
echo "Interview env written to ${DI_DIR}/interview.env"
```

Initialize the brief file so the Brief pane has something to render immediately:

```bash
cat > "${BRIEF_FILE}" << 'BRIEF_INIT'
# Deep Interview Brief

_Interview in progress..._

**Intent:** _(pending)_

**Scope:** _(pending)_

**Non-Goals:** _(pending)_

**Success Criteria:** _(pending)_

**Verbatim Goal:** _(pending)_

**Ready for dispatch:** No — interview not started
BRIEF_INIT
```

### Step 3: Spawn the Interview Window (3-pane layout)

Create a purpose-built window with this layout:

```
┌──────────────────┬──────────────┐
│                  │  Researcher  │
│   Interviewer    ├──────────────┤
│  (Masterplanner) │    Brief     │
└──────────────────┴──────────────┘
```

- **Pane 0 (left, 60%)** — Interviewer: Masterplanner persona, drives the conversation
- **Pane 1 (top-right)** — Researcher: Looks up codebase context on demand
- **Pane 2 (bottom-right)** — Brief: Live file watcher rendering the brief as it's updated

```bash
tmux new-window -t "$SESSION_NAME" -n "interview" -c "$PROJECT_DIR"; sleep 0.5
NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')
tmux split-window -h -t "$SESSION_NAME:$NEW_WIN.0" -p 40 -c "$PROJECT_DIR"; sleep 0.1
tmux split-window -v -t "$SESSION_NAME:$NEW_WIN.1" -p 50 -c "$PROJECT_DIR"; sleep 0.3
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.0" -T "Interviewer"
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.1" -T "Researcher"
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.2" -T "Brief"
echo "Interview window: ${NEW_WIN}"
```

### Step 4: Write Team Env + Update TEAM_WINDOWS

```bash
cat > "${RD}/team_${NEW_WIN}.env.tmp" << TEAM_EOF
SESSION_NAME=${SESSION_NAME}
PROJECT_DIR=${PROJECT_DIR}
PROJECT_NAME=${PROJECT}
WINDOW_INDEX=${NEW_WIN}
GRID=dynamic
TOTAL_PANES=3
MANAGER_PANE=0
WORKER_PANES=1
WORKER_COUNT=1
WORKTREE_DIR=
WORKTREE_BRANCH=
INTERVIEW_TEAM=true
INTERVIEW_ID=${INTERVIEW_ID}
TEAM_EOF
mv "${RD}/team_${NEW_WIN}.env.tmp" "${RD}/team_${NEW_WIN}.env"

CUR=$(grep '^TEAM_WINDOWS=' "${RD}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
[ -n "$CUR" ] && NW="${CUR},${NEW_WIN}" || NW="${NEW_WIN}"
TMPENV=$(mktemp "${RD}/session.env.tmp_XXXXXX")
if grep -q '^TEAM_WINDOWS=' "${RD}/session.env"; then
  sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NW}/" "${RD}/session.env" > "$TMPENV"
else
  cat "${RD}/session.env" > "$TMPENV"; echo "TEAM_WINDOWS=${NW}" >> "$TMPENV"
fi
mv "$TMPENV" "${RD}/session.env"
```

### Step 5: Write Interviewer System Prompt

This is the Masterplanner persona — assertive, demanding, pushes back on vagueness:

```bash
cat > "${DI_DIR}/interviewer-prompt.md" << 'INTERVIEWER_EOF'
# Masterplanner Interviewer

You are the Masterplanner — an assertive, senior technical interviewer who extracts crystal-clear requirements before any work begins. You are the last line of defense against wasted effort.

## Your Personality

You are direct, demanding, and allergic to vagueness. You do NOT accept:
- "Make it better" — Better HOW? Faster? More reliable? Easier to use?
- "Fix the tests" — Which tests? What's failing? What's the expected behavior?
- "Improve performance" — Which operation? What's the current latency? What's the target?
- "Clean up the code" — Which module? What's wrong with it? What does "clean" mean to you?

When you get a vague answer, you push back HARD:
- "That scope is too broad — which specific module are you actually changing?"
- "You said 'it should work better' — give me a number. What's acceptable?"
- "Those aren't success criteria, those are wishes. How would a machine verify this is done?"
- "You listed 8 areas to touch. In my experience, that means you haven't decided what matters most. Pick three."

You are not rude — you are rigorous. You save the team from building the wrong thing.

## Interview Protocol

You drive a 4-phase interview. Use AskUserQuestion for EVERY question.

### Phase 1: Intent
Ask: "What is the specific outcome you want? Describe the end state — what should be true when this is done?"

If vague, push back: "That's too abstract. Give me one concrete thing a user would see or a developer would measure."

Do NOT proceed until you have a concrete, falsifiable intent statement.

### Phase 2: Scope
Ask: "What areas of the codebase does this touch? Files, directories, modules, APIs — be specific, or say 'not sure' and I'll have my Researcher look it up."

If user says "not sure":
- Dispatch the Researcher (pane 1) to investigate:
  ```bash
  source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true
  doey_send_verified "${SESSION_NAME}:${DOEY_TEAM_WINDOW}.1" \
    "Research scope for: <GOAL>. Search the codebase for relevant files, modules, and dependencies. Write findings to ${RESEARCH_DIR}/scope.md. Be thorough — list every file that would likely need changes."
  ```
- Wait for the report, then present findings to the user and confirm scope.

If scope is too broad (5+ areas), push back: "That's a lot of surface area. Which of these is the core change vs. follow-on work?"

### Phase 3: Non-Goals
Ask: "What should this work NOT do? What areas should the team leave alone? What behaviors must be preserved?"

If user says "nothing" or gives a non-answer, probe: "Every project has boundaries. Is there a public API contract to preserve? Existing tests that must keep passing? A module someone else is working on?"

### Phase 4: Success Criteria
Ask: "How will you verify this is done correctly? Give me specific, testable criteria — not 'it works' but 'endpoint returns 200 with payload X in under 100ms.'"

If vague, push back: "Those aren't verifiable. If I handed this to a QA engineer, could they check every one of these? Rewrite them as pass/fail checks."

## Brief Management

After EACH phase, update the brief file at `${BRIEF_FILE}` using the Write tool. The Brief pane (pane 2) renders this file in real time.

The final brief format:

```markdown
# Deep Interview Brief

**Interview ID:** <INTERVIEW_ID>
**Task ID:** <DOEY_TASK_ID>
**Date:** <ISO 8601>

## Intent
<one-paragraph summary of what the user wants, in concrete terms>

## Scope
- <file/area 1> — <why it needs to change>
- <file/area 2> — <why it needs to change>
- (or "TBD — Researcher investigating")

## Non-Goals
- <boundary 1> — <what to preserve and why>
- <boundary 2>
- (or "None specified — user confirmed no boundaries")

## Success Criteria
- [ ] <testable criterion 1>
- [ ] <testable criterion 2>

## Research Findings
<summary of anything the Researcher discovered, if applicable>

## Verbatim Goal
> <user's original words, unmodified>

## Dispatch Recommendation
- **Type:** <feature|bugfix|refactor|research|audit|docs|infrastructure>
- **Priority:** <P0|P1|P2|P3>
- **Workers needed:** <N>
- **Dispatch mode:** <parallel|sequential>

**Ready for dispatch:** Yes / No (if No, state what's missing)
```

## Completion

When all four phases are complete and the brief is finalized:

1. Use AskUserQuestion to present the brief summary and ask: "Brief is ready. Shall I send this to the Taskmaster for execution? (Yes / Modify / Cancel)"

2. If **Yes** — send the brief to Boss/Taskmaster:
   ```bash
   TASKMASTER_PANE=$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)
   TASKMASTER_PANE="${TASKMASTER_PANE:-1.0}"

   doey task update --id "$DOEY_TASK_ID" --field "description" --value "$(cat "${BRIEF_FILE}")" 2>/dev/null || true
   doey task update --id "$DOEY_TASK_ID" --field "status" --value "ready" 2>/dev/null || true

   doey msg send --to "${SESSION_NAME}:${TASKMASTER_PANE}" --from "${DOEY_PANE_ID}" \
     --subject "interview_complete" \
     --body "TASK_ID=${DOEY_TASK_ID}
   INTERVIEW_ID=${INTERVIEW_ID}
   BRIEF_FILE=${BRIEF_FILE}
   Deep interview complete. Brief ready for dispatch at ${BRIEF_FILE}."
   doey msg trigger --pane "${SESSION_NAME}:${TASKMASTER_PANE}"
   ```

3. If **Modify** — ask which section, update, re-present.
4. If **Cancel** — acknowledge and stop.

## Rules
- Use AskUserQuestion for EVERY question — never inline
- Push back on vague answers — you are the quality gate
- Update the brief file after EACH phase so the Brief pane stays current
- Use the Researcher for codebase lookups — do NOT read source code yourself
- The brief must be self-contained — the Taskmaster dispatches from it without further clarification
- If the goal is already crystal clear, say so and offer to skip straight to dispatch
INTERVIEWER_EOF
echo "Interviewer prompt written"
```

### Step 6: Launch Brief Watcher (Pane 2)

The Brief pane runs a file watcher that re-renders the brief file on every change:

```bash
source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true
BRIEF_WATCH_CMD="echo '--- Deep Interview Brief ---'; echo ''; cat '${BRIEF_FILE}' 2>/dev/null || echo '(waiting for interview to begin...)'; echo ''; echo '--- watching for updates (every 3s) ---'; while true; do sleep 3; clear; echo '--- Deep Interview Brief ---'; echo ''; cat '${BRIEF_FILE}' 2>/dev/null || echo '(waiting...)'; echo ''; echo '--- last updated: '\"\\$(date +%H:%M:%S)\"' ---'; done"
doey_send_command "${SESSION_NAME}:${NEW_WIN}.2" "bash -c '${BRIEF_WATCH_CMD}'"
```

### Step 7: Launch Claude Instances (3s stagger)

```bash
DI_PROMPT="${DI_DIR}/interviewer-prompt.md"

# Pane 0: Interviewer (Masterplanner) — opus model for depth
doey_send_command "${SESSION_NAME}:${NEW_WIN}.0" \
  "claude --dangerously-skip-permissions --model opus --name \"Interviewer\""; sleep 3

# Pane 1: Researcher — sonnet for fast codebase lookups
doey_send_command "${SESSION_NAME}:${NEW_WIN}.1" \
  "claude --dangerously-skip-permissions --model sonnet --name \"Researcher\""
```

### Step 8: Brief the Interviewer

Wait for the Interviewer to boot, then send the goal and context:

```bash
sleep 10
INTERVIEWER_PANE="${SESSION_NAME}:${NEW_WIN}.0"

BRIEFING="You are the Masterplanner Interviewer for interview ${INTERVIEW_ID}.

$(cat "${DI_DIR}/interviewer-prompt.md")

## Context
- Interview ID: ${INTERVIEW_ID}
- Goal file: ${DI_DIR}/goal.md
- Brief file: ${BRIEF_FILE}
- Research directory: ${DI_DIR}/research/
- Researcher pane: ${SESSION_NAME}:${NEW_WIN}.1
- Task ID: ${DOEY_TASK_ID:-none}

## Goal
$(cat "${DI_DIR}/goal.md")

Read the goal and begin the interview. Start with Phase 1 (Intent). Update the brief file after each phase. Use the Researcher (pane 1) when you need codebase context. The Brief pane (pane 2) auto-renders your updates.

BEGIN THE INTERVIEW NOW."

doey_send_verified "$INTERVIEWER_PANE" "$BRIEFING" && echo "Interviewer briefed successfully" || echo "WARNING: Interviewer briefing delivery failed — will discover goal from ${DI_DIR}/goal.md"
```

### Step 9: Notify Taskmaster

```bash
TASKMASTER_PANE=$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)
TASKMASTER_PANE="${TASKMASTER_PANE:-1.0}"

doey msg send --to "${SESSION_NAME}:${TASKMASTER_PANE}" --from "${DOEY_PANE_ID}" \
  --subject "interview_spawned" \
  --body "INTERVIEW_ID: ${INTERVIEW_ID}
BRIEF_FILE: ${BRIEF_FILE}
TASK_ID: ${DOEY_TASK_ID:-}
WINDOW: ${NEW_WIN}

Deep Interview '${INTERVIEW_ID}' spawned in window ${NEW_WIN}.
Masterplanner is interviewing the user. Brief will be dispatched on completion.
Goal: $(head -5 "${DI_DIR}/goal.md")"
doey msg trigger --pane "${SESSION_NAME}:${TASKMASTER_PANE}"
echo "Taskmaster notified"
```

### Step 10: Report

Output the final summary:

```
## Deep Interview Spawned

**Interview ID:** ${INTERVIEW_ID}
**Task ID:** ${DOEY_TASK_ID:-none}
**Window:** ${NEW_WIN} (interview)
**Goal file:** ${DI_DIR}/goal.md
**Brief file:** ${BRIEF_FILE}

The Masterplanner interview team is now running in window ${NEW_WIN}:
- **Pane 0** — Interviewer (Masterplanner — drives the conversation)
- **Pane 1** — Researcher (codebase lookups on demand)
- **Pane 2** — Brief (live display — updates as interview progresses)

Switch to window ${NEW_WIN} to begin the interview. The Masterplanner will ask structured questions about intent, scope, non-goals, and success criteria. When the interview is complete, the brief will be dispatched to the Taskmaster automatically.

Teardown: `/doey-kill-window ${NEW_WIN}`
```

### Rules
- Always use AskUserQuestion for user interaction — never inline questions
- The skill is a launcher — all interview logic lives in the Interviewer's system prompt
- Use absolute paths only
- If window creation fails, report the error and stop
- Do NOT run the interview inline — spawn the window and let the Masterplanner take over
- The goal file at `${DI_DIR}/goal.md` is the handoff mechanism
- The brief file at `${BRIEF_FILE}` is the integration point between Interviewer and Brief pane
- Works from any caller context (Boss, Taskmaster, or any agent)
