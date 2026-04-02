#!/usr/bin/env bash
# doey-task-helpers.sh — Schema v3 persistent task management library
# Sourceable library, not standalone. Tasks stored in .doey/tasks/ (persistent).
# Exit codes: query functions return 0 always; mutation functions return 1 on error.
# Guard parallel Bash calls: bash -c 'source helpers.sh; func ... || true'
set -euo pipefail

# Source role definitions
_ROLES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=doey-roles.sh
source "${_ROLES_DIR}/doey-roles.sh" 2>/dev/null || true

HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true

_TASK_VALID_STATUSES="draft active in_progress paused blocked pending_user_confirmation done cancelled"
_TASK_VALID_TYPES="bug feature bugfix refactor research audit docs infrastructure"
_TASK_VALID_SUBTASK_STATUSES="pending in_progress done skipped failed"
_TASK_SCHEMA_VERSION_CURRENT="3"

# Styled output helpers (gum when available, plain fallback)
_task_err() {
  if [ "$HAS_GUM" = true ]; then gum style --foreground 1 --bold "$1" >&2
  else printf '%s\n' "$1" >&2; fi
}
_task_msg() {
  if [ "$HAS_GUM" = true ]; then gum style --foreground 8 "$1"
  else printf '%s\n' "$1"; fi
}

_count_field_lines() { # file pattern → count of matching lines
  local _cfl_f="$1" _cfl_p="$2" _cfl_n=0 _cfl_l
  [ -f "$_cfl_f" ] || { echo "0"; return 0; }
  while IFS= read -r _cfl_l || [ -n "$_cfl_l" ]; do
    case "$_cfl_l" in $_cfl_p) _cfl_n=$((_cfl_n + 1)) ;; esac
  done < "$_cfl_f" || true
  echo "$_cfl_n"
}

_touch_task_updated() { # task_file → upsert TASK_UPDATED=epoch
  local task_file="$1"
  [ -f "$task_file" ] || return 0
  local _ts; _ts=$(date +%s)
  if grep -q '^TASK_UPDATED=' "$task_file" 2>/dev/null; then
    sed -i '' "s/^TASK_UPDATED=.*/TASK_UPDATED=${_ts}/" "$task_file"
  else
    echo "TASK_UPDATED=${_ts}" >> "$task_file"
  fi
}

_write_v3_fields() { # output_file → write all v3 TASK_* fields from caller vars
  local _out="$1" _f _val
  printf 'TASK_SCHEMA_VERSION=%s\n' "$_TASK_SCHEMA_VERSION_CURRENT" > "$_out"
  for _f in ID TITLE STATUS TYPE TAGS CREATED_BY ASSIGNED_TO DESCRIPTION \
            ACCEPTANCE_CRITERIA HYPOTHESES DECISION_LOG SUBTASKS \
            RELATED_FILES BLOCKERS TIMESTAMPS CURRENT_PHASE TOTAL_PHASES \
            NOTES UPDATED; do
    eval "_val=\"\${TASK_${_f}:-}\""
    printf 'TASK_%s=%s\n' "$_f" "$_val"
  done >> "$_out"
}

task_dir() { # project_dir → echo .doey/tasks/ path (auto-creates)
  local project_dir="$1"
  local td="${project_dir}/.doey/tasks"
  mkdir -p "$td"
  echo "$td"
}

task_next_id() { # tasks_dir → echo next ID (auto-increments)
  local tasks_dir="$1"
  local counter_file="${tasks_dir}/.next_id"
  local id=1
  if [ -f "$counter_file" ]; then
    id=$(cat "$counter_file")
  fi
  echo "$((id + 1))" > "$counter_file"
  echo "$id"
}

task_create() { # project_dir title [type] [created_by] [description] → echo task ID
  # Fast path: use doey-ctl if available
  if command -v doey-ctl >/dev/null 2>&1; then
    local _result
    _result=$(doey-ctl task create --title "$2" --type "${3:-feature}" --created-by "${4:-Boss}" --description "${5:-}" --project-dir "$1" 2>/dev/null) && {
      echo "$_result"
      return 0
    }
  fi
  # Fallback: shell implementation continues below
  local project_dir="$1" title="$2"
  local task_type="${3:-feature}" created_by="${4:-Boss}" description="${5:-}"
  local tasks_dir; tasks_dir="$(task_dir "$project_dir")"
  local id; id="$(task_next_id "$tasks_dir")"
  local now; now=$(date +%s)
  local task_file="${tasks_dir}/${id}.task"

  TASK_ID="$id" TASK_TITLE="$title" TASK_STATUS="active" TASK_TYPE="$task_type"
  TASK_TAGS="" TASK_CREATED_BY="$created_by" TASK_ASSIGNED_TO=""
  TASK_DESCRIPTION="$description" TASK_ACCEPTANCE_CRITERIA="" TASK_HYPOTHESES=""
  TASK_DECISION_LOG="${now}:Created task" TASK_SUBTASKS="" TASK_RELATED_FILES=""
  TASK_BLOCKERS="" TASK_TIMESTAMPS="created=${now}" TASK_CURRENT_PHASE="0"
  TASK_TOTAL_PHASES="0" TASK_NOTES="" TASK_UPDATED="$now"

  _write_v3_fields "${task_file}.tmp"
  mv "${task_file}.tmp" "$task_file"
  echo "$id"
}

