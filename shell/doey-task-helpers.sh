#!/usr/bin/env bash
# doey-task-helpers.sh — Schema v3 persistent task management library
# Sourceable library, not standalone. Tasks stored in .doey/tasks/ (persistent).
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────
_TASK_VALID_STATUSES="draft active in_progress paused blocked pending_user_confirmation done cancelled"
_TASK_VALID_TYPES="bug feature bugfix refactor research audit docs infrastructure"
_TASK_VALID_SUBTASK_STATUSES="pending in_progress done skipped"
_TASK_SCHEMA_VERSION_CURRENT="3"

# ── _touch_task_updated ──────────────────────────────────────────────
# Set TASK_UPDATED=<epoch> on a .task file. Upserts the field.
# Args: task_file
_touch_task_updated() {
  local task_file="$1"
  [ -f "$task_file" ] || return 0
  local _ts; _ts=$(date +%s)
  if grep -q '^TASK_UPDATED=' "$task_file" 2>/dev/null; then
    sed -i '' "s/^TASK_UPDATED=.*/TASK_UPDATED=${_ts}/" "$task_file"
  else
    echo "TASK_UPDATED=${_ts}" >> "$task_file"
  fi
}

# ── task_dir ──────────────────────────────────────────────────────────
# Resolve .doey/tasks/ path relative to project root. Auto-creates on first call.
# Args: project_dir
# Returns (echo): absolute path to .doey/tasks/
task_dir() {
  local project_dir="$1"
  local td="${project_dir}/.doey/tasks"
  mkdir -p "$td"
  echo "$td"
}

# ── task_next_id ──────────────────────────────────────────────────────
# Get next auto-increment ID. Writes incremented value back.
# Args: tasks_dir
# Returns (echo): next ID
task_next_id() {
  local tasks_dir="$1"
  local counter_file="${tasks_dir}/.next_id"
  local id=1
  if [ -f "$counter_file" ]; then
    id=$(cat "$counter_file")
  fi
  echo "$((id + 1))" > "$counter_file"
  echo "$id"
}

# ── task_create ───────────────────────────────────────────────────────
# Create a new .task file with all schema v3 fields.
# Args: project_dir title [type] [created_by] [description]
# Returns (echo): task ID
task_create() {
  local project_dir="$1" title="$2"
  local task_type="${3:-feature}" created_by="${4:-Boss}" description="${5:-}"

  local tasks_dir
  tasks_dir="$(task_dir "$project_dir")"

  local id
  id="$(task_next_id "$tasks_dir")"

  local now
  now=$(date +%s)

  local task_file="${tasks_dir}/${id}.task"
  local tmp="${task_file}.tmp"

  printf 'TASK_SCHEMA_VERSION=%s\n' "$_TASK_SCHEMA_VERSION_CURRENT" > "$tmp"
  printf 'TASK_ID=%s\n' "$id" >> "$tmp"
  printf 'TASK_TITLE=%s\n' "$title" >> "$tmp"
  printf 'TASK_STATUS=active\n' >> "$tmp"
  printf 'TASK_TYPE=%s\n' "$task_type" >> "$tmp"
  printf 'TASK_TAGS=\n' >> "$tmp"
  printf 'TASK_CREATED_BY=%s\n' "$created_by" >> "$tmp"
  printf 'TASK_ASSIGNED_TO=\n' >> "$tmp"
  printf 'TASK_DESCRIPTION=%s\n' "$description" >> "$tmp"
  printf 'TASK_ACCEPTANCE_CRITERIA=\n' >> "$tmp"
  printf 'TASK_HYPOTHESES=\n' >> "$tmp"
  printf 'TASK_DECISION_LOG=%s:Created task\n' "$now" >> "$tmp"
  printf 'TASK_SUBTASKS=\n' >> "$tmp"
  printf 'TASK_RELATED_FILES=\n' >> "$tmp"
  printf 'TASK_BLOCKERS=\n' >> "$tmp"
  printf 'TASK_TIMESTAMPS=created=%s\n' "$now" >> "$tmp"
  printf 'TASK_CURRENT_PHASE=0\n' >> "$tmp"
  printf 'TASK_TOTAL_PHASES=0\n' >> "$tmp"
  printf 'TASK_NOTES=\n' >> "$tmp"
  printf 'TASK_UPDATED=%s\n' "$now" >> "$tmp"

  mv "$tmp" "$task_file"
  echo "$id"
}

