---
name: doey-planned-task
description: Plan-first task creation — research, breakdown, risk analysis, then create tasks from approved plan. Usage: /doey-planned-task <goal>
---

- Current tasks: !`bash -c 'source /home/doey/doey/shell/doey-task-helpers.sh 2>/dev/null && task_list "$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d \")" 2>/dev/null || echo "No tasks"'`
- Plans dir: !`bash -c 'PD=$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); echo "${PD:-.}/.doey/plans"'`
- Existing plans: !`bash -c 'PD=$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); ls "${PD:-.}/.doey/plans/"*.md 2>/dev/null | head -10 || echo "None"'`

Create a plan-first task from a natural-language goal. Goal from ARGUMENTS (if empty, use AskUserQuestion to ask, then stop).

### 1. Analyze Goal

Classify the goal:
- **TRIVIAL** — Direct question or lookup → answer directly, stop
- **SIMPLE** — Single obvious action → skip to `/doey-instant-task` instead
- **COMPLEX** — Multi-step, has risks, needs breakdown → continue with planning

### 2. Research & Breakdown

Before writing anything, research the goal:
1. Read relevant code files to understand current state
2. Identify what needs to change and where
3. Consider dependencies between changes
4. Identify risks and unknowns

Structure findings into a plan with:
- **Steps**: Ordered list of concrete actions with estimated complexity
- **Risks**: What could go wrong, mitigation strategies
- **Scope**: Files affected, teams needed, estimated worker count
- **Acceptance criteria**: How to verify the work is done correctly

### 3. Save Plan

Determine next plan ID:
```bash
PD=$(grep '^PROJECT_DIR=' "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
PLANS_DIR="${PD:-.}/.doey/plans"
mkdir -p "$PLANS_DIR"
PLAN_ID=$(( $(ls "$PLANS_DIR"/*.md 2>/dev/null | sed 's/.*\///' | grep -E '^[0-9]+\.md$' | sed 's/\.md//' | sort -n | tail -1) + 1 )) 2>/dev/null || PLAN_ID=1
echo "Next plan ID: $PLAN_ID"
```

Write the plan file using the Write tool to `${PLANS_DIR}/${PLAN_ID}.md`:

```markdown
---
plan_id: <PLAN_ID>
title: "<Plan Title>"
status: draft
created: <ISO 8601 timestamp>
updated: <ISO 8601 timestamp>
---

# <Plan Title>

## Goal
<Original goal from user>

## Steps
- [ ] Step 1: <description> (complexity: low/medium/high)
- [ ] Step 2: <description> (complexity: low/medium/high)
...

## Risks
- <Risk 1>: <mitigation>
- <Risk 2>: <mitigation>

## Scope
- **Files**: <list of files affected>
- **Teams**: <team assignment recommendation>
- **Workers**: <estimated count>

## Acceptance Criteria
- <criterion 1>
- <criterion 2>
```

### 4. Present Plan for Approval

Use AskUserQuestion to present the plan summary and ask the user to approve, modify, or reject:
- Show: title, step count, risks, scope estimate
- Options: "Approve and create tasks", "Modify plan", "Cancel"

If rejected or modified, iterate. Do NOT proceed to task creation without approval.

### 5. Create Tasks from Approved Plan

On approval, update plan status to `active`:
```bash
sed -i 's/^status: draft/status: active/' "${PLANS_DIR}/${PLAN_ID}.md"
```

Create task(s) using helpers:
```bash
PD=$(grep '^PROJECT_DIR=' "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
source "${PD}/shell/doey-task-helpers.sh" 2>/dev/null || source /home/doey/doey/shell/doey-task-helpers.sh
TASK_ID=$(task_create "$PD" "TITLE" "TYPE" "Boss" "DESCRIPTION")
echo "Created task #${TASK_ID}"
```

Link task to plan — append `TASK_PLAN_ID=<PLAN_ID>` to the .task file:
```bash
TD="${PD}/.doey/tasks"
echo "TASK_PLAN_ID=${PLAN_ID}" >> "${TD}/${TASK_ID}.task"
```

If the plan has multiple independent steps, create subtasks:
```bash
source "${PD}/shell/doey-task-helpers.sh" 2>/dev/null || source /home/doey/doey/shell/doey-task-helpers.sh
task_subtask_add "$PD" "$TASK_ID" "Subtask title"
```

Update the .json with plan metadata:
```bash
python3 -c "
import json, os
td = '${TD}'
with open(os.path.join(td, '${TASK_ID}.json'), 'r') as f: data = json.load(f)
data.update({
    'plan_id': ${PLAN_ID},
    'intent': '...',
    'success_criteria': [$(python3 -c "print(repr([c.strip() for c in '''CRITERIA_HERE'''.split(',')]))")],
    'dispatch_plan': {'mode': 'standard', 'teams': [], 'plan_ref': '${PLANS_DIR}/${PLAN_ID}.md'}
})
with open(os.path.join(td, '${TASK_ID}.json'), 'w') as f: json.dump(data, f, indent=2)
" 2>/dev/null || true
```

### 6. Dispatch to Session Manager

Send message to SM to pick up the new task:
```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION_NAME=$(grep '^SESSION_NAME=' "$RD/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
SM_SAFE=$(printf '%s' "${SESSION_NAME}:0.2" | tr ':.-' '_')
mkdir -p "${RD}/messages"
printf 'FROM: Boss\nSUBJECT: new_planned_task\nTASK_ID: %s\nPLAN_ID: %s\nTITLE: %s\nPRIORITY: %s\nPlanned task ready for dispatch. Plan: %s/%s.md\n' \
  "$TASK_ID" "$PLAN_ID" "$TASK_TITLE" "${TASK_PRIORITY:-P2}" "$PLANS_DIR" "$PLAN_ID" \
  > "${RD}/messages/${SM_SAFE}_$(date +%s)_$$.msg"
touch "${RD}/triggers/${SM_SAFE}.trigger" 2>/dev/null || true
```

### 7. Output

Report to user: task ID, plan ID, title, step count, dispatch status. Include paths to both plan and task files.

### Rules
- Always use AskUserQuestion for user interaction — never inline questions
- Use `task_create` from helpers — never duplicate the logic
- One clarifying question max before planning
- If goal is simple, redirect to `/doey-instant-task`
- Plan file must have valid YAML frontmatter with plan_id, title, status, created, updated
