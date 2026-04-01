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
TASK_BLOCKS=<comma-sep task IDs>  TASK_BLOCKED_BY=<comma-sep task IDs>
TASK_PLAN_PHASE=<gathering|drafted|approved|executing|reviewing|done>
TASK_TODOLIST=<\n-delimited "id:status:text" entries>
```

**Lifecycle:** `draft` → `active` → `in_progress` → `paused`/`blocked` → `pending_user_confirmation` → `done`/`cancelled`

**Plan phases** (orthogonal to status): `gathering` → `drafted` → `approved` → `executing` → `reviewing` → `done`
Plan phase is optional — not all tasks need one. Only change phase when explicitly requested.

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

# Dependencies: set "task A blocks tasks B and C"
task_set_blocks "$PROJECT_DIR" "A" "B,C"

# Plan phase: set phase for a task
task_set_plan_phase "$PROJECT_DIR" "ID" "approved"

# Check if task is dispatchable (not blocked, phase allows it)
task_is_dispatchable "$PROJECT_DIR" "ID"  # exit 0=yes, 1=no (prints reason)
```

### Dependencies

`TASK_BLOCKS` and `TASK_BLOCKED_BY` are comma-separated task ID lists. They are **bidirectionally synced**:

- Setting `blocks` on task A with value `B,C` automatically adds A to `blockedBy` on tasks B and C
- When a task transitions to `done`, iterate its `TASK_BLOCKS` list and remove this task's ID from each blocked task's `TASK_BLOCKED_BY`. If `TASK_BLOCKED_BY` becomes empty, that task is unblocked
- **Dispatch guard:** A task with non-empty `TASK_BLOCKED_BY` must NOT be dispatched — print warning: `"Task ID is blocked by: X, Y"`
- **Circular dep warning:** Before setting blocks, walk the chain (A blocks B, does B already block A?). If circular, warn but still allow: `"Warning: circular dependency detected between task A and task B"`
- **Missing ref warning:** If a referenced task ID doesn't have a `.task` file, warn: `"Warning: task ID not found"` — don't error