# ── task_read ─────────────────────────────────────────────────────────
# Parse a .task file and set all schema v3 shell variables.
# Args: task_file_path
# Sets: TASK_SCHEMA_VERSION, TASK_ID, TASK_TITLE, TASK_STATUS, TASK_TYPE,
#   TASK_TAGS, TASK_CREATED_BY, TASK_ASSIGNED_TO, TASK_DESCRIPTION,
#   TASK_ACCEPTANCE_CRITERIA, TASK_HYPOTHESES, TASK_DECISION_LOG,
#   TASK_SUBTASKS, TASK_RELATED_FILES, TASK_BLOCKERS, TASK_TIMESTAMPS,
#   TASK_NOTES, TASK_CURRENT_PHASE, TASK_TOTAL_PHASES,
#   TASK_CREATED (extracted from TASK_TIMESTAMPS for compat)
task_read() {
  local file="$1"
  [ -s "$file" ] || return 1

  TASK_SCHEMA_VERSION=""
  TASK_ID=""
  TASK_TITLE=""
  TASK_STATUS=""
  TASK_TYPE=""
  TASK_TAGS=""
  TASK_CREATED_BY=""
  TASK_ASSIGNED_TO=""
  TASK_DESCRIPTION=""
  TASK_ACCEPTANCE_CRITERIA=""
  TASK_HYPOTHESES=""
  TASK_DECISION_LOG=""
  TASK_SUBTASKS=""
  TASK_RELATED_FILES=""
  TASK_BLOCKERS=""
  TASK_TIMESTAMPS=""
  TASK_CURRENT_PHASE=""
  TASK_TOTAL_PHASES=""
  TASK_NOTES=""
  TASK_CREATED=""

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "${line%%=*}" in
      TASK_SCHEMA_VERSION)      TASK_SCHEMA_VERSION="${line#*=}" ;;
      TASK_ID)                  TASK_ID="${line#*=}" ;;
      TASK_TITLE)               TASK_TITLE="${line#*=}" ;;
      TASK_STATUS)              TASK_STATUS="${line#*=}" ;;
      TASK_TYPE)                TASK_TYPE="${line#*=}" ;;
      TASK_TAGS)                TASK_TAGS="${line#*=}" ;;
      TASK_CREATED_BY)          TASK_CREATED_BY="${line#*=}" ;;
      TASK_ASSIGNED_TO)         TASK_ASSIGNED_TO="${line#*=}" ;;
      TASK_DESCRIPTION)         TASK_DESCRIPTION="${line#*=}" ;;
      TASK_ACCEPTANCE_CRITERIA) TASK_ACCEPTANCE_CRITERIA="${line#*=}" ;;
      TASK_HYPOTHESES)          TASK_HYPOTHESES="${line#*=}" ;;
      TASK_DECISION_LOG)        TASK_DECISION_LOG="${line#*=}" ;;
      TASK_SUBTASKS)            TASK_SUBTASKS="${line#*=}" ;;
      TASK_RELATED_FILES)       TASK_RELATED_FILES="${line#*=}" ;;
      TASK_BLOCKERS)            TASK_BLOCKERS="${line#*=}" ;;
      TASK_TIMESTAMPS)          TASK_TIMESTAMPS="${line#*=}" ;;
      TASK_CURRENT_PHASE)       TASK_CURRENT_PHASE="${line#*=}" ;;
      TASK_TOTAL_PHASES)        TASK_TOTAL_PHASES="${line#*=}" ;;
      TASK_NOTES)               TASK_NOTES="${line#*=}" ;;
    esac
  done < "$file" || true

  # Extract TASK_CREATED from TASK_TIMESTAMPS for backward compat
  # TASK_TIMESTAMPS format: created=epoch|started=epoch|...
  TASK_CREATED=""
  if [ -n "$TASK_TIMESTAMPS" ]; then
    local ts_entry
    local remaining="$TASK_TIMESTAMPS"
    while [ -n "$remaining" ]; do
      # Split on pipe
      case "$remaining" in
        *\|*)
          ts_entry="${remaining%%|*}"
          remaining="${remaining#*|}"
          ;;
        *)
          ts_entry="$remaining"
          remaining=""
          ;;
      esac
      case "$ts_entry" in
        created=*) TASK_CREATED="${ts_entry#created=}" ;;
      esac
    done
  fi

  # Bail if no TASK_ID was parsed (malformed file)
  [ -n "${TASK_ID:-}" ] || return 1

  # Defaults for missing fields
  if [ -z "$TASK_SCHEMA_VERSION" ]; then TASK_SCHEMA_VERSION="1"; fi
  if [ -z "$TASK_TYPE" ]; then TASK_TYPE="feature"; fi
  if [ -z "$TASK_CREATED_BY" ]; then TASK_CREATED_BY="Boss"; fi
  # Default phase fields for older tasks that lack them
  if [ -z "$TASK_CURRENT_PHASE" ]; then TASK_CURRENT_PHASE="0"; fi
  if [ -z "$TASK_TOTAL_PHASES" ]; then TASK_TOTAL_PHASES="0"; fi
}

# ── task_update_field ─────────────────────────────────────────────────
# Update a single field in a .task file. Atomic write (tmp + mv).
# Args: task_file field_name new_value
task_update_field() {
  local task_file="$1" field_name="$2" new_value="$3"

  if [ ! -f "$task_file" ]; then
    printf 'Error: task file not found: %s\n' "$task_file" >&2
    return 1
  fi

  local tmp="${task_file}.tmp"
  local found=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "${line%%=*}" in
      "$field_name")
        printf '%s=%s\n' "$field_name" "$new_value"
        found=1
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$task_file" > "$tmp"

  # If field wasn't found, append it
  if [ "$found" -eq 0 ]; then
    printf '%s=%s\n' "$field_name" "$new_value" >> "$tmp"
  fi

  mv "$tmp" "$task_file"
  _touch_task_updated "$task_file"
}

# ── _task_read_field ─────────────────────────────────────────────────
# Read a single field value from a .task file.
# Args: task_file field_name. Returns (echo): field value or empty.
_task_read_field() {
  local _trf_result="" _trf_line
  while IFS= read -r _trf_line || [ -n "$_trf_line" ]; do
    case "${_trf_line%%=*}" in
      "$2") _trf_result="${_trf_line#*=}" ;;
    esac
  done < "$1" || true
  printf '%s' "$_trf_result"
}

# ── _task_append_to_field ────────────────────────────────────────────
# Append value to a delimited field. Reads current, appends, writes back.
# Args: task_file field new_value [separator] (default separator: \\n)
_task_append_to_field() {
  local current
  current="$(_task_read_field "$1" "$2")"
  if [ -n "$current" ]; then
    task_update_field "$1" "$2" "${current}${4:-\\n}${3}"
  else
    task_update_field "$1" "$2" "$3"
  fi
}

# ── _task_validate_status ─────────────────────────────────────────────
# Validate a status string. Returns 0 if valid, 1 if not.
# Args: status
_task_validate_status() {
  local status="$1" s
  for s in $_TASK_VALID_STATUSES; do
    if [ "$s" = "$status" ]; then
      return 0
    fi
  done
  return 1
}

# ── _task_status_timestamp_key ────────────────────────────────────────
# Map status to a timestamp key name.
# Args: status
# Returns (echo): timestamp key (e.g., "started", "completed")
_task_status_timestamp_key() {
  local status="$1"
  case "$status" in
    active)                       echo "activated" ;;
    in_progress)                  echo "started" ;;
    paused)                       echo "paused" ;;
    blocked)                      echo "blocked" ;;
    pending_user_confirmation)    echo "pending" ;;
    done)                         echo "completed" ;;
    cancelled)                    echo "cancelled" ;;
    *)                            echo "$status" ;;
  esac
}

# ── _task_append_timestamp ────────────────────────────────────────────
# Append a key=epoch entry to TASK_TIMESTAMPS field.
# Args: task_file key epoch
_task_append_timestamp() {
  _task_append_to_field "$1" "TASK_TIMESTAMPS" "${2}=${3}" "|"
}

# ── task_update_status ────────────────────────────────────────────────
# Update status with timestamp recording and validation.
# Args: project_dir task_id new_status
task_update_status() {
  local project_dir="$1" task_id="$2" new_status="$3"

  if ! _task_validate_status "$new_status"; then
    printf 'Error: invalid status "%s" (valid: %s)\n' "$new_status" "$_TASK_VALID_STATUSES" >&2
    return 1
  fi

  local tasks_dir
  tasks_dir="$(task_dir "$project_dir")"
  local task_file="${tasks_dir}/${task_id}.task"

  if [ ! -f "$task_file" ]; then
    printf 'Error: task %s not found\n' "$task_id" >&2
    return 1
  fi

  local now
  now=$(date +%s)

  # Update status field
  task_update_field "$task_file" "TASK_STATUS" "$new_status"

  # Append timestamp
  local ts_key
  ts_key="$(_task_status_timestamp_key "$new_status")"
  _task_append_timestamp "$task_file" "$ts_key" "$now"

  # Add decision log entry
  task_add_decision "$task_file" "Status changed to ${new_status}"
}

