---
name: doey-create-task
description: Compile a natural-language goal into a structured task package (.task + .json). Usage: /doey-create-task <goal>
---

## Context

- Current tasks: !`bash -c 'RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); source "$RUNTIME_DIR/../doey/shell/doey-task-helpers.sh" 2>/dev/null && task_list "$RUNTIME_DIR" 2>/dev/null || echo "No tasks"'`
- Helpers path: !`echo "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/../doey/shell/doey-task-helpers.sh"`

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
◆ DISPATCH PLAN: [team assignment, wave structure]
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
TD="${RUNTIME_DIR}/tasks"
python3 -c "
import json
with open('${TD}/${TASK_ID}.json', 'r') as f:
    data = json.load(f)
data['intent'] = 'INTENT_HERE'
data['hypotheses'] = ['H1: ...', 'H2: ...']
data['constraints'] = ['constraint1', 'constraint2']
data['success_criteria'] = ['criterion1', 'criterion2']
data['deliverables'] = ['deliverable1', 'deliverable2']
data['dispatch_plan'] = {'teams': [], 'waves': []}
with open('${TD}/${TASK_ID}.json', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
```

If python3 is not available, use printf to write the JSON directly.

Replace all placeholder values above with actual compiled content from Step 2.

### Step 4: Output Summary

Display in open-layout format (◆ sections, • items, → implications, ↳ sub-steps). Include: task ID, title, type, intent, hypotheses, dispatch plan, file paths.

## Rules

- Always use `task_create` from `doey-task-helpers.sh` — never duplicate logic
- `/doey-task add` for simple tasks; this skill for structured compilation only
- No border characters (│, ║, ┃). One clarifying question max if ambiguous
- Always show triviality classification before proceeding