```bash
# Implementation — use existing helpers, inline logic:
task_set_blocks() {
  local project_dir="$1" task_id="$2" blocks_csv="$3"
  local td; td="$(task_dir "$project_dir")"
  local task_file="${td}/${task_id}.task"
  [ -f "$task_file" ] || { printf 'Error: task %s not found\n' "$task_id" >&2; return 1; }

  task_update_field "$task_file" "TASK_BLOCKS" "$blocks_csv"

  # Bidirectional sync: add task_id to each blocked task's BLOCKED_BY
  local remaining="$blocks_csv" entry
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *,*) entry="${remaining%%,*}"; remaining="${remaining#*,}" ;;
      *)   entry="$remaining"; remaining="" ;;
    esac
    entry="${entry## }"; entry="${entry%% }"
    [ -z "$entry" ] && continue
    local blocked_file="${td}/${entry}.task"
    if [ ! -f "$blocked_file" ]; then
      printf 'Warning: task %s not found\n' "$entry" >&2; continue
    fi
    # Circular dep check: does the blocked task already block us?
    local their_blocks
    their_blocks="$(_task_read_field "$blocked_file" "TASK_BLOCKS")"
    local check="$their_blocks"
    while [ -n "$check" ]; do
      local centry
      case "$check" in
        *,*) centry="${check%%,*}"; check="${check#*,}" ;;
        *)   centry="$check"; check="" ;;
      esac
      centry="${centry## }"; centry="${centry%% }"
      if [ "$centry" = "$task_id" ]; then
        printf 'Warning: circular dependency detected between task %s and task %s\n' "$task_id" "$entry" >&2
        break
      fi
    done
    # Append task_id to their BLOCKED_BY (avoid duplicates)
    local current_bb
    current_bb="$(_task_read_field "$blocked_file" "TASK_BLOCKED_BY")"
    local already=0 rem2="$current_bb"
    while [ -n "$rem2" ]; do
      local e2
      case "$rem2" in
        *,*) e2="${rem2%%,*}"; rem2="${rem2#*,}" ;;
        *)   e2="$rem2"; rem2="" ;;
      esac
      [ "$e2" = "$task_id" ] && already=1
    done
    if [ "$already" -eq 0 ]; then
      if [ -n "$current_bb" ]; then
        task_update_field "$blocked_file" "TASK_BLOCKED_BY" "${current_bb},${task_id}"
      else
        task_update_field "$blocked_file" "TASK_BLOCKED_BY" "$task_id"
      fi
    fi
  done
}

# On task completion — call after task_update_status to "done":
task_unblock_dependents() {
  local project_dir="$1" task_id="$2"
  local td; td="$(task_dir "$project_dir")"
  local task_file="${td}/${task_id}.task"
  [ -f "$task_file" ] || return 0
  local blocks_csv
  blocks_csv="$(_task_read_field "$task_file" "TASK_BLOCKS")"
  [ -z "$blocks_csv" ] && return 0

  local remaining="$blocks_csv" entry
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *,*) entry="${remaining%%,*}"; remaining="${remaining#*,}" ;;
      *)   entry="$remaining"; remaining="" ;;
    esac
    entry="${entry## }"; entry="${entry%% }"
    [ -z "$entry" ] && continue
    local dep_file="${td}/${entry}.task"
    [ -f "$dep_file" ] || continue
    local current_bb
    current_bb="$(_task_read_field "$dep_file" "TASK_BLOCKED_BY")"
    # Remove task_id from comma-separated list
    local new_bb="" rem3="$current_bb" e3
    while [ -n "$rem3" ]; do
      case "$rem3" in
        *,*) e3="${rem3%%,*}"; rem3="${rem3#*,}" ;;
        *)   e3="$rem3"; rem3="" ;;
      esac
      e3="${e3## }"; e3="${e3%% }"
      [ "$e3" = "$task_id" ] && continue
      if [ -n "$new_bb" ]; then new_bb="${new_bb},${e3}"; else new_bb="$e3"; fi
    done
    task_update_field "$dep_file" "TASK_BLOCKED_BY" "$new_bb"
  done
}
```

**When transitioning a task to `done`**, always call `task_unblock_dependents` after `task_update_status`:
```bash
task_update_status "$PROJECT_DIR" "ID" "done"
task_unblock_dependents "$PROJECT_DIR" "ID"
```

### Plan Phases

`TASK_PLAN_PHASE` is optional and orthogonal to `TASK_STATUS`. Allowed values: `gathering`, `drafted`, `approved`, `executing`, `reviewing`, `done`.

```bash
task_set_plan_phase() {
  local project_dir="$1" task_id="$2" phase="$3"
  local valid="gathering drafted approved executing reviewing done"
  local ok=0 v; for v in $valid; do [ "$v" = "$phase" ] && ok=1; done
  if [ "$ok" -eq 0 ]; then
    printf 'Error: invalid plan phase "%s" (valid: %s)\n' "$phase" "$valid" >&2; return 1
  fi
  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1
  task_update_field "$task_file" "TASK_PLAN_PHASE" "$phase"
  task_add_decision "$task_file" "Plan phase set to ${phase}"
}
```

**Dispatch guard:** Tasks in `gathering` or `drafted` phase should NOT be dispatched for implementation.

```bash
task_is_dispatchable() {
  local project_dir="$1" task_id="$2"
  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1

  local blocked_by phase
  blocked_by="$(_task_read_field "$task_file" "TASK_BLOCKED_BY")"
  phase="$(_task_read_field "$task_file" "TASK_PLAN_PHASE")"

  if [ -n "$blocked_by" ]; then
    printf 'Task %s is blocked by: %s\n' "$task_id" "$blocked_by" >&2; return 1
  fi
  case "$phase" in
    gathering|drafted)
      printf 'Task %s plan phase is "%s" — not ready for dispatch\n' "$task_id" "$phase" >&2; return 1 ;;
  esac
  return 0
}
```

### TodoList

`TASK_TODOLIST` is a `\n`-delimited checklist of `id:status:text` entries attached to a task. Status values: `pending`, `in_progress`, `done`. IDs are simple incrementing integers within the task.

