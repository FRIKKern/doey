---
name: doey-task
description: Manage session tasks — list, add, start, mark done/failed, describe, attach. Tasks are user-confirmed goals tracked on the dashboard. Use when you need to "show tasks", "add a task", "mark a task done", "what are we working on", or "create a task".
---

## Context

- Tasks dir: !`ls $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/tasks/*.task 2>/dev/null || echo "(no tasks)"`
- Active tasks: !`TD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/tasks"; for f in "$TD"/*.task; do [ -f "$f" ] && ! grep -q "^TASK_STATUS=done\|^TASK_STATUS=cancelled" "$f" && cat "$f" && echo "---"; done 2>/dev/null || echo "(none)"`

## Prompt

Manage Doey session tasks. Tasks follow a 6-status lifecycle from creation to completion.

### Task file format

Stored in `${RUNTIME_DIR}/tasks/N.task`:
```
TASK_ID=1
TASK_TITLE=Implement the auth system
TASK_STATUS=in_progress
TASK_CREATED=1711234567
TASK_DESCRIPTION=Multi-line text with literal \n encoding for newlines
TASK_ATTACHMENTS=https://example.com/spec.pdf|/path/to/mockup.png
```

### Status lifecycle

`active` → `in_progress` → `pending_user_confirmation` → `done`

| Status | Meaning |
|--------|---------|
| `active` | Task created, not yet started |
| `in_progress` | Work is underway |
| `pending_user_confirmation` | Work complete, awaiting user review |
| `done` | User confirmed complete |
| `cancelled` | Abandoned |
| `failed` | Work failed |

### Operations

**List tasks** — shows all active (non-terminal) tasks
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
printf 'TASK_ID=%s\nTASK_TITLE=%s\nTASK_STATUS=active\nTASK_CREATED=%s\nTASK_DESCRIPTION=%s\nTASK_ATTACHMENTS=%s\n' \
  "$ID" "YOUR TITLE HERE" "$NOW" "" "" > "${TD}/${ID}.task"
echo "Created task $ID"
```

Optional flags for add: `--description "text"` and `--attach "url_or_path"`.

**Start work** — `doey task start <id>` — moves to `in_progress`

**Mark pending** — `doey task pending <id>` — moves to `pending_user_confirmation`

**Mark done** — `doey task done <id>` — moves to `done` (terminal)

**Mark failed** — `doey task failed <id>` — moves to `failed` (terminal)

**Cancel** — `doey task cancel <id>` — moves to `cancelled` (terminal)

**Set description** on an existing task
```bash
TD="${RUNTIME_DIR}/tasks"
FILE="${TD}/ID_HERE.task"
TMP="${FILE}.tmp"
while IFS= read -r line; do
  case "${line%%=*}" in TASK_DESCRIPTION) echo "TASK_DESCRIPTION=Your description here" ;;
  *) echo "$line" ;; esac
done < "$FILE" > "$TMP" && mv "$TMP" "$FILE"
```

**Add attachment** to an existing task
```bash
TD="${RUNTIME_DIR}/tasks"
FILE="${TD}/ID_HERE.task"
TMP="${FILE}.tmp"
while IFS= read -r line; do
  case "${line%%=*}" in TASK_ATTACHMENTS)
    existing="${line#*=}"
    if [ -n "$existing" ]; then echo "TASK_ATTACHMENTS=${existing}|NEW_ATTACHMENT"
    else echo "TASK_ATTACHMENTS=NEW_ATTACHMENT"; fi ;;
  *) echo "$line" ;; esac
done < "$FILE" > "$TMP" && mv "$TMP" "$FILE"
```

## Rules

1. SM sets `in_progress` when dispatching work to a team. SM sets `pending_user_confirmation` when work completes. Terminal states: `done`, `cancelled`, `failed`.
2. When listing tasks, show: ID, status (colored), title, age.
3. When asked "what are we working on" or "task status" — list non-terminal tasks and summarize progress.
4. Boss auto-creates a task for every goal dispatched to SM. Session Manager routes tasks to teams.
5. Description supports multi-line text with `\n` literal encoding. Attachments are pipe-delimited (`|`) URLs or file paths.
