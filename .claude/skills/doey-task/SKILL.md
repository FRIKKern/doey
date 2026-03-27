---
name: doey-task
description: Manage session tasks — list, add, mark pending/done, cancel, describe, attach. Tasks are user-confirmed goals tracked on the dashboard. Use when you need to "show tasks", "add a task", "mark a task done", "what are we working on", or "create a task".
---

## Context

- Tasks dir: !`ls $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/tasks/*.task 2>/dev/null || echo "(no tasks)"`
- Active tasks: !`TD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/tasks"; for f in "$TD"/*.task; do [ -f "$f" ] && grep -v "^TASK_STATUS=done" "$f" | grep -q "TASK_" && cat "$f" && echo "---"; done 2>/dev/null || echo "(none)"`

## Prompt

Manage Doey session tasks. Tasks are **user-owned goals** — the user is the only one who confirms a task as done.

### Task file format

Stored in `${RUNTIME_DIR}/tasks/N.task`:
```
TASK_ID=1
TASK_TITLE=Implement the auth system
TASK_STATUS=active
TASK_CREATED=1711234567
TASK_DESCRIPTION=Multi-line text with literal \n encoding for newlines
TASK_ATTACHMENTS=https://example.com/spec.pdf|/path/to/mockup.png
```

### Status values

| Status | Meaning |
|--------|---------|
| `active` | In progress |
| `blocked` | Waiting on external dependency or prerequisite |
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
printf 'TASK_ID=%s\nTASK_TITLE=%s\nTASK_STATUS=active\nTASK_CREATED=%s\nTASK_DESCRIPTION=%s\nTASK_ATTACHMENTS=%s\n' \
  "$ID" "YOUR TITLE HERE" "$NOW" "" "" > "${TD}/${ID}.task"
echo "Created task $ID"
```

Optional flags for add: `--description "text"` and `--attach "url_or_path"`.

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
5. Boss should propose creating a task for any high-level user goal that will take more than a few minutes. Session Manager routes tasks to teams.
6. Description supports multi-line text with `\n` literal encoding. Attachments are pipe-delimited (`|`) URLs or file paths.
