#!/usr/bin/env bash
# doey-task-cli.sh — Task CLI dispatch functions extracted from doey.sh.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_task_cli_sourced:-}" = "1" ] && return 0
__doey_task_cli_sourced=1

# ── Dependencies ────────────────────────────────────────────────────
# shellcheck source=doey-helpers.sh
_doey_task_cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_doey_task_cli_dir}/doey-helpers.sh"
# shellcheck source=doey-ui.sh
source "${_doey_task_cli_dir}/doey-ui.sh"

# ── Task Helpers (lazy-loaded) ──────────────────────────────────────
# Delegates to doey-task-helpers.sh for core CRUD operations.

_task_helpers_sourced=0
_task_source_helpers() {
  [ "$_task_helpers_sourced" -eq 1 ] && return 0
  local _helpers_path
  _helpers_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/doey-task-helpers.sh"
  if [ -f "$_helpers_path" ]; then
    # shellcheck source=doey-task-helpers.sh
    source "$_helpers_path"
    _task_helpers_sourced=1
    return 0
  fi
  printf '  %s✗ Task helpers not found: %s%s\n' "$ERROR" "$_helpers_path" "$RESET" >&2
  return 1
}

# ── Thin Wrappers ───────────────────────────────────────────────────
# Delegate to doey-task-helpers.sh while preserving the existing
# interface (callers pass task file paths, not project dirs).

_task_read() {
  _task_source_helpers || return 1
  local _file="$1"
  [ -s "$_file" ] || return 1
  TASK_ATTACHMENTS=""  # legacy field not in helpers
  task_read "$_file"
  # Also read TASK_ATTACHMENTS (legacy, not in helpers schema)
  local _line
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "${_line%%=*}" in
      TASK_ATTACHMENTS) TASK_ATTACHMENTS="${_line#*=}" ;;
    esac
  done < "$_file" || true
  [ -n "${TASK_ID:-}" ] || return 1
}

_task_age() {
  _task_source_helpers || { printf '?'; return; }
  _task_age_str "$1"
}

_task_create() {
  _task_source_helpers || return 1
  local _tasks_dir="$1" _title="$2"
  local _description="${3:-}" _attachments="${4:-}"
  # Derive project dir from tasks dir (strip /.doey/tasks or /tasks suffix)
  local _proj_dir="${_tasks_dir%/.doey/tasks}"
  [ "$_proj_dir" = "$_tasks_dir" ] && _proj_dir="${_tasks_dir%/tasks}"
  local _id
  _id="$(task_create "$_proj_dir" "$_title" "feature" "user" "$_description")"
  # Append legacy TASK_ATTACHMENTS if provided (not in helpers schema)
  # Use append semantics so pre-existing attachments are preserved.
  if [ -n "$_attachments" ]; then
    _task_append_to_field "${_tasks_dir}/${_id}.task" "TASK_ATTACHMENTS" "$_attachments" "|"
  fi
  echo "$_id"
}

_task_set_field() {
  _task_source_helpers || return 1
  task_update_field "$1" "$2" "$3"
}

_task_set_description() {
  local _file="${1}/${2}.task"
  [ -f "$_file" ] || { printf '  %s✗ Task %s not found%s\n' "$ERROR" "$2" "$RESET"; return 1; }
  _task_set_field "$_file" "TASK_DESCRIPTION" "$3"
}

_task_add_attachment() {
  _task_source_helpers || return 1
  local _tasks_dir="$1" _id="$2" _attachment="$3"
  local _file="${_tasks_dir}/${_id}.task"
  [ -f "$_file" ] || { printf '  %s✗ Task %s not found%s\n' "$ERROR" "$_id" "$RESET"; return 1; }
  _task_append_to_field "$_file" "TASK_ATTACHMENTS" "$_attachment" "|"
}

_task_set_status() {
  _task_source_helpers || return 1
  local _tasks_dir="$1" _id="$2" _new_status="$3"
  local _file="${_tasks_dir}/${_id}.task"
  [ -f "$_file" ] || { printf '  %s✗ Task %s not found%s\n' "$ERROR" "$_id" "$RESET"; return 1; }
  # "failed" is a CLI-only status not in helpers — handle directly
  case "$_new_status" in
    failed)
      task_update_field "$_file" "TASK_STATUS" "failed"
      local _now; _now=$(date +%s)
      _task_append_to_field "$_file" "TASK_TIMESTAMPS" "failed=${_now}" "|"
      return 0
      ;;
    draft|active|in_progress|paused|blocked|pending_user_confirmation|done|cancelled) ;;
    *) printf '  %s✗ Invalid status: %s%s\n' "$ERROR" "$_new_status" "$RESET"; return 1 ;;
  esac
  # Derive project dir for helpers API
  local _proj_dir="${_tasks_dir%/.doey/tasks}"
  [ "$_proj_dir" = "$_tasks_dir" ] && _proj_dir="${_tasks_dir%/tasks}"
  task_update_status "$_proj_dir" "$_id" "$_new_status"
}

