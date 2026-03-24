---
name: doey-task
description: Manage session tasks — list, add, mark pending/done, cancel. Tasks are user-confirmed goals tracked on the dashboard. Use when you need to "show tasks", "add a task", "mark a task done", "what are we working on", or "create a task".
---

## Context

- Tasks dir: !`ls $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/tasks/*.task 2>/dev/null || echo "(no tasks)"`
- Active tasks: !`TD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/tasks"; for f in "$TD"/*.task 2>/dev/null; do [ -f "$f" ] && grep -v "^TASK_STATUS=done" "$f" | grep -q "TASK_" && cat "$f" && echo "---"; done 2>/dev/null || echo "(none)"`

## Prompt

Manage Doey session tasks. Tasks are **user-owned goals** — the user is the only one who confirms a task as done.

### Task file format

Stored in `${RUNTIME_DIR}/tasks/N.task`:
```
TASK_ID=1
TASK_TITLE=Implement the auth system
TASK_STATUS=active
TASK_CREATED=1711234567
```

### Status values

| Status | Meaning |
|--------|---------|
| `active` | In progress |
| `pending_user_confirmation` | Work done — awaiting user sign-off |
| `done` | **User confirmed.** Cannot be undone |
| `cancelled` | Dropped |

### Operations

**List tasks**
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
TD="${RUNTIME_DIR}/tasks"
for f in "$TD"/*.task; do [ -f "$f" ] && cat "$f" && echo "---"; done 2>/dev/null || echo "(none)"
```

**Add a task** (from injected RUNTIME_DIR above)
```bash
TD="${RUNTIME_DIR}/tasks"
mkdir -p "$TD"
NEXT_ID_FILE="${TD}/.next_id"; ID=1
[ -f "$NEXT_ID_FILE" ] && ID=$(cat "$NEXT_ID_FILE")
echo $((ID + 1)) > "$NEXT_ID_FILE"
NOW=$(date +%s)
printf 'TASK_ID=%s\nTASK_TITLE=%s\nTASK_STATUS=active\nTASK_CREATED=%s\n' \
  "$ID" "YOUR TITLE HERE" "$NOW" > "${TD}/${ID}.task"
echo "Created task $ID"
```

**Mark pending** (agent signals completion — user must still confirm)
```bash
TD="${RUNTIME_DIR}/tasks"
FILE="${TD}/ID_HERE.task"
TMP="${FILE}.tmp"
while IFS= read -r line; do
  case "${line%%=*}" in TASK_STATUS) echo "TASK_STATUS=pending_user_confirmation" ;;
  *) echo "$line" ;; esac
done < "$FILE" > "$TMP" && mv "$TMP" "$FILE"
```

**Mark done** — ONLY when the user explicitly confirms. Always ask for confirmation before executing.
```bash
TD="${RUNTIME_DIR}/tasks"
FILE="${TD}/ID_HERE.task"
TMP="${FILE}.tmp"
while IFS= read -r line; do
  case "${line%%=*}" in TASK_STATUS) echo "TASK_STATUS=done" ;;
  *) echo "$line" ;; esac
done < "$FILE" > "$TMP" && mv "$TMP" "$FILE"
```

**Cancel a task**
```bash
# Same pattern as mark done, but TASK_STATUS=cancelled
```

## Rules

1. **Never mark a task `done` without explicit user confirmation.** Say "This looks complete — run `doey task done <id>` to confirm" instead.
2. Workers and managers may only set status to `pending_user_confirmation`. The `done` transition belongs to the user.
3. When listing tasks, show: ID, status (colored), title, age.
4. When asked "what are we working on" or "task status" — list active + pending tasks and summarize progress.
5. The Session Manager should propose creating a task for any high-level user goal that will take more than a few minutes.