task_read() { # task_file → sets TASK_* vars; returns 1 if missing/malformed
  # TODO(phase3): migrate to doey-ctl db-task get (requires JSON→shell var mapping)
  local file="$1"
  [ -s "$file" ] || return 1

  TASK_SCHEMA_VERSION="" TASK_ID="" TASK_TITLE="" TASK_STATUS="" TASK_TYPE=""
  TASK_TAGS="" TASK_CREATED_BY="" TASK_ASSIGNED_TO="" TASK_DESCRIPTION=""
  TASK_ACCEPTANCE_CRITERIA="" TASK_HYPOTHESES="" TASK_DECISION_LOG=""
  TASK_SUBTASKS="" TASK_RELATED_FILES="" TASK_BLOCKERS="" TASK_TIMESTAMPS=""
  TASK_CURRENT_PHASE="" TASK_TOTAL_PHASES="" TASK_NOTES="" TASK_CREATED=""

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

  # Extract TASK_CREATED from TASK_TIMESTAMPS (format: created=epoch|started=epoch|...)
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
  : "${TASK_SCHEMA_VERSION:=1}" "${TASK_TYPE:=feature}" "${TASK_CREATED_BY:=Boss}"
  : "${TASK_CURRENT_PHASE:=0}" "${TASK_TOTAL_PHASES:=0}"
}

task_update_field() { # task_file field_name new_value → atomic upsert
  local task_file="$1" field_name="$2" new_value="$3"
  # Fast path: doey-ctl task update (field names map TASK_X → x)
  if command -v doey-ctl >/dev/null 2>&1; then
    local _id _pd _dbfield
    _id=$(basename "$task_file" .task)
    _pd=$(cd "$(dirname "$task_file")/../.." 2>/dev/null && pwd)
    # Map TASK_STATUS → status, TASK_TITLE → title, etc.
    _dbfield="${field_name#TASK_}"
    _dbfield=$(printf '%s' "$_dbfield" | tr '[:upper:]' '[:lower:]')
    doey-ctl task update "$_id" --field "$_dbfield" --value "$new_value" --project-dir "$_pd" 2>/dev/null && {
      _touch_task_updated "$task_file"; return 0
    }
  fi

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

_task_read_field() { # task_file field_name → echo field value
  local _trf_result="" _trf_line
  while IFS= read -r _trf_line || [ -n "$_trf_line" ]; do
    case "${_trf_line%%=*}" in
      "$2") _trf_result="${_trf_line#*=}" ;;
    esac
  done < "$1" || true
  printf '%s' "$_trf_result"
}

_task_append_to_field() { # task_file field new_value [separator=\\n]
  local current
  current="$(_task_read_field "$1" "$2")"
  if [ -n "$current" ]; then
    task_update_field "$1" "$2" "${current}${4:-\\n}${3}"
  else
    task_update_field "$1" "$2" "$3"
  fi
}

_task_validate_status() { # status → 0=valid, 1=invalid
  local s; for s in $_TASK_VALID_STATUSES; do [ "$s" = "$1" ] && return 0; done; return 1
}

_validate_subtask_status() { # status → 0=valid, 1=invalid (prints error)
  local s; for s in $_TASK_VALID_SUBTASK_STATUSES; do [ "$s" = "$1" ] && return 0; done
  _task_err "Error: invalid subtask status \"$1\" (valid: $_TASK_VALID_SUBTASK_STATUSES)"
  return 1
}

