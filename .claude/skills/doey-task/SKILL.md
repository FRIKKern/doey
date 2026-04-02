---
name: doey-task
description: Manage persistent project tasks — list, add, transition, show, subtasks, decisions, notes. Tasks stored in .doey/tasks/ (survives reboot). Use when you need to "show tasks", "add a task", "mark a task done", "what are we working on", or "create a task".
---

- Active tasks: !`doey-ctl task list --json 2>/dev/null || echo "(none)"`

Persistent task management via `doey-ctl`.

### Schema v3

```
TASK_ID=<int>  TASK_TITLE=<text>  TASK_TYPE=<bug|feature|bugfix|refactor|research|audit|docs|infrastructure>
TASK_STATUS=<draft|active|in_progress|paused|blocked|pending_user_confirmation|done|cancelled>
TASK_TAGS=<comma-sep>  TASK_CREATED_BY  TASK_ASSIGNED_TO  TASK_BLOCKERS
TASK_DESCRIPTION=<\n-delimited>  TASK_ACCEPTANCE_CRITERIA  TASK_HYPOTHESES="1. [HIGH] Text\n..."
TASK_DECISION_LOG="epoch:text\n..."  TASK_SUBTASKS="idx:title:status\n..."  TASK_NOTES
TASK_RELATED_FILES=<pipe-delimited>  TASK_TIMESTAMPS=<pipe-delimited event=epoch>
TASK_BLOCKS=<comma-sep task IDs>  TASK_BLOCKED_BY=<comma-sep task IDs>
TASK_PLAN_PHASE=<gathering|drafted|approved|executing|reviewing|done>
TASK_TODOLIST=<\n-delimited "id:status:text" entries>
```

**Lifecycle:** `draft` → `active` → `in_progress` → `paused`/`blocked` → `pending_user_confirmation` → `done`/`cancelled`

**Plan phases** (orthogonal to status): `gathering` → `drafted` → `approved` → `executing` → `reviewing` → `done`
Plan phase is optional — not all tasks need one. Only change phase when explicitly requested.

### Operations

```bash
# List (--status in_progress | --json)
doey-ctl task list
doey-ctl task list --status in_progress
doey-ctl task list --json

# Create
TASK_ID=$(doey-ctl task create --title "TITLE" --type "feature" --description "DESCRIPTION")

# Get task details
doey-ctl task get --id "$TASK_ID"

# Transition: start/pause/block/confirm/done/cancel
doey-ctl task update --id "$TASK_ID" --status "in_progress"

# Update any field
doey-ctl task update --id "$TASK_ID" --field "TASK_DESCRIPTION" --value "New value"

# Subtasks
doey-ctl task subtask add --task-id "$TASK_ID" --description "Title"
doey-ctl task subtask update --task-id "$TASK_ID" --subtask-id "1" --status "done"  # pending|in_progress|done|skipped
doey-ctl task subtask list --task-id "$TASK_ID"

# Decision log / Notes / Related files
doey-ctl task decision --task-id "$TASK_ID" --title "Decision title" --body "Decision text"
doey-ctl task log add --task-id "$TASK_ID" --type "note" --title "Note title" --body "Note text"
doey-ctl task update --id "$TASK_ID" --field "TASK_RELATED_FILES" --value "path/to/file.sh|path/to/other.sh"
```

### Dependencies

`TASK_BLOCKS` and `TASK_BLOCKED_BY` are comma-separated task ID lists. They are **bidirectionally synced**:

```bash
# Set "task A blocks tasks B and C" (auto-syncs BLOCKED_BY on B and C)
doey-ctl task update --id "A" --field "TASK_BLOCKS" --value "B,C"

# Check if a task is blocked
doey-ctl task get --id "$TASK_ID"  # inspect TASK_BLOCKED_BY and TASK_PLAN_PHASE
```

- Setting `blocks` on task A with value `B,C` automatically adds A to `blockedBy` on tasks B and C
- When a task transitions to `done`, dependents are automatically unblocked
- **Dispatch guard:** A task with non-empty `TASK_BLOCKED_BY` must NOT be dispatched — print warning: `"Task ID is blocked by: X, Y"`
- **Circular dep warning:** Before setting blocks, walk the chain. If circular, warn but still allow: `"Warning: circular dependency detected between task A and task B"`
- **Missing ref warning:** If a referenced task ID doesn't exist, warn: `"Warning: task ID not found"` — don't error

**When transitioning a task to `done`:**
```bash
doey-ctl task update --id "$TASK_ID" --status "done"
```

### Plan Phases

`TASK_PLAN_PHASE` is optional and orthogonal to `TASK_STATUS`. Allowed values: `gathering`, `drafted`, `approved`, `executing`, `reviewing`, `done`.

```bash
doey-ctl task update --id "$TASK_ID" --field "TASK_PLAN_PHASE" --value "approved"
```

**Dispatch guard:** Tasks in `gathering` or `drafted` phase should NOT be dispatched for implementation.

### TodoList

`TASK_TODOLIST` is a `\n`-delimited checklist of `id:status:text` entries attached to a task. Status values: `pending`, `in_progress`, `done`. IDs are simple incrementing integers within the task.

Example value: `1:pending:Read the coordinator source\n2:in_progress:Adapt prompt patterns\n3:done:Write tests`

#### TodoList Operations

```bash
# Read current todolist
doey-ctl task get --id "$TASK_ID"  # inspect TASK_TODOLIST field

# Add a pending item (append to existing value with new auto-incremented ID)
doey-ctl task update --id "$TASK_ID" --field "TASK_TODOLIST" \
  --value "1:pending:Read source\n2:pending:New item"

# Update item status (rewrite full value with updated status)
doey-ctl task update --id "$TASK_ID" --field "TASK_TODOLIST" \
  --value "1:done:Read source\n2:in_progress:New item"
```

#### TodoList Usage Patterns

- **Workers** should update checklist items as they work — mark `in_progress` when starting an item, `done` when complete
- **Taskmaster/Subtaskmaster** can monitor todo progress to gauge completion percentage
- **TodoList is the plan made concrete** — each item is a verifiable step toward task completion
- **Progress percentage:** `done_count / total_count * 100`
- Tasks without a todoList work unchanged — the field is optional and all existing behavior is preserved

### Listing Enhancements

When listing tasks (`doey-ctl task list --json`), the output includes dependency and phase info:

- **Blocked tasks:** `TASK_BLOCKED_BY` field shows blocking task IDs
- **Plan phase:** `TASK_PLAN_PHASE` shown when set
- **Ready indicator:** tasks with no blockers AND phase is approved/executing/unset are ready to dispatch

### Encoding
Multiline: `\n` literal. Files: pipe-delimited. Tags: comma-separated. Subtask: `idx:title:status`. Decisions: `epoch:text`. Dependencies: comma-separated task IDs. TodoList: `id:status:text` (`\n`-delimited, status=`pending`|`in_progress`|`done`).
