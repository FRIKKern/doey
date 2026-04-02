---
name: doey-instant-task
description: Quick task creation without planning — create and dispatch immediately. Usage: /doey-instant-task <goal>
---

- Current tasks: !`bash -c 'source /home/doey/doey/shell/doey-task-helpers.sh 2>/dev/null && task_list "$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d \")" 2>/dev/null || echo "No tasks"'`
- Tasks dir: !`bash -c 'PD=$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); if [ -n "$PD" ] && [ -d "$PD/.doey/tasks" ]; then echo "$PD/.doey/tasks"; else echo "No tasks dir"; fi'`

Create and dispatch a task immediately from a natural-language goal. No planning step. Goal from ARGUMENTS (if empty, use AskUserQuestion to ask, then stop).

For complex multi-step work, suggest `/doey-planned-task` instead.

### 1. Classify

Determine type and priority from the goal:
- **Type**: feature, bugfix, refactor, research, audit, docs, infrastructure
- **Priority**: P0 (critical), P1 (high), P2 (normal), P3 (low)

Infer from keywords: "fix"/"bug"/"broken" → bugfix, "add"/"new"/"create" → feature, "clean"/"simplify" → refactor, "investigate"/"explore" → research.

### 2. Create Task

```bash
PD=$(grep '^PROJECT_DIR=' "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
source "${PD}/shell/doey-task-helpers.sh" 2>/dev/null || source /home/doey/doey/shell/doey-task-helpers.sh
TASK_ID=$(task_create "$PD" "TITLE" "TYPE" "Boss" "DESCRIPTION")
echo "Created task #${TASK_ID}"
```

For tasks with obvious sub-parts, add subtasks:
```bash
task_subtask_add "$PD" "$TASK_ID" "Subtask title"
```

### 3. Dispatch to Session Manager

Send message to SM for routing:
```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION_NAME=$(grep '^SESSION_NAME=' "$RD/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
SM_SAFE=$(printf '%s' "${SESSION_NAME}:0.2" | tr ':.-' '_')
mkdir -p "${RD}/messages" "${RD}/triggers"
printf 'FROM: Boss\nSUBJECT: new_task\nTASK_ID: %s\nTITLE: %s\nTYPE: %s\nPRIORITY: %s\nInstant task — ready for immediate dispatch.\n' \
  "$TASK_ID" "$TASK_TITLE" "${TASK_TYPE:-feature}" "${TASK_PRIORITY:-P2}" \
  > "${RD}/messages/${SM_SAFE}_$(date +%s)_$$.msg"
touch "${RD}/triggers/${SM_SAFE}.trigger" 2>/dev/null || true
```

### 4. Output

Report: task ID, title, type, priority, dispatch status. Keep it brief — this is the fast path.

### Rules
- Use AskUserQuestion if goal is empty — never inline questions
- Use `task_create` from helpers — never duplicate
- No planning, no approval gate — create and dispatch immediately
- If goal looks complex (multiple independent tracks, high risk, cross-team), suggest `/doey-planned-task` instead
- Zero clarifying questions for obvious goals; one max for ambiguous ones
