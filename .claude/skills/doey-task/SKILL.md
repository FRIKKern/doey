---
name: doey-task
description: Manage persistent project tasks — list, add, transition, show, subtasks, decisions, notes. Tasks stored in .doey/tasks/ (survives reboot). Use when you need to "show tasks", "add a task", "mark a task done", "what are we working on", or "create a task".
---

- Active tasks: !`TD="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.doey/tasks"; for f in "$TD"/*.task; do [ -f "$f" ] && ! grep -q "^TASK_STATUS=done\|^TASK_STATUS=cancelled" "$f" && cat "$f" && echo "---"; done 2>/dev/null || echo "(none)"`

Persistent in `.doey/tasks/N.task`. Source helpers first: `source "${PROJECT_DIR}/shell/doey-task-helpers.sh"`

### Schema v3

```
TASK_ID=<int>  TASK_TITLE=<text>  TASK_TYPE=<bug|feature|bugfix|refactor|research|audit|docs|infrastructure>
TASK_STATUS=<draft|active|in_progress|paused|blocked|pending_user_confirmation|done|cancelled>
TASK_TAGS=<comma-sep>  TASK_CREATED_BY  TASK_ASSIGNED_TO  TASK_BLOCKERS
TASK_DESCRIPTION=<\n-delimited>  TASK_ACCEPTANCE_CRITERIA  TASK_HYPOTHESES="1. [HIGH] Text\n..."
TASK_DECISION_LOG="epoch:text\n..."  TASK_SUBTASKS="idx:title:status\n..."  TASK_NOTES
TASK_RELATED_FILES=<pipe-delimited>  TASK_TIMESTAMPS=<pipe-delimited event=epoch>
```

**Lifecycle:** `draft` → `active` → `in_progress` → `paused`/`blocked` → `pending_user_confirmation` → `done`/`cancelled`

### Operations

```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
TD="$(task_dir "$PROJECT_DIR")"

# List (--status in_progress | --all)
task_list "$PROJECT_DIR"

# Add
ID=$(task_create "$PROJECT_DIR" "TITLE" "feature" "CREATOR" "DESCRIPTION")

# Transition: start/pause/block/confirm/done/cancel
task_update_status "$PROJECT_DIR" "ID" "in_progress"

# Update field
task_update_field "${TD}/ID.task" "TASK_DESCRIPTION" "New value"

# Show
task_read "${TD}/ID.task"
echo "ID=$TASK_ID Title=$TASK_TITLE Status=$TASK_STATUS Type=$TASK_TYPE"
# Print multiline fields with: printf '%s\n' "$(echo "$FIELD" | sed 's/\\n/\n/g')"

# Subtasks
task_add_subtask "${TD}/ID.task" "Title"
task_update_subtask "${TD}/ID.task" "1" "done"  # pending|in_progress|done|skipped

# Decision log / Notes / Related files
task_add_decision "${TD}/ID.task" "Decision text"
task_add_note "${TD}/ID.task" "Note text"
task_add_related_file "${TD}/ID.task" "path/to/file.sh"
```

### Encoding
Multiline: `\n` literal. Files: pipe-delimited. Tags: comma-separated. Subtask: `idx:title:status`. Decisions: `epoch:text`. Atomic writes (tmp+mv).
