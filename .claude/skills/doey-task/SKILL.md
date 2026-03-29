---
name: doey-task
description: Manage persistent project tasks — list, add, transition, show, subtasks, decisions, notes. Tasks stored in .doey/tasks/ (survives reboot). Use when you need to "show tasks", "add a task", "mark a task done", "what are we working on", or "create a task".
---

- Active tasks: !`TD="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.doey/tasks"; for f in "$TD"/*.task; do [ -f "$f" ] && ! grep -q "^TASK_STATUS=done\|^TASK_STATUS=cancelled" "$f" && cat "$f" && echo "---"; done 2>/dev/null || echo "(none)"`

Tasks stored in `.doey/tasks/N.task` — persistent, project-local, survives reboot.

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
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TD="${PROJECT_ROOT}/.doey/tasks"
for f in "$TD"/*.task; do [ -f "$f" ] && cat "$f" && echo "---"; done 2>/dev/null || echo "(none)"
```

### Add
```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TD="${PROJECT_ROOT}/.doey/tasks"; mkdir -p "$TD"
NEXT_ID_FILE="${TD}/.next_id"; ID=1
[ -f "$NEXT_ID_FILE" ] && ID=$(cat "$NEXT_ID_FILE")
echo $((ID + 1)) > "$NEXT_ID_FILE"
NOW=$(date +%s)
printf 'TASK_SCHEMA_VERSION=3\nTASK_ID=%s\nTASK_TITLE=%s\nTASK_STATUS=active\nTASK_TYPE=%s\nTASK_TAGS=\nTASK_CREATED_BY=%s\nTASK_ASSIGNED_TO=\nTASK_DESCRIPTION=%s\nTASK_ACCEPTANCE_CRITERIA=\nTASK_HYPOTHESES=\nTASK_DECISION_LOG=\nTASK_SUBTASKS=\nTASK_RELATED_FILES=\nTASK_BLOCKERS=\nTASK_TIMESTAMPS=created=%s\nTASK_NOTES=\n' \
  "$ID" "TITLE" "feature" "CREATOR" "DESCRIPTION" "$NOW" > "${TD}/${ID}.task"
```

### Transition
`start <id>` → in_progress | `pause <id>` → paused | `block <id>` → blocked | `confirm <id>` → pending_user_confirmation | `done/cancel <id>` → terminal

```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TD="${PROJECT_ROOT}/.doey/tasks"; FILE="${TD}/ID_HERE.task"; TMP="${FILE}.tmp"
NEW_STATUS="in_progress"; NOW=$(date +%s)
while IFS= read -r line; do
  case "${line%%=*}" in
    TASK_STATUS) echo "TASK_STATUS=${NEW_STATUS}" ;;
    TASK_TIMESTAMPS) echo "${line}|${NEW_STATUS}=${NOW}" ;;
    *) echo "$line" ;;
  esac
done < "$FILE" > "$TMP" && mv "$TMP" "$FILE"
```

### Update field
```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TD="${PROJECT_ROOT}/.doey/tasks"; FILE="${TD}/ID_HERE.task"; TMP="${FILE}.tmp"
while IFS= read -r line; do
  case "${line%%=*}" in TASK_DESCRIPTION) echo "TASK_DESCRIPTION=New value" ;;
  *) echo "$line" ;; esac
done < "$FILE" > "$TMP" && mv "$TMP" "$FILE"
```

### Show
```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
FILE="${PROJECT_ROOT}/.doey/tasks/ID_HERE.task"
[ ! -f "$FILE" ] && echo "Task not found" && exit 1
while IFS= read -r line; do
  KEY="${line%%=*}"; VAL="${line#*=}"
  case "$KEY" in
    TASK_ID) echo "ID: $VAL" ;;
    TASK_TITLE) echo "Title: $VAL" ;;
    TASK_STATUS) echo "Status: $VAL" ;;
    TASK_TYPE) echo "Type: $VAL" ;;
    TASK_TAGS) [ -n "$VAL" ] && echo "Tags: $VAL" ;;
    TASK_CREATED_BY) [ -n "$VAL" ] && echo "Created by: $VAL" ;;
    TASK_ASSIGNED_TO) [ -n "$VAL" ] && echo "Assigned to: $VAL" ;;
    TASK_DESCRIPTION) [ -n "$VAL" ] && printf 'Description:\n  %s\n' "$(echo "$VAL" | sed 's/\\n/\n  /g')" ;;
    TASK_ACCEPTANCE_CRITERIA) [ -n "$VAL" ] && printf 'Acceptance Criteria:\n  %s\n' "$(echo "$VAL" | sed 's/\\n/\n  /g')" ;;
    TASK_HYPOTHESES) [ -n "$VAL" ] && printf 'Hypotheses:\n  %s\n' "$(echo "$VAL" | sed 's/\\n/\n  /g')" ;;
    TASK_DECISION_LOG) [ -n "$VAL" ] && printf 'Decisions:\n  %s\n' "$(echo "$VAL" | sed 's/\\n/\n  /g')" ;;
    TASK_SUBTASKS) [ -n "$VAL" ] && printf 'Subtasks:\n  %s\n' "$(echo "$VAL" | sed 's/\\n/\n  /g')" ;;
    TASK_RELATED_FILES) [ -n "$VAL" ] && echo "Files: $(echo "$VAL" | sed 's/|/, /g')" ;;
    TASK_BLOCKERS) [ -n "$VAL" ] && echo "Blockers: $VAL" ;;
    TASK_TIMESTAMPS) echo "Timestamps: $(echo "$VAL" | sed 's/|/, /g')" ;;
    TASK_NOTES) [ -n "$VAL" ] && printf 'Notes:\n  %s\n' "$(echo "$VAL" | sed 's/\\n/\n  /g')" ;;
  esac
done < "$FILE"
```

### Subtask management
Add subtask: read TASK_SUBTASKS, determine next index, append `\nINDEX:Title:pending`.
Update subtask status: match by index, replace status in the entry.

```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TD="${PROJECT_ROOT}/.doey/tasks"; FILE="${TD}/ID_HERE.task"; TMP="${FILE}.tmp"
# Add subtask — determine next index from current value
while IFS= read -r line; do
  case "${line%%=*}" in
    TASK_SUBTASKS)
      VAL="${line#*=}"
      if [ -z "$VAL" ]; then NEXT=1; else NEXT=$(echo "$VAL" | tr '\\' '\n' | grep -c ':' || true); NEXT=$((NEXT + 1)); fi
      echo "TASK_SUBTASKS=${VAL}${VAL:+\\n}${NEXT}:Subtask title:pending" ;;
    *) echo "$line" ;;
  esac
done < "$FILE" > "$TMP" && mv "$TMP" "$FILE"
```

### Decision log
Append timestamped entry to TASK_DECISION_LOG:
```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TD="${PROJECT_ROOT}/.doey/tasks"; FILE="${TD}/ID_HERE.task"; TMP="${FILE}.tmp"
NOW=$(date +%s)
while IFS= read -r line; do
  case "${line%%=*}" in
    TASK_DECISION_LOG)
      VAL="${line#*=}"
      echo "TASK_DECISION_LOG=${VAL}${VAL:+\\n}${NOW}:Decision text here" ;;
    *) echo "$line" ;;
  esac
done < "$FILE" > "$TMP" && mv "$TMP" "$FILE"
```

### Notes
Append to TASK_NOTES:
```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TD="${PROJECT_ROOT}/.doey/tasks"; FILE="${TD}/ID_HERE.task"; TMP="${FILE}.tmp"
while IFS= read -r line; do
  case "${line%%=*}" in
    TASK_NOTES)
      VAL="${line#*=}"
      echo "TASK_NOTES=${VAL}${VAL:+\\n}New note text here" ;;
    *) echo "$line" ;;
  esac
done < "$FILE" > "$TMP" && mv "$TMP" "$FILE"
```

### Rules
- Tasks persist in `.doey/tasks/` — project-local, survives reboot
- Every status transition appends `status=epoch` to TASK_TIMESTAMPS
- Multiline fields use `\n` literal encoding; related files are pipe-delimited; tags comma-separated
- Subtask format: `index:title:status`; decision log: `epoch:text`
- All writes use atomic tmp+mv pattern
