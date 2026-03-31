---
name: doey-task
description: Manage persistent project tasks — list, add, transition, show, subtasks, decisions, notes. Tasks stored in .doey/tasks/ (survives reboot). Use when you need to "show tasks", "add a task", "mark a task done", "what are we working on", or "create a task".
---

- Active tasks: !`TD="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.doey/tasks"; for f in "$TD"/*.task; do [ -f "$f" ] && ! grep -q "^TASK_STATUS=done\|^TASK_STATUS=cancelled" "$f" && cat "$f" && echo "---"; done 2>/dev/null || echo "(none)"`

Tasks stored in `.doey/tasks/N.task` — persistent, project-local, survives reboot.

## Library

Source the task helpers library before any task operation:
```bash
HELPERS="${PROJECT_DIR}/shell/doey-task-helpers.sh"
[ -f "$HELPERS" ] && source "$HELPERS"
```
This provides all `task_*` functions. Use them instead of inline bash.

### Schema v3

```
TASK_SCHEMA_VERSION=3
TASK_ID=<integer>
TASK_TITLE=<text>
TASK_STATUS=<draft|active|in_progress|paused|blocked|pending_user_confirmation|done|cancelled>
TASK_TYPE=<bug|feature|bugfix|refactor|research|audit|docs|infrastructure>
TASK_TAGS=<comma-separated>
TASK_CREATED_BY=<who created it>
TASK_ASSIGNED_TO=<who/what team>
TASK_DESCRIPTION=<multiline via literal \n>
TASK_ACCEPTANCE_CRITERIA=<multiline via literal \n — bulleted>
TASK_HYPOTHESES=<multiline — "1. [HIGH] Text\n2. [MED] Text">
TASK_DECISION_LOG=<multiline — "epoch:Decision text\nepoch:Another">
TASK_SUBTASKS=<multiline — "1:Title:pending\n2:Title:done" — status: pending|in_progress|done|skipped>
TASK_RELATED_FILES=<pipe-delimited paths>
TASK_BLOCKERS=<text>
TASK_TIMESTAMPS=<pipe-delimited event=epoch pairs — "created=epoch|started=epoch">
TASK_NOTES=<multiline via literal \n — free-form journal>
```

**Lifecycle:** `draft` → `active` → `in_progress` → `paused`/`blocked` → `pending_user_confirmation` → `done` | `cancelled`

### List

```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
task_list "$PROJECT_DIR"
# Filter by status:  task_list "$PROJECT_DIR" --status in_progress
# Include done/cancelled:  task_list "$PROJECT_DIR" --all
```

### Add

```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
ID=$(task_create "$PROJECT_DIR" "TITLE" "feature" "CREATOR" "DESCRIPTION")
echo "Created task #${ID}"
```

### Transition

`start <id>` → in_progress | `pause <id>` → paused | `block <id>` → blocked | `confirm <id>` → pending_user_confirmation | `done/cancel <id>` → terminal

```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
task_update_status "$PROJECT_DIR" "ID_HERE" "in_progress"
```

### Update field

```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
TD="$(task_dir "$PROJECT_DIR")"
task_update_field "${TD}/ID_HERE.task" "TASK_DESCRIPTION" "New value"
```

### Show

```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
TD="$(task_dir "$PROJECT_DIR")"
FILE="${TD}/ID_HERE.task"
[ ! -f "$FILE" ] && echo "Task not found" && exit 1
task_read "$FILE"
echo "ID: $TASK_ID"
echo "Title: $TASK_TITLE"
echo "Status: $TASK_STATUS"
echo "Type: $TASK_TYPE"
[ -n "$TASK_TAGS" ] && echo "Tags: $TASK_TAGS"
[ -n "$TASK_CREATED_BY" ] && echo "Created by: $TASK_CREATED_BY"
[ -n "$TASK_ASSIGNED_TO" ] && echo "Assigned to: $TASK_ASSIGNED_TO"
[ -n "$TASK_DESCRIPTION" ] && printf 'Description:\n  %s\n' "$(echo "$TASK_DESCRIPTION" | sed 's/\\n/\n  /g')"
[ -n "$TASK_ACCEPTANCE_CRITERIA" ] && printf 'Acceptance Criteria:\n  %s\n' "$(echo "$TASK_ACCEPTANCE_CRITERIA" | sed 's/\\n/\n  /g')"
[ -n "$TASK_HYPOTHESES" ] && printf 'Hypotheses:\n  %s\n' "$(echo "$TASK_HYPOTHESES" | sed 's/\\n/\n  /g')"
[ -n "$TASK_DECISION_LOG" ] && printf 'Decisions:\n  %s\n' "$(echo "$TASK_DECISION_LOG" | sed 's/\\n/\n  /g')"
[ -n "$TASK_SUBTASKS" ] && printf 'Subtasks:\n  %s\n' "$(echo "$TASK_SUBTASKS" | sed 's/\\n/\n  /g')"
[ -n "$TASK_RELATED_FILES" ] && echo "Files: $(echo "$TASK_RELATED_FILES" | sed 's/|/, /g')"
[ -n "$TASK_BLOCKERS" ] && echo "Blockers: $TASK_BLOCKERS"
echo "Timestamps: $(echo "$TASK_TIMESTAMPS" | sed 's/|/, /g')"
[ -n "$TASK_NOTES" ] && printf 'Notes:\n  %s\n' "$(echo "$TASK_NOTES" | sed 's/\\n/\n  /g')"
```

### Subtask management

```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
TD="$(task_dir "$PROJECT_DIR")"
# Add subtask:
task_add_subtask "${TD}/ID_HERE.task" "Subtask title"
# Update subtask status (valid: pending, in_progress, done, skipped):
task_update_subtask "${TD}/ID_HERE.task" "1" "done"
```

### Decision log

```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
TD="$(task_dir "$PROJECT_DIR")"
task_add_decision "${TD}/ID_HERE.task" "Decision text here"
```

### Notes

```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
TD="$(task_dir "$PROJECT_DIR")"
task_add_note "${TD}/ID_HERE.task" "New note text here"
```

### Related files

```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
TD="$(task_dir "$PROJECT_DIR")"
task_add_related_file "${TD}/ID_HERE.task" "path/to/file.sh"
```

### Rules
- Persistent in `.doey/tasks/`. Multiline: `\n` literal. Files: pipe-delimited. Tags: comma-separated
- Subtask: `index:title:status`. Decisions: `epoch:text`. Status transitions append to TASK_TIMESTAMPS
- All writes atomic (tmp+mv via library)
