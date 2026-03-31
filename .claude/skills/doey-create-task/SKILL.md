---
name: doey-create-task
description: Compile a natural-language goal into a structured task package (.task + .json). Usage: /doey-create-task <goal>
---

## Context

- Current tasks: !`bash -c 'RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); source "$RUNTIME_DIR/../doey/shell/doey-task-helpers.sh" 2>/dev/null && task_list "$RUNTIME_DIR" 2>/dev/null || echo "No tasks"'`
- Helpers path: !`echo "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/../doey/shell/doey-task-helpers.sh"`
- Tasks dir: !`bash -c 'RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); PD=$(grep "^PROJECT_DIR=" "$RUNTIME_DIR/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); if [ -n "$PD" ] && [ -d "$PD/.doey/tasks" ]; then echo "$PD/.doey/tasks"; else echo "$RUNTIME_DIR/tasks"; fi'`

## Prompt

Compile a natural-language goal into a structured task package. The goal is provided in ARGUMENTS. If no argument was provided, ask the user what their goal is and stop.

### Step 1: Triviality Check

Classify the goal into one of three categories and state the classification before proceeding:

- **TRIVIAL** — A direct question or lookup. Tell the user: "This is a direct question — no task needed." Then answer it directly. Stop here.
- **SIMPLE OPERATIONAL** — A straightforward action (e.g., "restart workers", "check status"). Use `/doey-task add "title"` instead. Stop here.
- **STRUCTURED** — A multi-step goal requiring planning, coordination, or multiple deliverables. Continue to Step 2.

### Step 2: Compile Task Package

Analyze the goal and compile a structured task specification:

```
◆ TASK TYPE: [feature|bugfix|refactor|research|audit|docs|infrastructure]
◆ INTENT: [what + why]
◆ CONCEPTS: [key domain and technical concepts]
◆ BRIDGE PROBLEM: [current state → desired state gap]
◆ REPRESENTATION: [how the solution should be structured]
◆ HYPOTHESES:
  • H1: [approach] — confidence: HIGH/MEDIUM/LOW
  • H2: [alternative] — confidence: HIGH/MEDIUM/LOW
◆ CONSTRAINTS: [limits and requirements]
◆ SUCCESS CRITERIA: [measurable done-definition]
◆ EVIDENCE PLAN: [how to validate]
◆ DELIVERABLES: [concrete outputs]
◆ DISPATCH MODE: [standard|phased]
◆ DISPATCH PLAN: [team assignment, wave structure, phases if applicable]
```

**Phase Detection:** Before finalizing, check if the goal is phased. Suggest `DISPATCH MODE: phased` if ANY of these apply:
- Goal explicitly mentions "Phase 1", "Phase 2", etc.
- Goal has sequential dependencies ("first X, then Y", "after that", "once X is done")
- User says "phased", "multi-phase", or "staged"

If phased is detected, tell the user: "This looks like a phased task (N phases detected). Creating as phased — let me know if you'd prefer standard." Then structure the DISPATCH PLAN with numbered phases:
```
◆ DISPATCH PLAN:
  Phase 1: [title] — [brief]
  Phase 2: [title] — [brief]
  ...
```

### Step 3: Create Task Artifacts

Source the helpers and create both the .task and .json files:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/../doey/shell/doey-task-helpers.sh" 2>/dev/null || source /home/doey/doey/shell/doey-task-helpers.sh

TASK_ID=$(task_create "$RUNTIME_DIR" \
  "TITLE" \
  "TYPE" \
  "Boss" \
  "PRIORITY" \
  "ONE_LINE_SUMMARY" \
  "FULL_DESCRIPTION")

echo "Created task #${TASK_ID}"
```

Then update the companion .json with the compiled structured fields:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
PD=$(grep '^PROJECT_DIR=' "$RUNTIME_DIR/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
# Prefer persistent .doey/tasks/, fall back to runtime
if [ -n "$PD" ] && [ -d "$PD/.doey/tasks" ]; then
  TD="$PD/.doey/tasks"
else
  TD="${RUNTIME_DIR}/tasks"
fi
python3 -c "
import json
with open('${TD}/${TASK_ID}.json', 'r') as f:
    data = json.load(f)
data['intent'] = 'INTENT_HERE'
data['hypotheses'] = ['H1: ...', 'H2: ...']
data['constraints'] = ['constraint1', 'constraint2']
data['success_criteria'] = ['criterion1', 'criterion2']
data['deliverables'] = ['deliverable1', 'deliverable2']
data['dispatch_plan'] = {'mode': 'standard', 'teams': [], 'waves': []}
with open('${TD}/${TASK_ID}.json', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
```

Replace all placeholder values with actual compiled content from Step 2. If python3 is unavailable, use printf.

### Step 3b: Phased Task Runtime Setup (only if DISPATCH MODE is phased)

If the task is phased, perform two additional steps:

**1. Update the .task file with phase tracking fields:**

```bash
printf 'TASK_DISPATCH_MODE="phased"\n' >> "${TD}/${TASK_ID}.task"
printf 'TASK_CURRENT_PHASE=0\n' >> "${TD}/${TASK_ID}.task"
printf 'TASK_TOTAL_PHASES=%d\n' "$TOTAL_PHASES" >> "${TD}/${TASK_ID}.task"
task_update_field "${TD}/${TASK_ID}.task" "TASK_UPDATED" "$(date +%s)"
```

**2. Create the runtime phase file for SM auto-forwarding:**

```bash
mkdir -p "$RUNTIME_DIR/phases"
python3 -c "
import json
phases = [
    {'phase': 1, 'title': 'TITLE', 'brief': 'BRIEF', 'team_scope': 'any'},
    {'phase': 2, 'title': 'TITLE', 'brief': 'BRIEF', 'team_scope': 'any'}
]
data = {
    'task_id': '${TASK_ID}',
    'total_phases': len(phases),
    'current_phase': 0,
    'phases': phases
}
with open('${RUNTIME_DIR}/phases/task_${TASK_ID}.json', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
```

Replace the phases list with actual phases from Step 2. Skip this entire step for standard (non-phased) tasks.

### Step 4: Output Summary

Display in open-layout format (◆ sections, • items, → implications, ↳ sub-steps). Include: task ID, title, type, intent, hypotheses, dispatch plan, file paths. For phased tasks, also show: dispatch mode (phased), phase count, phase titles, and runtime phase file path.

## Rules

- Always use `task_create` from `doey-task-helpers.sh` — never duplicate logic
- `/doey-task add` for simple tasks; this skill for structured compilation only
- No border characters (│, ║, ┃). One clarifying question max if ambiguous
- Always show triviality classification before proceeding