# ── Directory Resolution ────────────────────────────────────────────

# Walk up from cwd to find the project directory (contains .doey/)
_task_find_project_dir() {
  local _search_dir
  _search_dir="$(pwd)"
  while [ "$_search_dir" != "/" ]; do
    if [ -d "${_search_dir}/.doey" ]; then
      echo "$_search_dir"
      return 0
    fi
    _search_dir="$(dirname "$_search_dir")"
  done
  return 1
}

# Return the persistent task directory (.doey/tasks/), auto-creating it
_task_persistent_dir() {
  local _proj_dir
  _proj_dir="$(_task_find_project_dir 2>/dev/null)" || true
  if [ -n "$_proj_dir" ]; then
    mkdir -p "${_proj_dir}/.doey/tasks"
    echo "${_proj_dir}/.doey/tasks"
    return 0
  fi
  # Fallback: use RUNTIME_DIR if no .doey/ found (e.g. unregistered project)
  local _dir _name _session _runtime
  _dir="$(pwd)"
  _name="$(find_project "$_dir" 2>/dev/null)"
  [ -z "$_name" ] && { printf '  %s✗ No doey project for %s%s\n' "$ERROR" "$_dir" "$RESET" >&2; return 1; }
  _session="doey-${_name}"
  _runtime=$(tmux show-environment -t "$_session" DOEY_RUNTIME 2>/dev/null) || true
  _runtime="${_runtime#*=}"
  [ -z "$_runtime" ] && { printf '  %s✗ Session not running: %s%s\n' "$ERROR" "$_session" "$RESET" >&2; return 1; }
  mkdir -p "${_runtime}/tasks"
  echo "${_runtime}/tasks"
}

# Get runtime dir for syncing (may fail silently if no session running)
_task_runtime_dir() {
  local _dir _name _session _runtime
  _dir="$(pwd)"
  _name="$(find_project "$_dir" 2>/dev/null)" || true
  [ -z "$_name" ] && return 1
  _session="doey-${_name}"
  _runtime=$(tmux show-environment -t "$_session" DOEY_RUNTIME 2>/dev/null) || true
  _runtime="${_runtime#*=}"
  [ -z "$_runtime" ] && return 1
  echo "$_runtime"
}