Example value: `1:pending:Read the coordinator source\n2:in_progress:Adapt prompt patterns\n3:done:Write tests`

#### TodoList Operations

```bash
# todo-add <task-id> <text> — append a new pending item, auto-increment ID
task_todo_add() {
  local task_file="$1" text="$2"
  local current; current="$(_task_read_field "$task_file" "TASK_TODOLIST")"
  local max_id=0 remaining="$current"
  while [ -n "$remaining" ]; do
    local line
    case "$remaining" in
      *'\n'*) line="${remaining%%\\n*}"; remaining="${remaining#*\\n}" ;;
      *)      line="$remaining"; remaining="" ;;
    esac
    local id="${line%%:*}"
    [ "$id" -gt "$max_id" ] 2>/dev/null && max_id="$id"
  done
  local new_id=$((max_id + 1))
  local new_entry="${new_id}:pending:${text}"
  if [ -n "$current" ]; then
    task_update_field "$task_file" "TASK_TODOLIST" "${current}\\n${new_entry}"
  else
    task_update_field "$task_file" "TASK_TODOLIST" "$new_entry"
  fi
  printf 'Added todo #%d: %s\n' "$new_id" "$text"
}

# todo-check <task-id> <item-id> — mark item as done
task_todo_set_status() {
  local task_file="$1" item_id="$2" new_status="$3"
  local current; current="$(_task_read_field "$task_file" "TASK_TODOLIST")"
  [ -z "$current" ] && { printf 'Error: task has no todolist\n' >&2; return 1; }
  local found=0 result="" remaining="$current"
  while [ -n "$remaining" ]; do
    local line
    case "$remaining" in
      *'\n'*) line="${remaining%%\\n*}"; remaining="${remaining#*\\n}" ;;
      *)      line="$remaining"; remaining="" ;;
    esac
    local id="${line%%:*}"
    local rest="${line#*:}"
    local text="${rest#*:}"
    if [ "$id" = "$item_id" ]; then
      found=1; line="${id}:${new_status}:${text}"
    fi
    if [ -n "$result" ]; then result="${result}\\n${line}"; else result="$line"; fi
  done
  [ "$found" -eq 0 ] && { printf 'Error: todo item %s not found\n' "$item_id" >&2; return 1; }
  task_update_field "$task_file" "TASK_TODOLIST" "$result"
}

# todo-remove <task-id> <item-id> — remove an item
task_todo_remove() {
  local task_file="$1" item_id="$2"
  local current; current="$(_task_read_field "$task_file" "TASK_TODOLIST")"
  [ -z "$current" ] && { printf 'Error: task has no todolist\n' >&2; return 1; }
  local found=0 result="" remaining="$current"
  while [ -n "$remaining" ]; do
    local line
    case "$remaining" in
      *'\n'*) line="${remaining%%\\n*}"; remaining="${remaining#*\\n}" ;;
      *)      line="$remaining"; remaining="" ;;
    esac
    local id="${line%%:*}"
    if [ "$id" = "$item_id" ]; then found=1; continue; fi
    if [ -n "$result" ]; then result="${result}\\n${line}"; else result="$line"; fi
  done
  [ "$found" -eq 0 ] && { printf 'Error: todo item %s not found\n' "$item_id" >&2; return 1; }
  task_update_field "$task_file" "TASK_TODOLIST" "$result"
  printf 'Removed todo #%s\n' "$item_id"
}

# todo-list <task-id> — show all items with status indicators
task_todo_list() {
  local task_file="$1"
  local current; current="$(_task_read_field "$task_file" "TASK_TODOLIST")"
  [ -z "$current" ] && { printf '(no todolist)\n'; return 0; }
  local remaining="$current"
  while [ -n "$remaining" ]; do
    local line
    case "$remaining" in
      *'\n'*) line="${remaining%%\\n*}"; remaining="${remaining#*\\n}" ;;
      *)      line="$remaining"; remaining="" ;;
    esac
    local id="${line%%:*}"
    local rest="${line#*:}"
    local status="${rest%%:*}"
    local text="${rest#*:}"
    local icon
    case "$status" in
      done)        icon="[x]" ;;
      in_progress) icon="[~]" ;;
      *)           icon="[ ]" ;;
    esac
    printf '  %s #%s %s\n' "$icon" "$id" "$text"
  done
}

# todo-progress — compute done/total
task_todo_progress() {
  local task_file="$1"
  local current; current="$(_task_read_field "$task_file" "TASK_TODOLIST")"
  [ -z "$current" ] && { printf ''; return 0; }
  local total=0 done_count=0 remaining="$current"
  while [ -n "$remaining" ]; do
    local line
    case "$remaining" in
      *'\n'*) line="${remaining%%\\n*}"; remaining="${remaining#*\\n}" ;;
      *)      line="$remaining"; remaining="" ;;
    esac
    total=$((total + 1))
    local rest="${line#*:}"
    local status="${rest%%:*}"
    [ "$status" = "done" ] && done_count=$((done_count + 1))
  done
  # Build progress bar: # for done, - for remaining
  local bar="" i=0
  while [ "$i" -lt "$done_count" ]; do bar="${bar}#"; i=$((i + 1)); done
  i=0; local rem=$((total - done_count))
  while [ "$i" -lt "$rem" ]; do bar="${bar}-"; i=$((i + 1)); done
  printf '[%s] %d/%d' "$bar" "$done_count" "$total"
}
```