# ── _task_age_str ─────────────────────────────────────────────────────
# Human-readable age from epoch. Args: epoch. Returns (echo): e.g., "3h"
_task_age_str() {
  local created="$1"
  if [ -z "$created" ]; then echo "?"; return; fi
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - created))
  if [ "$elapsed" -lt 60 ]; then echo "${elapsed}s"
  elif [ "$elapsed" -lt 3600 ]; then echo "$((elapsed / 60))m"
  elif [ "$elapsed" -lt 86400 ]; then echo "$((elapsed / 3600))h"
  else echo "$((elapsed / 86400))d"; fi
}

# ── task_list ─────────────────────────────────────────────────────────
# List all tasks with optional status filter.
# Args: project_dir [--status filter] [--all]
# Prints formatted output sorted by ID.
task_list() {
  local project_dir="$1"; shift
  local status_filter="" show_all=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --status) shift; status_filter="${1:-}" ;;
      --all)    show_all=1 ;;
    esac
    shift
  done

  local tasks_dir="${project_dir}/.doey/tasks"
  if [ ! -d "$tasks_dir" ]; then
    echo "No tasks."
    return 0
  fi

  local entries="" f
  for f in "${tasks_dir}"/*.task; do
    [ -f "$f" ] || continue
    [ -s "$f" ] || continue  # skip empty files

    local TASK_SCHEMA_VERSION TASK_ID TASK_TITLE TASK_STATUS TASK_TYPE
    local TASK_TAGS TASK_CREATED_BY TASK_ASSIGNED_TO TASK_DESCRIPTION
    local TASK_ACCEPTANCE_CRITERIA TASK_HYPOTHESES TASK_DECISION_LOG
    local TASK_SUBTASKS TASK_RELATED_FILES TASK_BLOCKERS TASK_TIMESTAMPS
    local TASK_NOTES TASK_CREATED
    task_read "$f" || continue
    [ -n "${TASK_ID:-}" ] || continue

    # Apply status filter
    if [ -n "$status_filter" ] && [ "$TASK_STATUS" != "$status_filter" ]; then
      continue
    fi

    # Skip terminal unless --all
    if [ "$show_all" -eq 0 ] && [ -z "$status_filter" ]; then
      case "$TASK_STATUS" in
        done|cancelled) continue ;;
      esac
    fi

    local age
    age="$(_task_age_str "$TASK_CREATED")"

    local line
    line=$(printf '#%s [%s] [%s] %s (%s)' \
      "$TASK_ID" "$TASK_STATUS" "$TASK_TYPE" "$TASK_TITLE" "$age")
    entries="${entries}${TASK_ID}|${line}"$'\n'
  done

  if [ -n "$entries" ]; then
    printf '%s' "$entries" | sort -t'|' -k1,1n | while IFS='|' read -r _ line; do
      echo "$line"
    done
  else
    echo "No tasks found."
  fi
}

# ── task_sync_runtime ─────────────────────────────────────────────────
# Copy active (non-terminal) task files from .doey/tasks/ to /tmp runtime cache.
# Args: project_dir runtime_dir
task_sync_runtime() {
  local project_dir="$1" runtime_dir="$2"
  local src="${project_dir}/.doey/tasks"
  local dst="${runtime_dir}/tasks"

  if [ ! -d "$src" ]; then
    return 0
  fi

  mkdir -p "$dst"

  local f line status
  for f in "${src}"/*.task; do
    [ -f "$f" ] || continue
    [ -s "$f" ] || continue  # skip empty files

    # Quick status check without full parse
    status=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "${line%%=*}" in
        TASK_STATUS) status="${line#*=}"; break ;;
      esac
    done < "$f" || true

    # Skip terminal tasks
    case "$status" in
      done|cancelled) continue ;;
    esac

    cp "$f" "$dst/"
  done

  # Sync .next_id
  if [ -f "${src}/.next_id" ]; then
    cp "${src}/.next_id" "${dst}/.next_id"
  fi
}

# ── task_add_decision ─────────────────────────────────────────────────
# Append timestamped entry to TASK_DECISION_LOG.
# Args: task_file entry_text
task_add_decision() {
  local now
  now=$(date +%s)
  _task_append_to_field "$1" "TASK_DECISION_LOG" "${now}:${2}"
}

# ── task_add_note ─────────────────────────────────────────────────────
# Append to TASK_NOTES. Args: task_file note_text
task_add_note() {
  _task_append_to_field "$1" "TASK_NOTES" "$2"
}

# ── task_update_subtask ───────────────────────────────────────────────
# Update a subtask's status.
# Args: task_file subtask_id new_status
# Subtask format: id:title:status separated by \n
task_update_subtask() {
  local task_file="$1" subtask_id="$2" new_status="$3"

  # Validate subtask status
  local valid=0 s
  for s in $_TASK_VALID_SUBTASK_STATUSES; do
    if [ "$s" = "$new_status" ]; then valid=1; break; fi
  done
  if [ "$valid" -eq 0 ]; then
    printf 'Error: invalid subtask status "%s" (valid: %s)\n' "$new_status" "$_TASK_VALID_SUBTASK_STATUSES" >&2
    return 1
  fi

  local current_subtasks
  current_subtasks="$(_task_read_field "$task_file" "TASK_SUBTASKS")"

  if [ -z "$current_subtasks" ]; then
    printf 'Error: no subtasks found in task\n' >&2
    return 1
  fi

  # Rebuild subtasks with updated status
  # Format: id:title:status\nid:title:status
  local updated="" found=0
  local remaining="$current_subtasks"
  while [ -n "$remaining" ]; do
    local entry
    case "$remaining" in
      *\\n*)
        entry="${remaining%%\\n*}"
        remaining="${remaining#*\\n}"
        ;;
      *)
        entry="$remaining"
        remaining=""
        ;;
    esac

    # Parse entry: id:title:status
    local eid etitle estatus
    eid="${entry%%:*}"
    local rest="${entry#*:}"
    etitle="${rest%:*}"
    estatus="${rest##*:}"

    if [ "$eid" = "$subtask_id" ]; then
      estatus="$new_status"
      found=1
    fi

    local rebuilt="${eid}:${etitle}:${estatus}"
    if [ -n "$updated" ]; then
      updated="${updated}\\n${rebuilt}"
    else
      updated="$rebuilt"
    fi
  done

  if [ "$found" -eq 0 ]; then
    printf 'Error: subtask %s not found\n' "$subtask_id" >&2
    return 1
  fi

  task_update_field "$task_file" "TASK_SUBTASKS" "$updated"
}

# ── task_add_subtask ──────────────────────────────────────────────────
# Add a new subtask. Auto-increments subtask ID.
# Args: task_file title
# Returns (echo): new subtask ID
task_add_subtask() {
  local task_file="$1" title="$2"

  local current_subtasks
  current_subtasks="$(_task_read_field "$task_file" "TASK_SUBTASKS")"

  local max_id=0
  if [ -n "$current_subtasks" ]; then
    local remaining="$current_subtasks"
    while [ -n "$remaining" ]; do
      local entry
      case "$remaining" in
        *\\n*)
          entry="${remaining%%\\n*}"
          remaining="${remaining#*\\n}"
          ;;
        *)
          entry="$remaining"
          remaining=""
          ;;
      esac
      local eid="${entry%%:*}"
      if [ "$eid" -gt "$max_id" ] 2>/dev/null; then
        max_id="$eid"
      fi
    done
  fi

  local new_id=$((max_id + 1))
  local new_entry="${new_id}:${title}:pending"

  if [ -n "$current_subtasks" ]; then
    current_subtasks="${current_subtasks}\\n${new_entry}"
  else
    current_subtasks="$new_entry"
  fi

  task_update_field "$task_file" "TASK_SUBTASKS" "$current_subtasks"
  echo "$new_id"
}

# ── task_add_related_file ─────────────────────────────────────────────
# Append file to TASK_RELATED_FILES (pipe-delimited, no duplicates).
# Args: task_file filepath
task_add_related_file() {
  local task_file="$1" filepath="$2"

  local current_files
  current_files="$(_task_read_field "$task_file" "TASK_RELATED_FILES")"

  # Check for duplicate
  if [ -n "$current_files" ]; then
    local remaining="$current_files"
    while [ -n "$remaining" ]; do
      local entry
      case "$remaining" in
        *\|*)
          entry="${remaining%%|*}"
          remaining="${remaining#*|}"
          ;;
        *)
          entry="$remaining"
          remaining=""
          ;;
      esac
      if [ "$entry" = "$filepath" ]; then
        return 0
      fi
    done
    current_files="${current_files}|${filepath}"
  else
    current_files="$filepath"
  fi

  task_update_field "$task_file" "TASK_RELATED_FILES" "$current_files"
}

# ── _json_escape ─────────────────────────────────────────────────────
# Escape a string for safe embedding in JSON. Bash 3.2 compatible.
# Args: string
# Returns (echo): escaped string (without surrounding quotes)
_json_escape() {
  printf '%s' "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g' \
    -e 's/	/\\t/g' \
    -e "$(printf 's/\r/\\\\r/g')" \
    -e 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//'
}

# ── _json_array_from_lines ───────────────────────────────────────────
# Convert a newline-separated string into a JSON array of strings.
# Args: items_string (literal \n as separator)
# Returns (echo): JSON array, e.g. ["a", "b"]
_json_array_from_lines() {
  local input="$1"
  if [ -z "$input" ]; then
    printf '[]'
    return
  fi
  # Split on literal \n sequences
  local remaining="$input" entry first=1
  printf '['
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *\\n*)
        entry="${remaining%%\\n*}"
        remaining="${remaining#*\\n}"
        ;;
      *)
        entry="$remaining"
        remaining=""
        ;;
    esac
    [ -z "$entry" ] && continue
    local escaped
    escaped="$(_json_escape "$entry")"
    if [ "$first" -eq 1 ]; then
      printf '"%s"' "$escaped"
      first=0
    else
      printf ', "%s"' "$escaped"
    fi
  done
  printf ']'
}

# ── _write_task_json (kept from v2) ──────────────────────────────────
# Write a minimal companion .json file. Used by upgrade and dispatch.
# Args: json_file task_id title task_type
_write_task_json() {
  local json_file="$1" task_id="$2" title="$3" task_type="$4"
  local tmp="${json_file}.tmp"
  local esc_title
  esc_title="$(_json_escape "$title")"
  printf '{\n  "schema_version": 3,\n  "task_id": %s,\n  "title": "%s",\n  "task_type": "%s",\n  "intent": "",\n  "hypotheses": [],\n  "constraints": [],\n  "success_criteria": [],\n  "deliverables": [],\n  "dispatch_plan": {}\n}\n' \
    "$task_id" "$esc_title" "$task_type" > "$tmp"
  mv "$tmp" "$json_file"
}

# ── task_write_json ──────────────────────────────────────────────────
# Create a rich companion .json file for a task from .task metadata and
# optional structured fields passed via environment variables.
# Args: project_dir task_id
# Env (optional):
#   INTENT            — string describing what the task aims to achieve
#   HYPOTHESES        — literal \n-separated list
#   CONSTRAINTS       — literal \n-separated list
#   SUCCESS_CRITERIA  — literal \n-separated list
#   DELIVERABLES      — literal \n-separated list
#   DISPATCH_MODE     — string (standard|phased|parallel|sequential)
#   DISPATCH_TEAM     — string (team type)
#   FORCE             — set to 1 to overwrite existing .json
# Returns: 0 on success, 1 on error
task_write_json() {
  local project_dir="$1" task_id="$2"

  local tasks_dir
  tasks_dir="$(task_dir "$project_dir")"
  local task_file="${tasks_dir}/${task_id}.task"
  local json_file="${tasks_dir}/${task_id}.json"

  if [ ! -f "$task_file" ]; then
    printf 'Error: task file not found: %s\n' "$task_file" >&2
    return 1
  fi

  # Don't overwrite unless FORCE=1
  if [ -f "$json_file" ] && [ "${FORCE:-0}" != "1" ]; then
    printf 'Warning: %s already exists (use FORCE=1 to overwrite)\n' "$json_file" >&2
    return 0
  fi

  # Read task metadata
  local title task_type
  title="$(_task_read_field "$task_file" "TASK_TITLE")"
  task_type="$(_task_read_field "$task_file" "TASK_TYPE")"

  # Escape strings for JSON
  local esc_title esc_intent esc_type
  esc_title="$(_json_escape "$title")"
  esc_type="$(_json_escape "${task_type:-feature}")"
  esc_intent="$(_json_escape "${INTENT:-}")"

  # Build arrays from literal \n-separated env vars
  local arr_hyp arr_con arr_crit arr_del
  arr_hyp="$(_json_array_from_lines "${HYPOTHESES:-}")"
  arr_con="$(_json_array_from_lines "${CONSTRAINTS:-}")"
  arr_crit="$(_json_array_from_lines "${SUCCESS_CRITERIA:-}")"
  arr_del="$(_json_array_from_lines "${DELIVERABLES:-}")"

  # Build dispatch_plan object
  local dispatch_json="{}"
  if [ -n "${DISPATCH_MODE:-}" ]; then
    local esc_mode esc_team
    esc_mode="$(_json_escape "$DISPATCH_MODE")"
    esc_team="$(_json_escape "${DISPATCH_TEAM:-}")"
    if [ -n "${DISPATCH_TEAM:-}" ]; then
      dispatch_json=$(printf '{"mode": "%s", "team_type": "%s"}' "$esc_mode" "$esc_team")
    else
      dispatch_json=$(printf '{"mode": "%s"}' "$esc_mode")
    fi
  fi

  # Write JSON with atomic tmp+mv
  local tmp="${json_file}.tmp"
  printf '{\n' > "$tmp"
  printf '  "schema_version": 3,\n' >> "$tmp"
  printf '  "task_id": %s,\n' "$task_id" >> "$tmp"
  printf '  "title": "%s",\n' "$esc_title" >> "$tmp"
  printf '  "task_type": "%s",\n' "$esc_type" >> "$tmp"
  printf '  "intent": "%s",\n' "$esc_intent" >> "$tmp"
  printf '  "hypotheses": %s,\n' "$arr_hyp" >> "$tmp"
  printf '  "constraints": %s,\n' "$arr_con" >> "$tmp"
  printf '  "success_criteria": %s,\n' "$arr_crit" >> "$tmp"
  printf '  "deliverables": %s,\n' "$arr_del" >> "$tmp"
  printf '  "dispatch_plan": %s\n' "$dispatch_json" >> "$tmp"
  printf '}\n' >> "$tmp"
  mv "$tmp" "$json_file"
}

# ── task_commit_msg ──────────────────────────────────────────────────
# Generate a conventional commit message from task metadata.
# Args: project_dir task_id
# Outputs: multi-line commit message to stdout
#   Line 1: <prefix>(task-<id>): <title>
#   Line 2: (blank, only if body follows)
#   Line 3+: first 1-2 sentences of description/summary
task_commit_msg() {
  local project_dir="$1" task_id="$2"

  local tasks_dir
  tasks_dir="$(task_dir "$project_dir")"
  local task_file="${tasks_dir}/${task_id}.task"

  # Fallback for missing or empty file
  if [ ! -f "$task_file" ] || [ ! -s "$task_file" ]; then
    printf 'chore(task-%s): task %s\n' "$task_id" "$task_id"
    return 0
  fi

  local title task_type description summary
  title="$(_task_read_field "$task_file" "TASK_TITLE")"
  task_type="$(_task_read_field "$task_file" "TASK_TYPE")"
  description="$(_task_read_field "$task_file" "TASK_DESCRIPTION")"
  summary="$(_task_read_field "$task_file" "TASK_SUMMARY")"

  # Fallback for empty title
  if [ -z "$title" ]; then
    title="task $task_id"
  fi

  # Map TASK_TYPE to conventional commit prefix
  local prefix
  case "${task_type:-}" in
    feature)                    prefix="feat" ;;
    fix|bugfix)                 prefix="fix" ;;
    refactor)                   prefix="refactor" ;;
    docs|research)              prefix="docs" ;;
    test)                       prefix="test" ;;
    infrastructure|maintenance) prefix="chore" ;;
    *)                          prefix="chore" ;;
  esac

  # Lowercase the title
  local lc_title
  lc_title="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"

  # Build subject line and truncate to ~72 chars
  local subject="${prefix}(task-${task_id}): ${lc_title}"
  if [ "${#subject}" -gt 72 ]; then
    subject="$(printf '%s' "$subject" | cut -c1-69)..."
  fi

  printf '%s\n' "$subject"

  # Body: prefer summary, fall back to description
  local body="${summary:-$description}"
  if [ -n "$body" ]; then
    # Unescape literal \n sequences to real newlines, take first 2 lines
    local short
    short="$(printf '%s' "$body" | sed 's/\\n/\n/g' | head -2 | head -c 200)"
    if [ -n "$short" ]; then
      printf '\n%s\n' "$short"
    fi
  fi
}

# ── task_upgrade_schema ───────────────────────────────────────────────
# Upgrade v1 or v2 .task files to v3 format. Idempotent.
# Args: task_file_path
task_upgrade_schema() {
  local file="$1"
  [ -f "$file" ] || { printf 'Error: file not found: %s\n' "$file" >&2; return 1; }
  [ -s "$file" ] || return 1

  # Read with task_read (handles all versions)
  local TASK_SCHEMA_VERSION TASK_ID TASK_TITLE TASK_STATUS TASK_TYPE
  local TASK_TAGS TASK_CREATED_BY TASK_ASSIGNED_TO TASK_DESCRIPTION
  local TASK_ACCEPTANCE_CRITERIA TASK_HYPOTHESES TASK_DECISION_LOG
  local TASK_SUBTASKS TASK_RELATED_FILES TASK_BLOCKERS TASK_TIMESTAMPS
  local TASK_NOTES TASK_CREATED
  task_read "$file"

  # Already v3 — nothing to do
  if [ "$TASK_SCHEMA_VERSION" = "3" ]; then
    return 0
  fi

  # Gather legacy fields that v1/v2 might have set via older parsers
  # Read raw for fields task_read doesn't know about (v2: TASK_OWNER, TASK_PRIORITY, TASK_SUMMARY, TASK_ATTACHMENTS)
  local legacy_owner="" legacy_priority="" legacy_summary="" legacy_attachments="" legacy_created_ts=""
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "${line%%=*}" in
      TASK_OWNER)    legacy_owner="${line#*=}" ;;
      TASK_PRIORITY) legacy_priority="${line#*=}" ;;
      TASK_SUMMARY)  legacy_summary="${line#*=}" ;;
      TASK_ATTACHMENTS) legacy_attachments="${line#*=}" ;;
      TASK_CREATED)  legacy_created_ts="${line#*=}" ;;
    esac
  done < "$file" || true

  # Map legacy fields to v3
  if [ -z "$TASK_CREATED_BY" ] && [ -n "$legacy_owner" ]; then
    TASK_CREATED_BY="$legacy_owner"
  fi
  if [ -z "$TASK_CREATED_BY" ]; then TASK_CREATED_BY="Boss"; fi
  if [ -z "$TASK_TYPE" ]; then TASK_TYPE="feature"; fi

  # Build TASK_TIMESTAMPS from legacy TASK_CREATED if missing
  if [ -z "$TASK_TIMESTAMPS" ]; then
    if [ -n "$legacy_created_ts" ]; then
      TASK_TIMESTAMPS="created=${legacy_created_ts}"
    elif [ -n "$TASK_CREATED" ]; then
      TASK_TIMESTAMPS="created=${TASK_CREATED}"
    else
      TASK_TIMESTAMPS="created=$(date +%s)"
    fi
  fi

  # Migrate attachments to notes if present
  if [ -n "$legacy_attachments" ] && [ -z "$TASK_NOTES" ]; then
    TASK_NOTES="Migrated attachments: ${legacy_attachments}"
  fi

  # Rewrite file with all v3 fields
  local tmp="${file}.tmp"
  printf 'TASK_SCHEMA_VERSION=%s\n' "$_TASK_SCHEMA_VERSION_CURRENT" > "$tmp"
  printf 'TASK_ID=%s\n' "$TASK_ID" >> "$tmp"
  printf 'TASK_TITLE=%s\n' "$TASK_TITLE" >> "$tmp"
  printf 'TASK_STATUS=%s\n' "$TASK_STATUS" >> "$tmp"
  printf 'TASK_TYPE=%s\n' "$TASK_TYPE" >> "$tmp"
  printf 'TASK_TAGS=%s\n' "${TASK_TAGS:-}" >> "$tmp"
  printf 'TASK_CREATED_BY=%s\n' "$TASK_CREATED_BY" >> "$tmp"
  printf 'TASK_ASSIGNED_TO=%s\n' "${TASK_ASSIGNED_TO:-}" >> "$tmp"
  printf 'TASK_DESCRIPTION=%s\n' "${TASK_DESCRIPTION:-}" >> "$tmp"
  printf 'TASK_ACCEPTANCE_CRITERIA=%s\n' "${TASK_ACCEPTANCE_CRITERIA:-}" >> "$tmp"
  printf 'TASK_HYPOTHESES=%s\n' "${TASK_HYPOTHESES:-}" >> "$tmp"
  printf 'TASK_DECISION_LOG=%s\n' "${TASK_DECISION_LOG:-}" >> "$tmp"
  printf 'TASK_SUBTASKS=%s\n' "${TASK_SUBTASKS:-}" >> "$tmp"
  printf 'TASK_RELATED_FILES=%s\n' "${TASK_RELATED_FILES:-}" >> "$tmp"
  printf 'TASK_BLOCKERS=%s\n' "${TASK_BLOCKERS:-}" >> "$tmp"
  printf 'TASK_TIMESTAMPS=%s\n' "$TASK_TIMESTAMPS" >> "$tmp"
  printf 'TASK_CURRENT_PHASE=%s\n' "${TASK_CURRENT_PHASE:-0}" >> "$tmp"
  printf 'TASK_TOTAL_PHASES=%s\n' "${TASK_TOTAL_PHASES:-0}" >> "$tmp"
  printf 'TASK_NOTES=%s\n' "${TASK_NOTES:-}" >> "$tmp"
  printf 'TASK_UPDATED=%s\n' "$(date +%s)" >> "$tmp"
  mv "$tmp" "$file"

  # Create companion .json if missing
  local json_file="${file%.task}.json"
  if [ ! -f "$json_file" ]; then
    _write_task_json "$json_file" "$TASK_ID" "$TASK_TITLE" "$TASK_TYPE"
  fi

  return 0
}

# ── task_dispatch_msg (kept from v2) ──────────────────────────────────
# Generate a dispatch_task message body for sending to Session Manager.
# Args: project_dir task_id [mode] [priority]
#   mode: parallel|sequential|phased (default: sequential)
#   priority: P0|P1|P2|P3 (default: P1)
# Output: message body string
task_dispatch_msg() {
  local project_dir="$1" task_id="$2"
  local mode="${3:-sequential}" priority="${4:-P1}"

  local tasks_dir
  tasks_dir="$(task_dir "$project_dir")"
  local task_file="${tasks_dir}/${task_id}.task"
  local json_file="${tasks_dir}/${task_id}.json"

  if [ ! -f "$task_file" ]; then
    printf 'Error: task file not found: %s\n' "$task_file" >&2
    return 1
  fi

  local title summary
  title="$(_task_read_field "$task_file" "TASK_TITLE")"
  summary="$(_task_read_field "$task_file" "TASK_DESCRIPTION")"

  printf 'FROM: Boss\nSUBJECT: dispatch_task\nTASK_ID=%s\nTASK_FILE=%s\nTASK_JSON=%s\nDISPATCH_MODE=%s\nPRIORITY=%s\nSUMMARY=%s\n' \
    "$task_id" "$task_file" "$json_file" "$mode" "$priority" "${summary:-$title}"
}

# ── task_update_phase ────────────────────────────────────────────────
# Update phase tracking fields on a task.
# Args: project_dir task_id current_phase total_phases
#   current_phase: 0 = not phased, 1+ = current phase number
#   total_phases:  0 = not phased, 1+ = total phase count
task_update_phase() {
  local project_dir="$1" task_id="$2" current="$3" total="$4"
  local task_file="${project_dir}/.doey/tasks/${task_id}.task"

  if [ ! -f "$task_file" ]; then
    printf 'Error: task %s not found\n' "$task_id" >&2
    return 1
  fi

  # Validate integers
  case "$current" in
    *[!0-9]*) printf 'Error: current_phase must be integer, got "%s"\n' "$current" >&2; return 1 ;;
  esac
  case "$total" in
    *[!0-9]*) printf 'Error: total_phases must be integer, got "%s"\n' "$total" >&2; return 1 ;;
  esac

  task_update_field "$task_file" "TASK_CURRENT_PHASE" "$current"
  task_update_field "$task_file" "TASK_TOTAL_PHASES" "$total"

  # Log phase change
  if [ "$total" -gt 0 ]; then
    task_add_decision "$task_file" "Phase ${current}/${total}"
  fi
}

# ── task_context_overlap ─────────────────────────────────────────────
# Score how relevant a worker's previous task context is to a new task.
# Args: last_tags last_type last_files new_tags new_type new_files
#   Tags: comma-separated. Files: pipe-delimited paths.
# Returns (echo): integer 0-100
task_context_overlap() {
  local last_tags="${1:-}" last_type="${2:-}" last_files="${3:-}"
  local new_tags="${4:-}" new_type="${5:-}" new_files="${6:-}"

  # ── Tag overlap (0-40 points) ──
  local tag_score=0
  if [ -n "$last_tags" ] && [ -n "$new_tags" ]; then
    local last_count=0 new_count=0 matches=0

    # Count last tags
    local remaining="$last_tags"
    local last_list=""
    while [ -n "$remaining" ]; do
      local entry
      case "$remaining" in
        *,*) entry="${remaining%%,*}"; remaining="${remaining#*,}" ;;
        *)   entry="$remaining"; remaining="" ;;
      esac
      entry="${entry## }"; entry="${entry%% }"
      [ -z "$entry" ] && continue
      last_list="${last_list}|${entry}|"
      last_count=$((last_count + 1))
    done

    # Count new tags and check matches
    remaining="$new_tags"
    while [ -n "$remaining" ]; do
      local entry
      case "$remaining" in
        *,*) entry="${remaining%%,*}"; remaining="${remaining#*,}" ;;
        *)   entry="$remaining"; remaining="" ;;
      esac
      entry="${entry## }"; entry="${entry%% }"
      [ -z "$entry" ] && continue
      new_count=$((new_count + 1))
      case "$last_list" in
        *"|${entry}|"*) matches=$((matches + 1)) ;;
      esac
    done

    local max_count="$last_count"
    [ "$new_count" -gt "$max_count" ] && max_count="$new_count"
    if [ "$max_count" -gt 0 ]; then
      tag_score=$(( matches * 40 / max_count ))
    fi
  fi

  # ── Type match (0-20 points) ──
  local type_score=0
  if [ -n "$last_type" ] && [ -n "$new_type" ] && [ "$last_type" = "$new_type" ]; then
    type_score=20
  fi

  # ── File path overlap (0-40 points) ──
  local file_score=0
  if [ -n "$last_files" ] && [ -n "$new_files" ]; then
    # Extract directory prefixes from last_files
    local last_dirs="" last_dir_count=0
    local remaining="$last_files"
    while [ -n "$remaining" ]; do
      local entry
      case "$remaining" in
        *\|*) entry="${remaining%%|*}"; remaining="${remaining#*|}" ;;
        *)    entry="$remaining"; remaining="" ;;
      esac
      [ -z "$entry" ] && continue
      local dir="${entry%/*}"
      [ "$dir" = "$entry" ] && dir="."
      last_dirs="${last_dirs}|${dir}|"
      last_dir_count=$((last_dir_count + 1))
    done

    # Check new file dirs against last dirs
    local new_dir_count=0 dir_matches=0
    remaining="$new_files"
    while [ -n "$remaining" ]; do
      local entry
      case "$remaining" in
        *\|*) entry="${remaining%%|*}"; remaining="${remaining#*|}" ;;
        *)    entry="$remaining"; remaining="" ;;
      esac
      [ -z "$entry" ] && continue
      local dir="${entry%/*}"
      [ "$dir" = "$entry" ] && dir="."
      new_dir_count=$((new_dir_count + 1))
      case "$last_dirs" in
        *"|${dir}|"*) dir_matches=$((dir_matches + 1)) ;;
      esac
    done

    local max_dir_count="$last_dir_count"
    [ "$new_dir_count" -gt "$max_dir_count" ] && max_dir_count="$new_dir_count"
    if [ "$max_dir_count" -gt 0 ]; then
      file_score=$(( dir_matches * 40 / max_dir_count ))
    fi
  fi

  echo $(( tag_score + type_score + file_score ))
}

# ── task_should_restart ──────────────────────────────────────────────
# Decide whether a worker should be restarted (fresh context) or delegated to
# (reuse existing context) based on task overlap.
# Args: last_tags last_type last_files new_tags new_type new_files
# Returns: exit 0 = should restart (low overlap), exit 1 = should delegate (high overlap)
task_should_restart() {
  local score
  score="$(task_context_overlap "$@")"
  [ "$score" -lt 30 ]
}

# ── _task_resolve_file ───────────────────────────────────────────────
# Resolve task file path from project_dir + task_id.
# Args: project_dir task_id
# Returns (echo): absolute path to .task file, or returns 1 if missing.
_task_resolve_file() {
  local project_dir="$1" task_id="$2"
  local task_file="${project_dir}/.doey/tasks/${task_id}.task"
  if [ ! -f "$task_file" ]; then
    printf 'Error: task %s not found\n' "$task_id" >&2
    return 1
  fi
  printf '%s' "$task_file"
}

# ── doey_task_get_subtask_count ──────────────────────────────────────
# Count TASK_SUBTASK_*_TITLE lines in a task file.
# Args: project_dir task_id
# Returns (echo): count (0 if missing/none)
doey_task_get_subtask_count() {
  local task_file
  task_file="$(_task_resolve_file "$1" "$2")" || { echo "0"; return 1; }
  local count=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      TASK_SUBTASK_*_TITLE=*) count=$((count + 1)) ;;
    esac
  done < "$task_file" || true
  echo "$count"
}

# ── doey_task_add_subtask ────────────────────────────────────────────
# Add a numbered subtask (TASK_SUBTASK_<N>_*) to a task file.
# Args: project_dir task_id title [assignee]
# Returns (echo): subtask number
doey_task_add_subtask() {
  local project_dir="$1" task_id="$2" title="$3"
  local assignee="${4:-}"

  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1

  local count
  count="$(doey_task_get_subtask_count "$project_dir" "$task_id")"
  local n=$((count + 1))

  printf 'TASK_SUBTASK_%s_TITLE=%s\n' "$n" "$title" >> "$task_file"
  printf 'TASK_SUBTASK_%s_STATUS=pending\n' "$n" >> "$task_file"
  if [ -n "$assignee" ]; then
    printf 'TASK_SUBTASK_%s_ASSIGNEE=%s\n' "$n" "$assignee" >> "$task_file"
  fi

  _touch_task_updated "$task_file"
  echo "$n"
}

# ── doey_task_update_subtask ─────────────────────────────────────────
# Update TASK_SUBTASK_<N>_STATUS in-place. Appends if missing.
# Args: project_dir task_id subtask_n status
doey_task_update_subtask() {
  local project_dir="$1" task_id="$2" subtask_n="$3" new_status="$4"

  # Validate subtask status
  local valid=0 s
  for s in $_TASK_VALID_SUBTASK_STATUSES; do
    if [ "$s" = "$new_status" ]; then valid=1; break; fi
  done
  if [ "$valid" -eq 0 ]; then
    printf 'Error: invalid subtask status "%s" (valid: %s)\n' "$new_status" "$_TASK_VALID_SUBTASK_STATUSES" >&2
    return 1
  fi

  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1

  local field="TASK_SUBTASK_${subtask_n}_STATUS"

  # Check if the field exists
  local found=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${field}="*) found=1; break ;;
    esac
  done < "$task_file" || true

  if [ "$found" -eq 1 ]; then
    task_update_field "$task_file" "$field" "$new_status"
  else
    printf '%s=%s\n' "$field" "$new_status" >> "$task_file"
    _touch_task_updated "$task_file"
  fi
}

# ── doey_task_add_update ─────────────────────────────────────────────
# Add a numbered update (TASK_UPDATE_<N>_*) to a task file.
# Args: project_dir task_id author text
# Returns (echo): update number
doey_task_add_update() {
  local project_dir="$1" task_id="$2" author="$3" text="$4"

  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1

  # Count existing updates
  local count=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      TASK_UPDATE_*_TIMESTAMP=*) count=$((count + 1)) ;;
    esac
  done < "$task_file" || true

  local n=$((count + 1))
  local now
  now=$(date +%s)

  printf 'TASK_UPDATE_%s_TIMESTAMP=%s\n' "$n" "$now" >> "$task_file"
  printf 'TASK_UPDATE_%s_AUTHOR=%s\n' "$n" "$author" >> "$task_file"
  printf 'TASK_UPDATE_%s_TEXT=%s\n' "$n" "$text" >> "$task_file"

  _touch_task_updated "$task_file"
  echo "$n"
}

# ── Reports ──────────────────────────────────────────────────────────

# ── task_add_report ─────────────────────────────────────────────────
# Add a numbered report (TASK_REPORT_<N>_*) to a task file.
# Args: task_file report_type title body [author]
# Report types: research, progress, decision, completion, error
# Returns (echo): report number
task_add_report() {
  local task_file="$1" report_type="$2" title="$3" body="$4" author="${5:-unknown}"

  [ ! -f "$task_file" ] && return 1

  # Count existing reports (bash 3.2 compatible loop, not grep -c)
  local count=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      TASK_REPORT_*_TIMESTAMP=*) count=$((count + 1)) ;;
    esac
  done < "$task_file" || true

  local n=$((count + 1))
  local ts
  ts=$(date +%s)

  printf 'TASK_REPORT_%s_TIMESTAMP=%s\n' "$n" "$ts" >> "$task_file"
  printf 'TASK_REPORT_%s_AUTHOR=%s\n' "$n" "$author" >> "$task_file"
  printf 'TASK_REPORT_%s_TYPE=%s\n' "$n" "$report_type" >> "$task_file"
  printf 'TASK_REPORT_%s_TITLE=%s\n' "$n" "$title" >> "$task_file"
  printf 'TASK_REPORT_%s_BODY=%s\n' "$n" "$body" >> "$task_file"

  _touch_task_updated "$task_file"
  echo "$n"
}

# ── doey_task_get_report_count ──────────────────────────────────────
# Count TASK_REPORT_*_TIMESTAMP lines in a task file.
# Args: project_dir task_id
# Returns (echo): count (0 if missing/none)
doey_task_get_report_count() {
  local project_dir="$1" task_id="$2"

  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || { echo "0"; return 1; }

  local count=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      TASK_REPORT_*_TIMESTAMP=*) count=$((count + 1)) ;;
    esac
  done < "$task_file" || true

  echo "$count"
}

# ── doey_task_add_report ────────────────────────────────────────────
# Add a numbered report (TASK_REPORT_<N>_*) to a task file.
# Wrapper around task_add_report() that resolves task file from project_dir + task_id.
# Args: project_dir task_id report_type title body [author]
# Returns (echo): report number
doey_task_add_report() {
  local project_dir="$1" task_id="$2" report_type="$3" title="$4" body="$5" author="${6:-unknown}"

  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1

  task_add_report "$task_file" "$report_type" "$title" "$body" "$author"
}

# ── Recovery Events ─────────────────────────────────────────────────

# ── task_add_recovery_event ─────────────────────────────────────────
# Add a numbered recovery event (TASK_RECOVERY_<N>_*) to a task file.
# Args: task_file event_type failed_agent new_agent description
# Event types: stale_detected, redispatched, rerouted, heartbeat_timeout, crash_recovery
# Returns (echo): recovery event number
task_add_recovery_event() {
  local task_file="$1" event_type="$2" failed_agent="$3" new_agent="$4" description="$5"

  [ ! -f "$task_file" ] && return 1

  # Count existing recovery events (bash 3.2 compatible loop, not grep -c)
  local count=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      TASK_RECOVERY_*_TIMESTAMP=*) count=$((count + 1)) ;;
    esac
  done < "$task_file" || true

  local n=$((count + 1))
  local ts
  ts=$(date +%s)

  printf 'TASK_RECOVERY_%s_TIMESTAMP=%s\n' "$n" "$ts" >> "$task_file"
  printf 'TASK_RECOVERY_%s_EVENT=%s\n' "$n" "$event_type" >> "$task_file"
  printf 'TASK_RECOVERY_%s_FAILED_AGENT=%s\n' "$n" "$failed_agent" >> "$task_file"
  printf 'TASK_RECOVERY_%s_NEW_AGENT=%s\n' "$n" "$new_agent" >> "$task_file"
  printf 'TASK_RECOVERY_%s_DESCRIPTION=%s\n' "$n" "$description" >> "$task_file"

  _touch_task_updated "$task_file"
  echo "$n"
}

# ── task_get_recovery_count ─────────────────────────────────────────
# Count TASK_RECOVERY_*_TIMESTAMP lines in a task file.
# Args: task_file
# Returns (echo): count (0 if missing/none)
task_get_recovery_count() {
  local task_file="$1"

  [ ! -f "$task_file" ] && { echo "0"; return 1; }

  local count=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      TASK_RECOVERY_*_TIMESTAMP=*) count=$((count + 1)) ;;
    esac
  done < "$task_file" || true

  echo "$count"
}

# ── doey_task_add_recovery_event ────────────────────────────────────
# Add a recovery event to a task file, resolving from project_dir + task_id.
# Args: project_dir task_id event_type failed_agent new_agent description
# Returns (echo): recovery event number
doey_task_add_recovery_event() {
  local project_dir="$1" task_id="$2"

  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1

  shift 2
  task_add_recovery_event "$task_file" "$@"
}