# Sync .task files and .next_id from persistent dir to runtime cache
_task_sync_to_runtime() {
  local _src="$1" _dst="$2"
  [ -d "$_src" ] || return 0
  mkdir -p "$_dst"
  # Copy .next_id
  [ -f "$_src/.next_id" ] && cp "$_src/.next_id" "$_dst/.next_id"
  # Copy all .task files (including terminal — TUI may want history)
  local _f
  for _f in "$_src"/*.task; do
    [ -f "$_f" ] || continue
    [ -s "$_f" ] || continue  # skip empty files
    cp "$_f" "$_dst/$(basename "$_f")"
  done
}

# ── Display Helpers ─────────────────────────────────────────────────

# Print a task field if non-empty
_tsf() { [ -n "$2" ] && printf '  %b%-16s%b %s\n' "$BOLD" "$1" "$RESET" "$2"; }

_task_show() {
  local _file="$1"
  [ -f "$_file" ] || { printf '  %s✗ Task file not found%s\n' "$ERROR" "$RESET"; return 1; }
  _task_read "$_file"
  local _age=""
  [ -n "$TASK_CREATED" ] && _age="$(_task_age "$TASK_CREATED")"
  printf '\n'
  printf '  %b━━━ Task #%s ━━━%b\n' "$BRAND" "$TASK_ID" "$RESET"
  printf '  %b%-16s%b %s\n' "$BOLD" "Title:" "$RESET" "$TASK_TITLE"
  _tsf "Shortname:" "${TASK_SHORTNAME:-}"
  printf '  %b%-16s%b %s\n' "$BOLD" "Status:" "$RESET" "$TASK_STATUS"
  _tsf "Type:" "$TASK_TYPE"
  _tsf "Tags:" "$TASK_TAGS"
  _tsf "Created by:" "$TASK_CREATED_BY"
  _tsf "Assigned to:" "$TASK_ASSIGNED_TO"
  [ -n "$_age" ] && printf '  %b%-16s%b %s ago\n' "$BOLD" "Age:" "$RESET" "$_age"
  _tsf "Description:" "$TASK_DESCRIPTION"
  _tsf "Acceptance:" "$TASK_ACCEPTANCE_CRITERIA"
  _tsf "Hypotheses:" "$TASK_HYPOTHESES"
  _tsf "Decisions:" "$TASK_DECISION_LOG"
  _tsf "Subtasks:" "$TASK_SUBTASKS"
  _tsf "Related files:" "$TASK_RELATED_FILES"
  _tsf "Blockers:" "$TASK_BLOCKERS"
  _tsf "Attachments:" "$TASK_ATTACHMENTS"
  _tsf "Timestamps:" "$TASK_TIMESTAMPS"
  _tsf "Notes:" "$TASK_NOTES"
  printf '  %b%-16s%b v%s\n' "$DIM" "Schema:" "$RESET" "${TASK_SCHEMA_VERSION:-1}"
  printf '\n'
}

# ── Main Dispatch ───────────────────────────────────────────────────

task_command() {
  local _tasks_dir _runtime_cache _subcmd="${1:-list}"
  shift 2>/dev/null || true

  _tasks_dir="$(_task_persistent_dir)" || exit 1
  mkdir -p "$_tasks_dir"
  # Runtime cache for TUI sync (best-effort, may not exist if session is down)
  _runtime_cache=""
  local _rt
  _rt="$(_task_runtime_dir 2>/dev/null)" && _runtime_cache="${_rt}/tasks"

  case "$_subcmd" in
    list|ls|"")
      doey_header "Doey Tasks"
      printf '\n'
      # DB fast path: try doey-ctl first
      if command -v doey-ctl >/dev/null 2>&1; then
        local _db_list
        _db_list=$(doey-ctl task list --project-dir "$PROJECT_DIR" 2>/dev/null) && [ -n "$_db_list" ] && {
          printf '%s\n' "$_db_list"
          printf '\n'
          break
        }
      fi
      local _count=0
      for _f in "${_tasks_dir}"/*.task; do
        [ -f "$_f" ] || continue
        [ -s "$_f" ] || continue  # skip empty files
        local TASK_ID TASK_TITLE TASK_STATUS TASK_CREATED TASK_TYPE
        local TASK_TAGS TASK_CREATED_BY TASK_ASSIGNED_TO TASK_DESCRIPTION
        local TASK_ATTACHMENTS TASK_ACCEPTANCE_CRITERIA TASK_HYPOTHESES
        local TASK_DECISION_LOG TASK_SUBTASKS TASK_RELATED_FILES
        local TASK_BLOCKERS TASK_TIMESTAMPS TASK_NOTES TASK_SCHEMA_VERSION
        _task_read "$_f" || continue  # skip malformed files
        [ "$TASK_STATUS" = "done" ] && continue
        [ "$TASK_STATUS" = "cancelled" ] && continue
        local _col _age
        case "$TASK_STATUS" in
          in_progress)                _col="$SUCCESS" ;;
          pending_user_confirmation)  _col="$WARN" ;;
          active)                     _col="$BOLD" ;;
          blocked)                    _col="$ERROR" ;;
          *)                          _col="$DIM" ;;
        esac
        _age="$(_task_age "$TASK_CREATED")"
        local _type_tag=""
        [ -n "$TASK_TYPE" ] && [ "$TASK_TYPE" != "feature" ] && _type_tag=" [${TASK_TYPE}]"
        printf '  %b[%s]%b  %b%-30s%b  %b%s%b%s  %s ago\n' \
          "$BOLD" "$TASK_ID" "$RESET" \
          "$_col" "$TASK_STATUS" "$RESET" \
          "$BOLD" "$TASK_TITLE" "$RESET" \
          "$_type_tag" \
          "$_age"
        _count=$((_count + 1))
      done
      if [ "$_count" -eq 0 ]; then
        printf '  %bNo active tasks.%b\n' "$DIM" "$RESET"
        printf '  %bAdd: doey task add "your goal"%b\n' "$DIM" "$RESET"
      else
        printf '\n  %bLifecycle: draft → active → in_progress → pending_user_confirmation → done%b\n' "$DIM" "$RESET"
      fi
      printf '\n'
      ;;

    add)
      local _title="" _desc="" _attach=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --description) shift; _desc="${1:-}"; shift ;;
          --attach)      shift; _attach="${1:-}"; shift ;;
          *)             if [ -n "$_title" ]; then _title="$_title $1"; else _title="$1"; fi; shift ;;
        esac
      done
      [ -z "$_title" ] && { printf '  Usage: doey task add "Your task title" [--description "text"] [--attach "url"]\n'; exit 1; }
      local _id
      _id="$(_task_create "$_tasks_dir" "$_title" "$_desc" "$_attach")"
      [ -n "$_runtime_cache" ] && _task_sync_to_runtime "$_tasks_dir" "$_runtime_cache"
      printf '\n  %s[%s]%s Task created: %s%s%s\n\n' \
        "$SUCCESS" "$_id" "$RESET" "$BOLD" "$_title" "$RESET"
      ;;

    show)
      local _id="${1:-}"
      [ -z "$_id" ] && { printf '  Usage: doey task show <id>\n'; exit 1; }
      # DB fast path: try doey-ctl first
      if command -v doey-ctl >/dev/null 2>&1; then
        local _db_show
        _db_show=$(doey-ctl task get --id "$_id" --project-dir "$PROJECT_DIR" 2>/dev/null) && [ -n "$_db_show" ] && {
          printf '%s\n' "$_db_show"
          break
        }
      fi
      local _file="${_tasks_dir}/${_id}.task"
      [ -f "$_file" ] || { printf '  %s✗ Task %s not found%s\n' "$ERROR" "$_id" "$RESET"; exit 1; }
      _task_show "$_file"
      ;;

    ready|activate|start|pause|block|confirm|pending|done|failed|cancel)
      local _id="${1:-}"
      [ -z "$_id" ] && { printf '  Usage: doey task %s <id>\n' "$_subcmd"; exit 1; }
      local _ts_status _ts_icon _ts_color
      case "$_subcmd" in
        ready|activate)  _ts_status="active";                     _ts_icon="✓"; _ts_color="$SUCCESS" ;;
        start)           _ts_status="in_progress";                _ts_icon="●"; _ts_color="$SUCCESS" ;;
        pause)           _ts_status="paused";                     _ts_icon="⏸"; _ts_color="$WARN" ;;
        block)           _ts_status="blocked";                    _ts_icon="⊘"; _ts_color="$ERROR" ;;
        confirm|pending) _ts_status="pending_user_confirmation";  _ts_icon="✓"; _ts_color="$WARN" ;;
        done)            _ts_status="done";                       _ts_icon="✓"; _ts_color="$SUCCESS" ;;
        failed)          _ts_status="failed";                     _ts_icon="✗"; _ts_color="$ERROR" ;;
        cancel)          _ts_status="cancelled";                  _ts_icon="—"; _ts_color="$DIM" ;;
      esac
      _task_set_status "$_tasks_dir" "$_id" "$_ts_status"
      [ -n "$_runtime_cache" ] && _task_sync_to_runtime "$_tasks_dir" "$_runtime_cache"
      printf '  %s%s Task [%s] %s.%s\n' "$_ts_color" "$_ts_icon" "$_id" "$_ts_status" "$RESET"
      ;;

    describe)
      local _id="${1:-}" _desc="${2:-}"
      [ -z "$_id" ] || [ -z "$_desc" ] && { printf '  Usage: doey task describe <id> "description text"\n'; exit 1; }
      _task_set_description "$_tasks_dir" "$_id" "$_desc"
      [ -n "$_runtime_cache" ] && _task_sync_to_runtime "$_tasks_dir" "$_runtime_cache"
      printf '  %s✓ Task [%s] description updated.%s\n' "$SUCCESS" "$_id" "$RESET"
      ;;

    attach)
      local _id="${1:-}" _attachment="${2:-}"
      [ -z "$_id" ] || [ -z "$_attachment" ] && { printf '  Usage: doey task attach <id> "url_or_path"\n'; exit 1; }
      _task_add_attachment "$_tasks_dir" "$_id" "$_attachment"
      [ -n "$_runtime_cache" ] && _task_sync_to_runtime "$_tasks_dir" "$_runtime_cache"
      printf '  %s✓ Attachment added to task [%s].%s\n' "$SUCCESS" "$_id" "$RESET"
      ;;

    *)
      printf '  Usage: doey task [list|add|show|ready|start|pause|block|confirm|pending|done|failed|cancel|describe|attach]\n'
      ;;
  esac
}