_task_status_timestamp_key() { # status → echo timestamp key
  case "$1" in
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

_task_append_timestamp() { # task_file key epoch
  _task_append_to_field "$1" "TASK_TIMESTAMPS" "${2}=${3}" "|"
}

task_update_status() { # project_dir task_id new_status
  # Fast path: use doey-ctl if available
  if command -v doey-ctl >/dev/null 2>&1; then
    doey-ctl task update "$2" --field TASK_STATUS --value "$3" --project-dir "$1" 2>/dev/null && return 0
  fi
  # Fallback: shell implementation continues below
  local project_dir="$1" task_id="$2" new_status="$3"

  if ! _task_validate_status "$new_status"; then
    _task_err "Error: invalid status \"${new_status}\" (valid: ${_TASK_VALID_STATUSES})"; return 1
  fi

  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1

  local now; now=$(date +%s)
  task_update_field "$task_file" "TASK_STATUS" "$new_status"
  _task_append_timestamp "$task_file" "$(_task_status_timestamp_key "$new_status")" "$now"
  task_add_decision "$task_file" "Status changed to ${new_status}"
}

_task_age_str() { # epoch → echo human-readable age (e.g., "3h")
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

task_list() { # TODO(phase3): migrate to doey-ctl db-task list (output format differs)
  # project_dir [--status filter] [--all]
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
  if [ ! -d "$tasks_dir" ]; then _task_msg "No tasks."; return 0; fi

  local entries="" f
  for f in "${tasks_dir}"/*.task; do
    [ -f "$f" ] || continue
    [ -s "$f" ] || continue
    local TASK_SCHEMA_VERSION TASK_ID TASK_TITLE TASK_STATUS TASK_TYPE TASK_TAGS
    local TASK_CREATED_BY TASK_ASSIGNED_TO TASK_DESCRIPTION TASK_ACCEPTANCE_CRITERIA
    local TASK_HYPOTHESES TASK_DECISION_LOG TASK_SUBTASKS TASK_RELATED_FILES
    local TASK_BLOCKERS TASK_TIMESTAMPS TASK_NOTES TASK_CREATED
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
    if [ "$HAS_GUM" = true ]; then
      local _st_icon _st_fg
      case "$TASK_STATUS" in
        active|in_progress) _st_icon="●"; _st_fg="3" ;;
        blocked)            _st_icon="■"; _st_fg="1" ;;
        paused)             _st_icon="◆"; _st_fg="5" ;;
        pending_*)          _st_icon="⬤"; _st_fg="6" ;;
        done)               _st_icon="✓"; _st_fg="2" ;;
        cancelled)          _st_icon="✗"; _st_fg="8" ;;
        *)                  _st_icon="○"; _st_fg="8" ;;
      esac
      local _styled_st _styled_meta
      _styled_st="$(gum style --foreground "$_st_fg" "${_st_icon}")"
      _styled_meta="$(gum style --foreground 8 "[${TASK_TYPE}] (${age})")"
      line=$(printf '%s #%s [%s] %s %s' "$_styled_st" "$TASK_ID" "$TASK_STATUS" "$TASK_TITLE" "$_styled_meta")
    else
      line=$(printf '#%s [%s] [%s] %s (%s)' \
        "$TASK_ID" "$TASK_STATUS" "$TASK_TYPE" "$TASK_TITLE" "$age")
    fi
    entries="${entries}${TASK_ID}|${line}"$'\n'
  done

  if [ -n "$entries" ]; then
    printf '%s' "$entries" | sort -t'|' -k1,1n | while IFS='|' read -r _ line; do
      printf '%s\n' "$line"
    done
  else
    _task_msg "No tasks found."
  fi
}

task_sync_runtime() { # TODO(phase3): migrate to doey-ctl when available
  # project_dir runtime_dir → copy active tasks to runtime cache
  local project_dir="$1" runtime_dir="$2"
  local src="${project_dir}/.doey/tasks" dst="${runtime_dir}/tasks"
  [ -d "$src" ] || return 0
  mkdir -p "$dst"

  local f line status
  for f in "${src}"/*.task; do
    [ -f "$f" ] || continue
    [ -s "$f" ] || continue
    status=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "${line%%=*}" in TASK_STATUS) status="${line#*=}"; break ;; esac
    done < "$f" || true
    case "$status" in done|cancelled) continue ;; esac
    cp "$f" "$dst/"
  done
  [ -f "${src}/.next_id" ] && cp "${src}/.next_id" "${dst}/.next_id"
}

task_add_decision() { # task_file entry_text → append timestamped decision
  if command -v doey-ctl >/dev/null 2>&1; then
    local _id _pd
    _id=$(basename "$1" .task)
    _pd=$(cd "$(dirname "$1")/../.." 2>/dev/null && pwd)
    doey-ctl task log add "$_id" --type decision --author "${DOEY_ROLE:-unknown}" --title "$2" --project-dir "$_pd" 2>/dev/null && return 0
  fi
  local now; now=$(date +%s); _task_append_to_field "$1" "TASK_DECISION_LOG" "${now}:${2}"
}

task_add_note() { # task_file note_text
  if command -v doey-ctl >/dev/null 2>&1; then
    local _id _pd
    _id=$(basename "$1" .task)
    _pd=$(cd "$(dirname "$1")/../.." 2>/dev/null && pwd)
    doey-ctl task log add "$_id" --type note --author "${DOEY_ROLE:-unknown}" --title "$2" --project-dir "$_pd" 2>/dev/null && return 0
  fi
  _task_append_to_field "$1" "TASK_NOTES" "$2"
}

task_update_subtask() { # task_file subtask_id new_status (format: id:title:status\\n...)
  local task_file="$1" subtask_id="$2" new_status="$3"
  # Fast path: doey-ctl task subtask update
  if command -v doey-ctl >/dev/null 2>&1; then
    local _pd
    _pd=$(cd "$(dirname "$task_file")/../.." 2>/dev/null && pwd)
    doey-ctl task subtask update "$subtask_id" --status "$new_status" --project-dir "$_pd" 2>/dev/null && return 0
  fi

  _validate_subtask_status "$new_status" || return 1

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

task_add_subtask() { # task_file title → echo new subtask ID
  # Fast path: use doey-ctl if available
  if command -v doey-ctl >/dev/null 2>&1; then
    local _task_id _project_dir _result
    _task_id=$(basename "$1" .task)
    _project_dir=$(cd "$(dirname "$1")/../.." && pwd)
    _result=$(doey-ctl task subtask add "$_task_id" "$2" --project-dir "$_project_dir" 2>/dev/null) && {
      echo "$_result"
      return 0
    }
  fi
  # Fallback: shell implementation continues below
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

task_add_related_file() { # task_file filepath (pipe-delimited, no dupes)
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

_json_escape() { # string → echo JSON-safe escaped string
  printf '%s' "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g' \
    -e 's/	/\\t/g' \
    -e "$(printf 's/\r/\\\\r/g')" \
    -e 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//'
}

_json_array_from_lines() { # items_string (literal \\n sep) → echo JSON array
  local input="$1"
  if [ -z "$input" ]; then printf '[]'; return; fi
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

_write_task_json() { # json_file task_id title task_type → write minimal .json
  local json_file="$1" task_id="$2" title="$3" task_type="$4"
  local tmp="${json_file}.tmp"
  local esc_title
  esc_title="$(_json_escape "$title")"
  printf '{\n  "schema_version": 3,\n  "task_id": %s,\n  "title": "%s",\n  "task_type": "%s",\n  "intent": "",\n  "hypotheses": [],\n  "constraints": [],\n  "success_criteria": [],\n  "deliverables": [],\n  "dispatch_plan": {}\n}\n' \
    "$task_id" "$esc_title" "$task_type" > "$tmp"
  mv "$tmp" "$json_file"
}

task_write_json() { # project_dir task_id; env: INTENT HYPOTHESES CONSTRAINTS SUCCESS_CRITERIA DELIVERABLES DISPATCH_MODE DISPATCH_TEAM FORCE
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
  printf '{\n  "schema_version": 3,\n  "task_id": %s,\n  "title": "%s",\n  "task_type": "%s",\n  "intent": "%s",\n  "hypotheses": %s,\n  "constraints": %s,\n  "success_criteria": %s,\n  "deliverables": %s,\n  "dispatch_plan": %s\n}\n' \
    "$task_id" "$esc_title" "$esc_type" "$esc_intent" "$arr_hyp" "$arr_con" "$arr_crit" "$arr_del" "$dispatch_json" > "$tmp"
  mv "$tmp" "$json_file"
}

task_commit_msg() { # project_dir task_id → echo conventional commit message
  local project_dir="$1" task_id="$2"
  local task_file="${project_dir}/.doey/tasks/${task_id}.task"

  if [ ! -f "$task_file" ] || [ ! -s "$task_file" ]; then
    printf 'chore(task-%s): task %s\n' "$task_id" "$task_id"; return 0
  fi

  local title task_type description summary
  title="$(_task_read_field "$task_file" "TASK_TITLE")"
  task_type="$(_task_read_field "$task_file" "TASK_TYPE")"
  description="$(_task_read_field "$task_file" "TASK_DESCRIPTION")"
  summary="$(_task_read_field "$task_file" "TASK_SUMMARY")"
  : "${title:=task $task_id}"

  local prefix
  case "${task_type:-}" in
    feature) prefix="feat" ;; fix|bugfix) prefix="fix" ;; refactor) prefix="refactor" ;;
    docs|research) prefix="docs" ;; test) prefix="test" ;; *) prefix="chore" ;;
  esac

  local lc_title; lc_title="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
  local subject="${prefix}(task-${task_id}): ${lc_title}"
  [ "${#subject}" -gt 72 ] && subject="$(printf '%s' "$subject" | cut -c1-69)..."
  printf '%s\n' "$subject"

  local body="${summary:-$description}"
  if [ -n "$body" ]; then
    local short; short="$(printf '%s' "$body" | sed 's/\\n/\n/g' | head -2 | head -c 200)"
    [ -n "$short" ] && printf '\n%s\n' "$short"
  fi
}

task_upgrade_schema() { # task_file → upgrade v1/v2 to v3 (idempotent)
  local file="$1"
  [ -f "$file" ] || { printf 'Error: file not found: %s\n' "$file" >&2; return 1; }
  [ -s "$file" ] || return 1

  local TASK_SCHEMA_VERSION TASK_ID TASK_TITLE TASK_STATUS TASK_TYPE TASK_TAGS
  local TASK_CREATED_BY TASK_ASSIGNED_TO TASK_DESCRIPTION TASK_ACCEPTANCE_CRITERIA
  local TASK_HYPOTHESES TASK_DECISION_LOG TASK_SUBTASKS TASK_RELATED_FILES
  local TASK_BLOCKERS TASK_TIMESTAMPS TASK_NOTES TASK_CREATED
  task_read "$file"
  [ "$TASK_SCHEMA_VERSION" = "3" ] && return 0

  # Read legacy fields that task_read doesn't know about
  local legacy_owner="" legacy_priority="" legacy_summary="" legacy_attachments="" legacy_created_ts=""
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "${line%%=*}" in
      TASK_OWNER) legacy_owner="${line#*=}" ;; TASK_PRIORITY) legacy_priority="${line#*=}" ;;
      TASK_SUMMARY) legacy_summary="${line#*=}" ;; TASK_ATTACHMENTS) legacy_attachments="${line#*=}" ;;
      TASK_CREATED) legacy_created_ts="${line#*=}" ;;
    esac
  done < "$file" || true

  [ -z "$TASK_CREATED_BY" ] && [ -n "$legacy_owner" ] && TASK_CREATED_BY="$legacy_owner"
  : "${TASK_CREATED_BY:=Boss}" "${TASK_TYPE:=feature}"

  if [ -z "$TASK_TIMESTAMPS" ]; then
    if [ -n "$legacy_created_ts" ]; then TASK_TIMESTAMPS="created=${legacy_created_ts}"
    elif [ -n "$TASK_CREATED" ]; then TASK_TIMESTAMPS="created=${TASK_CREATED}"
    else TASK_TIMESTAMPS="created=$(date +%s)"; fi
  fi

  [ -n "$legacy_attachments" ] && [ -z "$TASK_NOTES" ] && TASK_NOTES="Migrated attachments: ${legacy_attachments}"

  TASK_UPDATED="$(date +%s)"
  local tmp="${file}.tmp"
  _write_v3_fields "$tmp"

  # Preserve extension fields (TASK_REPORT_*, TASK_SUBTASK_N_*, etc.)
  while IFS= read -r line || [ -n "$line" ]; do
    case "${line%%=*}" in
      TASK_SCHEMA_VERSION|TASK_ID|TASK_TITLE|TASK_STATUS|TASK_TYPE|\
      TASK_TAGS|TASK_CREATED_BY|TASK_ASSIGNED_TO|TASK_DESCRIPTION|\
      TASK_ACCEPTANCE_CRITERIA|TASK_HYPOTHESES|TASK_DECISION_LOG|\
      TASK_SUBTASKS|TASK_RELATED_FILES|TASK_BLOCKERS|TASK_TIMESTAMPS|\
      TASK_CURRENT_PHASE|TASK_TOTAL_PHASES|TASK_NOTES|TASK_UPDATED)
        ;; # already written above — skip
      TASK_OWNER|TASK_PRIORITY|TASK_CREATED) ;; # legacy — drop
      TASK_*) printf '%s\n' "$line" ;; # preserve extension fields
    esac
  done < "$file" >> "$tmp"
  mv "$tmp" "$file"

  local json_file="${file%.task}.json"
  [ ! -f "$json_file" ] && _write_task_json "$json_file" "$TASK_ID" "$TASK_TITLE" "$TASK_TYPE"
}

task_dispatch_msg() { # project_dir task_id [mode] [priority] → echo dispatch message
  local project_dir="$1" task_id="$2"
  local mode="${3:-sequential}" priority="${4:-P1}"

  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1
  local json_file="${task_file%.task}.json"

  local title summary
  title="$(_task_read_field "$task_file" "TASK_TITLE")"
  summary="$(_task_read_field "$task_file" "TASK_DESCRIPTION")"

  printf 'FROM: %s\nSUBJECT: dispatch_task\nTASK_ID=%s\nTASK_FILE=%s\nTASK_JSON=%s\nDISPATCH_MODE=%s\nPRIORITY=%s\nSUMMARY=%s\n' \
    "${DOEY_ROLE_BOSS}" \
    "$task_id" "$task_file" "$json_file" "$mode" "$priority" "${summary:-$title}"
}

task_update_phase() { # project_dir task_id current_phase total_phases
  local project_dir="$1" task_id="$2" current="$3" total="$4"
  local task_file
  task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1
  case "$current" in *[!0-9]*) _task_err "Error: current_phase must be integer, got \"$current\""; return 1 ;; esac
  case "$total" in *[!0-9]*) _task_err "Error: total_phases must be integer, got \"$total\""; return 1 ;; esac
  task_update_field "$task_file" "TASK_CURRENT_PHASE" "$current"
  task_update_field "$task_file" "TASK_TOTAL_PHASES" "$total"
  [ "$total" -gt 0 ] && task_add_decision "$task_file" "Phase ${current}/${total}"
}

_list_overlap_score() { # list_a list_b delim max_points [use_dirs] → echo 0-max_points
  local list_a="$1" list_b="$2" delim="$3" max_points="$4" use_dirs="${5:-0}"
  if [ -z "$list_a" ] || [ -z "$list_b" ]; then echo 0; return; fi
  local items="" count_a=0 count_b=0 matches=0 remaining entry val

  # Build lookup from list A
  remaining="$list_a"
  while [ -n "$remaining" ]; do
    if [ "${remaining#*$delim}" != "$remaining" ]; then
      entry="${remaining%%$delim*}"; remaining="${remaining#*$delim}"
    else entry="$remaining"; remaining=""; fi
    entry="${entry## }"; entry="${entry%% }"
    [ -z "$entry" ] && continue
    if [ "$use_dirs" = "1" ]; then val="${entry%/*}"; [ "$val" = "$entry" ] && val="."; else val="$entry"; fi
    items="${items}|${val}|"; count_a=$((count_a + 1))
  done

  # Count matches from list B
  remaining="$list_b"
  while [ -n "$remaining" ]; do
    if [ "${remaining#*$delim}" != "$remaining" ]; then
      entry="${remaining%%$delim*}"; remaining="${remaining#*$delim}"
    else entry="$remaining"; remaining=""; fi
    entry="${entry## }"; entry="${entry%% }"
    [ -z "$entry" ] && continue
    if [ "$use_dirs" = "1" ]; then val="${entry%/*}"; [ "$val" = "$entry" ] && val="."; else val="$entry"; fi
    count_b=$((count_b + 1))
    case "$items" in *"|${val}|"*) matches=$((matches + 1)) ;; esac
  done

  local max_count="$count_a"
  [ "$count_b" -gt "$max_count" ] && max_count="$count_b"
  [ "$max_count" -gt 0 ] && echo $(( matches * max_points / max_count )) || echo 0
}

task_context_overlap() { # last_tags last_type last_files new_tags new_type new_files → echo 0-100
  local last_tags="${1:-}" last_type="${2:-}" last_files="${3:-}"
  local new_tags="${4:-}" new_type="${5:-}" new_files="${6:-}"

  local tag_score; tag_score=$(_list_overlap_score "$last_tags" "$new_tags" "," 40)

  local type_score=0
  [ -n "$last_type" ] && [ -n "$new_type" ] && [ "$last_type" = "$new_type" ] && type_score=20

  local file_score; file_score=$(_list_overlap_score "$last_files" "$new_files" "|" 40 1)

  echo $(( tag_score + type_score + file_score ))
}

task_should_restart() { # same args as task_context_overlap; exit 0=restart, 1=delegate
  local score
  score="$(task_context_overlap "$@")"
  [ "$score" -lt 30 ]
}

_task_resolve_file() { # project_dir task_id → echo .task path (returns 1 if missing)
  local task_file="${1}/.doey/tasks/${2}.task"
  if [ ! -f "$task_file" ]; then _task_err "Error: task ${2} not found"; return 1; fi
  printf '%s' "$task_file"
}

doey_task_get_subtask_count() { # project_dir task_id → echo count (0 if none)
  local task_file
  task_file="$(_task_resolve_file "$1" "$2")" || { echo "0"; return 0; }
  _count_field_lines "$task_file" "TASK_SUBTASK_*_TITLE=*"
}

doey_task_add_subtask() { # project_dir task_id title [assignee] [worker_pane] → echo subtask N
  local project_dir="$1" task_id="$2" title="$3"
  local assignee="${4:-}" worker_pane="${5:-}"
  local task_file; task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1
  local n; n=$(($(doey_task_get_subtask_count "$project_dir" "$task_id") + 1))

  printf 'TASK_SUBTASK_%s_TITLE=%s\n' "$n" "$title" >> "$task_file"
  printf 'TASK_SUBTASK_%s_STATUS=pending\n' "$n" >> "$task_file"
  [ -n "$assignee" ] && printf 'TASK_SUBTASK_%s_ASSIGNEE=%s\n' "$n" "$assignee" >> "$task_file"
  [ -n "$worker_pane" ] && printf 'TASK_SUBTASK_%s_WORKER=%s\n' "$n" "$worker_pane" >> "$task_file"
  printf 'TASK_SUBTASK_%s_CREATED_AT=%s\n' "$n" "$(date +%s)" >> "$task_file"
  _touch_task_updated "$task_file"
  echo "$n"
}

doey_task_update_subtask() { # project_dir task_id subtask_n status
  local project_dir="$1" task_id="$2" subtask_n="$3" new_status="$4"
  _validate_subtask_status "$new_status" || return 1
  local task_file; task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1
  task_update_field "$task_file" "TASK_SUBTASK_${subtask_n}_STATUS" "$new_status"
  case "$new_status" in done|failed) task_update_field "$task_file" "TASK_SUBTASK_${subtask_n}_COMPLETED_AT" "$(date +%s)" ;; esac
}

doey_task_add_update() { # project_dir task_id author text → echo update N
  local project_dir="$1" task_id="$2" author="$3" text="$4"
  local task_file; task_file="$(_task_resolve_file "$project_dir" "$task_id")" || return 1
  local count; count=$(_count_field_lines "$task_file" "TASK_UPDATE_*_TIMESTAMP=*")
  local n=$((count + 1)) now; now=$(date +%s)

  printf 'TASK_UPDATE_%s_TIMESTAMP=%s\n' "$n" "$now" >> "$task_file"
  printf 'TASK_UPDATE_%s_AUTHOR=%s\n' "$n" "$author" >> "$task_file"
  printf 'TASK_UPDATE_%s_TEXT=%s\n' "$n" "$text" >> "$task_file"

  _touch_task_updated "$task_file"
  echo "$n"
}

task_add_report() { # task_file report_type title body [author] → echo report N
  local task_file="$1" report_type="$2" title="$3" body="$4" author="${5:-unknown}"
  # Fast path: doey-ctl task log add --type report
  if command -v doey-ctl >/dev/null 2>&1; then
    local _id _pd
    _id=$(basename "$task_file" .task)
    _pd=$(cd "$(dirname "$task_file")/../.." 2>/dev/null && pwd)
    doey-ctl task log add "$_id" --type "report:${report_type}" --author "$author" --title "$title" --body "$body" --project-dir "$_pd" 2>/dev/null && return 0
  fi
  [ ! -f "$task_file" ] && return 1
  local n; n=$(($(_count_field_lines "$task_file" "TASK_REPORT_*_TIMESTAMP=*") + 1))
  local ts; ts=$(date +%s)
  printf 'TASK_REPORT_%s_TIMESTAMP=%s\nTASK_REPORT_%s_AUTHOR=%s\nTASK_REPORT_%s_TYPE=%s\nTASK_REPORT_%s_TITLE=%s\nTASK_REPORT_%s_BODY=%s\n' \
    "$n" "$ts" "$n" "$author" "$n" "$report_type" "$n" "$title" "$n" "$body" >> "$task_file"
  _touch_task_updated "$task_file"; echo "$n"
}

doey_task_get_report_count() { # project_dir task_id → echo count
  local task_file; task_file="$(_task_resolve_file "$1" "$2")" || { echo "0"; return 0; }
  _count_field_lines "$task_file" "TASK_REPORT_*_TIMESTAMP=*"
}

doey_task_add_report() { # project_dir task_id report_type title body [author] → echo report N
  local task_file; task_file="$(_task_resolve_file "$1" "$2")" || return 1
  task_add_report "$task_file" "$3" "$4" "$5" "${6:-unknown}"
}

task_add_recovery_event() { # task_file event_type failed_agent new_agent description → echo N
  local task_file="$1" event_type="$2" failed_agent="$3" new_agent="$4" description="$5"
  # Fast path: doey-ctl task log add --type recovery
  if command -v doey-ctl >/dev/null 2>&1; then
    local _id _pd
    _id=$(basename "$task_file" .task)
    _pd=$(cd "$(dirname "$task_file")/../.." 2>/dev/null && pwd)
    doey-ctl task log add "$_id" --type "recovery:${event_type}" --author "$failed_agent" --title "recovery → ${new_agent}" --body "$description" --project-dir "$_pd" 2>/dev/null && return 0
  fi
  [ ! -f "$task_file" ] && return 1
  local n; n=$(($(_count_field_lines "$task_file" "TASK_RECOVERY_*_TIMESTAMP=*") + 1))
  local ts; ts=$(date +%s)
  printf 'TASK_RECOVERY_%s_TIMESTAMP=%s\nTASK_RECOVERY_%s_EVENT=%s\nTASK_RECOVERY_%s_FAILED_AGENT=%s\nTASK_RECOVERY_%s_NEW_AGENT=%s\nTASK_RECOVERY_%s_DESCRIPTION=%s\n' \
    "$n" "$ts" "$n" "$event_type" "$n" "$failed_agent" "$n" "$new_agent" "$n" "$description" >> "$task_file"
  _touch_task_updated "$task_file"; echo "$n"
}

task_get_recovery_count() { _count_field_lines "${1:?}" "TASK_RECOVERY_*_TIMESTAMP=*"; }

doey_task_add_recovery_event() { # project_dir task_id event_type failed_agent new_agent desc
  local task_file; task_file="$(_task_resolve_file "$1" "$2")" || return 1
  shift 2; task_add_recovery_event "$task_file" "$@"
}

task_attachment_dir() { # project_dir task_id → echo attachments path (auto-creates)
  local dir="${1}/.doey/tasks/${2}/attachments"; mkdir -p "$dir"; echo "$dir"
}

task_write_attachment() { # project_dir task_id type title body author → echo filepath
  local project_dir="$1" task_id="$2" report_type="$3" title="$4" body="$5" author="$6"
  local dir; dir=$(task_attachment_dir "$project_dir" "$task_id")
  local ts; ts=$(date +%s)
  local author_safe; author_safe=$(echo "$author" | tr ' /:.' '_')
  local filepath="${dir}/${ts}_${report_type}_${author_safe}.md"
  cat > "$filepath" << ATTACHMENT_EOF
---
type: ${report_type}
title: ${title}
author: ${author}
timestamp: ${ts}
task_id: ${task_id}
---

${body}
ATTACHMENT_EOF
  local task_file="${project_dir}/.doey/tasks/${task_id}.task"
  [ -f "$task_file" ] && _touch_task_updated "$task_file"
  echo "$filepath"
}

task_list_attachments() { # project_dir task_id → echo filepaths (newest first)
  local dir="${1}/.doey/tasks/${2}/attachments"
  [ -d "$dir" ] || return 0
  ls -1 "$dir"/*.md 2>/dev/null | sort -r
}

_tokenize() { # text stop_words → sets _TKN_KEYS and _TKN_COUNT in caller
  local lower; lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ')
  local stops="$2"
  _TKN_KEYS="" _TKN_COUNT=0
  local remaining="$lower" word
  while [ -n "$remaining" ]; do
    remaining="${remaining## }"
    [ -z "$remaining" ] && break
    case "$remaining" in
      *" "*) word="${remaining%% *}"; remaining="${remaining#* }" ;;
      *)     word="$remaining"; remaining="" ;;
    esac
    [ -z "$word" ] && continue
    case "$stops" in *"|${word}|"*) continue ;; esac
    case "$_TKN_KEYS" in *"|${word}|"*) continue ;; esac
    _TKN_KEYS="${_TKN_KEYS}|${word}|"
    _TKN_COUNT=$((_TKN_COUNT + 1))
  done
}

task_find_similar() { # project_dir title_string → echo matching TASK_ID or empty
  local project_dir="$1" title_string="$2"
  local tasks_dir="${project_dir}/.doey/tasks"
  [ -d "$tasks_dir" ] || return 0

  local stop_words="|the|a|an|and|or|in|on|at|to|for|of|is|it|fix|add|update|"

  _tokenize "$title_string" "$stop_words"
  local input_keys="$_TKN_KEYS" input_count="$_TKN_COUNT"
  [ "$input_count" -eq 0 ] && return 0

  local f
  for f in "${tasks_dir}"/*.task; do
    [ -f "$f" ] || continue
    [ -s "$f" ] || continue

    local _fs_status="" _fs_title="" _fs_tags="" _fs_id="" _fs_line
    while IFS= read -r _fs_line || [ -n "$_fs_line" ]; do
      case "${_fs_line%%=*}" in
        TASK_STATUS) _fs_status="${_fs_line#*=}" ;;
        TASK_TITLE)  _fs_title="${_fs_line#*=}" ;;
        TASK_TAGS)   _fs_tags="${_fs_line#*=}" ;;
        TASK_ID)     _fs_id="${_fs_line#*=}" ;;
      esac
    done < "$f" || true

    [ -n "$_fs_id" ] || continue
    case "$_fs_status" in done|cancelled|pending_user_confirmation) continue ;; esac

    _tokenize "$(printf '%s %s' "$_fs_title" "$_fs_tags")" "$stop_words"
    [ "$_TKN_COUNT" -eq 0 ] && continue

    local matches=0 unique_total="$input_count" remaining="$_TKN_KEYS"
    while [ -n "$remaining" ]; do
      remaining="${remaining#|}"
      [ -z "$remaining" ] && break
      local word="${remaining%%|*}"
      remaining="${remaining#*|}"
      [ -z "$word" ] && continue
      case "$input_keys" in
        *"|${word}|"*) matches=$((matches + 1)) ;;
        *)             unique_total=$((unique_total + 1)) ;;
      esac
    done

    [ "$unique_total" -gt 0 ] && [ $((matches * 100 / unique_total)) -ge 50 ] && {
      printf '%s' "$_fs_id"; return 0
    }
  done
  return 0
}

task_find_or_create() { # project_dir title [type] [owner] → echo task ID
  local project_dir="$1" title="$2"
  local task_type="${3:-feature}" owner="${4:-Boss}"
  local existing_id
  if existing_id="$(task_find_similar "$project_dir" "$title")" && [ -n "$existing_id" ]; then
    printf '%s' "$existing_id"; return 0
  fi
  task_create "$project_dir" "$title" "$task_type" "$owner"
}

doey_task_write_attachment() { task_write_attachment "$@"; } # convenience wrapper
