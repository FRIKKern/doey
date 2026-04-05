---
name: doey-planned-task
description: Plan-first task creation — research, breakdown, risk analysis, then create tasks from approved plan. Usage: /doey-planned-task <goal>
---

- Current tasks: !`doey task list 2>/dev/null || echo "No tasks"`
- Existing plans: !`doey-ctl plan list 2>/dev/null || echo "None"`

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

### 3. Create the Task First

A plan requires an associated task. Create one:
```bash
TASK_ID=$(doey task create --title "TITLE" --type "TYPE" --description "DESCRIPTION")
echo "Created task #${TASK_ID}"
```

### 4. Save Plan via doey-ctl

Create the plan in SQLite using `doey-ctl plan create` with the task ID:

```bash
PLAN_BODY="# Plan Title

## Goal
<Original goal from user>

## Steps
- [ ] Step 1: <description> (complexity: low/medium/high)
- [ ] Step 2: <description> (complexity: low/medium/high)

## Risks
- <Risk 1>: <mitigation>

## Scope
- **Files**: <list of files affected>
- **Teams**: <team assignment recommendation>
- **Workers**: <estimated count>

## Acceptance Criteria
- <criterion 1>
- <criterion 2>"

PLAN_ID=$(doey-ctl plan create --task-id "$TASK_ID" --title "Plan Title" --body "$PLAN_BODY" | grep -oE '[0-9]+')
echo "Created plan #${PLAN_ID} linked to task #${TASK_ID}"
```

To update the plan status later:
```bash
doey-ctl plan update --status active "$PLAN_ID"
```

### 5. Present Plan for Approval

Use AskUserQuestion to present the plan summary and ask the user to approve, modify, or reject:
- Show: title, step count, risks, scope estimate
- Options: "Approve and dispatch", "Modify plan", "Cancel"

If rejected or modified, iterate. Do NOT proceed to dispatch without approval.

### 6. On Approval — Activate and Enrich Task

Update plan status to active:
```bash
doey-ctl plan update --status active "$PLAN_ID"
```

If the plan has multiple independent steps, create subtasks:
```bash
doey task subtask add --task-id "$TASK_ID" --description "Subtask title"
```

Update task with plan metadata:
```bash
doey task update --id "$TASK_ID" --field "intent" --value "..."
doey task update --id "$TASK_ID" --field "success_criteria" --value "criterion 1, criterion 2"
doey task update --id "$TASK_ID" --field "dispatch_plan" --value "standard"
```

### 7. Dispatch to Taskmaster

Send message to Taskmaster to pick up the new task:
```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
TASKMASTER_PANE=$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)
TASKMASTER_PANE="${TASKMASTER_PANE:-1.0}"
doey msg send --to "${SESSION_NAME}:${TASKMASTER_PANE}" --from "${DOEY_PANE_ID}" \
  --subject "new_planned_task" \
  --body "TASK_ID: ${TASK_ID}
PLAN_ID: ${PLAN_ID}
TITLE: ${TASK_TITLE}
PRIORITY: ${TASK_PRIORITY:-P2}
Planned task ready for dispatch."
doey msg trigger --pane "${SESSION_NAME}:${TASKMASTER_PANE}"
```

### 8. Output

Report to user: task ID, plan ID, title, step count, dispatch status.

### Rules
- Always use AskUserQuestion for user interaction — never inline questions
- Use `doey task create` for tasks — never duplicate the logic
- Use `doey-ctl plan create --task-id` for plans — never write plan .md files directly
- Every plan must have a `--task-id` — plans without tasks are not allowed
- One clarifying question max before planning
- If goal is simple, redirect to `/doey-instant-task`