#### TodoList Command Reference

| Command | Usage | Description |
|---------|-------|-------------|
| `todo-add` | `task_todo_add "${TD}/ID.task" "Item text"` | Add pending item (auto-ID) |
| `todo-check` | `task_todo_set_status "${TD}/ID.task" "1" "done"` | Mark item done |
| `todo-progress` | `task_todo_set_status "${TD}/ID.task" "1" "in_progress"` | Mark item in progress |
| `todo-uncheck` | `task_todo_set_status "${TD}/ID.task" "1" "pending"` | Reset item to pending |
| `todo-remove` | `task_todo_remove "${TD}/ID.task" "1"` | Remove an item |
| `todo-list` | `task_todo_list "${TD}/ID.task"` | Show items with status icons |

#### TodoList Usage Patterns

- **Workers** should update checklist items as they work — mark `in_progress` when starting an item, `done` when complete
- **SM/Manager** can monitor todo progress to gauge completion percentage via `task_todo_progress`
- **TodoList is the plan made concrete** — each item is a verifiable step toward task completion
- **Progress percentage:** `done_count / total_count * 100` — available via `task_todo_progress` which returns `[###--] 3/5` format
- Tasks without a todoList work unchanged — the field is optional and all existing behavior is preserved

### Listing Enhancements

When listing tasks, show dependency and phase info:

- **Blocked tasks:** append `BLOCKED by task-3, task-7` in red/warning after status
- **Plan phase:** show `[phase]` before status when set, e.g., `[approved] [in_progress]`
- **Ready indicator:** tasks with no blockers AND phase is approved/executing/unset are ready to dispatch
- Keep existing format — these are additive columns

In `task_list`, after reading each task, also read:
```bash
local blocked_by phase
blocked_by="$(_task_read_field "$f" "TASK_BLOCKED_BY")"
phase="$(_task_read_field "$f" "TASK_PLAN_PHASE")"
```

Then adjust the display line:
- If `blocked_by` is non-empty: append ` ← BLOCKED by ${blocked_by}` (gum: `--foreground 1`, plain: as-is)
- If `phase` is non-empty: insert `[${phase}]` before `[${TASK_STATUS}]`
- If `TASK_TODOLIST` is non-empty: append progress indicator from `task_todo_progress` — e.g., `[###--] 3/5`
- Plain format becomes: `#ID [phase] [status] [type] Title (age) [###--] 3/5` or without progress/phase if unset

### Encoding
Multiline: `\n` literal. Files: pipe-delimited. Tags: comma-separated. Subtask: `idx:title:status`. Decisions: `epoch:text`. Dependencies: comma-separated task IDs. TodoList: `id:status:text` (`\n`-delimited, status=`pending`|`in_progress`|`done`). Atomic writes (tmp+mv).
