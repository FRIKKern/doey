---
name: doey-task
description: Manage session tasks — list, add, start, mark done/failed, describe, attach. Tasks are user-confirmed goals tracked on the dashboard. Use when you need to "show tasks", "add a task", "mark a task done", "what are we working on", or "create a task".
---

- Active tasks: !`TD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/tasks"; for f in "$TD"/*.task; do [ -f "$f" ] && ! grep -q "^TASK_STATUS=done\|^TASK_STATUS=cancelled" "$f" && cat "$f" && echo "---"; done 2>/dev/null || echo "(none)"`

Tasks stored in `${RUNTIME_DIR}/tasks/N.task` (fields: TASK_ID, TASK_TITLE, TASK_STATUS, TASK_CREATED, TASK_DESCRIPTION, TASK_ATTACHMENTS).

**Lifecycle:** `active` → `in_progress` → `pending_user_confirmation` → `done` | `cancelled` | `failed`

### List
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
TD="${RUNTIME_DIR}/tasks"
for f in "$TD"/*.task; do [ -f "$f" ] && cat "$f" && echo "---"; done 2>/dev/null || echo "(none)"
```

### Add
```bash
TD="${RUNTIME_DIR}/tasks"; mkdir -p "$TD"
NEXT_ID_FILE="${TD}/.next_id"; ID=1
[ -f "$NEXT_ID_FILE" ] && ID=$(cat "$NEXT_ID_FILE")
echo $((ID + 1)) > "$NEXT_ID_FILE"
printf 'TASK_ID=%s\nTASK_TITLE=%s\nTASK_STATUS=active\nTASK_CREATED=%s\nTASK_DESCRIPTION=%s\nTASK_ATTACHMENTS=%s\n' \
  "$ID" "YOUR TITLE HERE" "$(date +%s)" "" "" > "${TD}/${ID}.task"
```

### Transition
`start <id>` → in_progress | `confirm <id>` → pending | `done/failed/cancel <id>` → terminal

### Update field
```bash
TD="${RUNTIME_DIR}/tasks"; FILE="${TD}/ID_HERE.task"; TMP="${FILE}.tmp"
while IFS= read -r line; do
  case "${line%%=*}" in TASK_DESCRIPTION) echo "TASK_DESCRIPTION=New value" ;;
  *) echo "$line" ;; esac
done < "$FILE" > "$TMP" && mv "$TMP" "$FILE"
```
Attachments: append with `|` delimiter.

### Rules
- SM sets `in_progress` on dispatch, `pending_user_confirmation` on completion
- Show: ID, status (colored), title, age. Boss auto-creates tasks for SM goals
- Description uses `\n` literal encoding; attachments are pipe-delimited
