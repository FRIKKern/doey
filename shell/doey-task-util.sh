#!/usr/bin/env bash
set -euo pipefail

# doey-task-util.sh — task file utility for Doey runtime task management
# Usage: doey-task-util <command> [args...]

if [ -z "${RUNTIME_DIR:-}" ]; then
  printf 'error: RUNTIME_DIR is not set\n' >&2
  exit 1
fi

TD="${RUNTIME_DIR}/tasks"

usage() {
  printf 'Usage: doey-task-util <command> [args...]\n\n'
  printf 'Commands:\n'
  printf '  create TITLE              Create a new task\n'
  printf '  set-status ID STATUS      Set task status\n'
  printf '  set-field ID FIELD VALUE  Set or append a field\n'
  printf '  list [--active]           List tasks\n'
  printf '  get ID                    Print a task\n'
}

cmd_create() {
  local title="$1"
  mkdir -p "$TD"

  # Allocate next ID
  local id=1
  if [ -f "${TD}/.next_id" ]; then
    id="$(cat "${TD}/.next_id")"
  fi
  local next_id=$((id + 1))
  printf '%s\n' "$next_id" > "${TD}/.next_id"

  # Write task file atomically
  local tmpfile="${TD}/${id}.task.tmp.$$"
  local epoch
  epoch="$(date +%s)"
  printf 'TASK_ID=%s\nTASK_TITLE=%s\nTASK_STATUS=active\nTASK_CREATED=%s\n' \
    "$id" "$title" "$epoch" > "$tmpfile"
  mv -f "$tmpfile" "${TD}/${id}.task"

  printf '%s\n' "$id"
}

cmd_set_status() {
  local id="$1"
  local status="$2"
  local taskfile="${TD}/${id}.task"

  if [ ! -f "$taskfile" ]; then
    printf 'error: task %s not found\n' "$id" >&2
    return 1
  fi

  # Validate status
  case "$status" in
    active|pending_user_confirmation|committed|pushed|done|cancelled) ;;
    *)
      printf 'error: invalid status: %s\n' "$status" >&2
      return 1
      ;;
  esac

  local tmpfile="${taskfile}.tmp.$$"
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      TASK_STATUS=*) printf 'TASK_STATUS=%s\n' "$status" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$taskfile" > "$tmpfile"
  mv -f "$tmpfile" "$taskfile"
}

cmd_set_field() {
  local id="$1"
  local field="$2"
  local value="$3"
  local taskfile="${TD}/${id}.task"

  if [ ! -f "$taskfile" ]; then
    printf 'error: task %s not found\n' "$id" >&2
    return 1
  fi

  local tmpfile="${taskfile}.tmp.$$"
  local found=0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${field}"=*)
        printf '%s=%s\n' "$field" "$value"
        found=1
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$taskfile" > "$tmpfile"

  # Append if field was not found
  if [ "$found" -eq 0 ]; then
    printf '%s=%s\n' "$field" "$value" >> "$tmpfile"
  fi

  mv -f "$tmpfile" "$taskfile"
}

cmd_list() {
  local active_only=0
  if [ "${1:-}" = "--active" ]; then
    active_only=1
  fi

  mkdir -p "$TD"

  # zsh-safe glob via bash -c
  local files
  files="$(bash -c 'shopt -s nullglob; for f in "'"$TD"'"/*.task; do printf "%s\n" "$f"; done')"

  if [ -z "$files" ]; then
    exit 0
  fi

  local first=1
  local line status
  while IFS= read -r taskfile; do
    if [ "$active_only" -eq 1 ]; then
      status=""
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          TASK_STATUS=*) status="${line#TASK_STATUS=}" ;;
        esac
      done < "$taskfile"
      case "$status" in
        done|cancelled) continue ;;
      esac
    fi

    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf '---\n'
    fi
    cat "$taskfile"
  done <<EOF
$files
EOF
}

cmd_get() {
  local id="$1"
  local taskfile="${TD}/${id}.task"

  if [ ! -f "$taskfile" ]; then
    printf 'error: task %s not found\n' "$id" >&2
    return 1
  fi

  cat "$taskfile"
}

# Main dispatch
if [ $# -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  usage
  exit 0
fi

cmd="$1"
shift

case "$cmd" in
  create)
    if [ $# -lt 1 ]; then
      printf 'error: create requires TITLE\n' >&2
      exit 1
    fi
    cmd_create "$1"
    ;;
  set-status)
    if [ $# -lt 2 ]; then
      printf 'error: set-status requires ID STATUS\n' >&2
      exit 1
    fi
    cmd_set_status "$1" "$2"
    ;;
  set-field)
    if [ $# -lt 3 ]; then
      printf 'error: set-field requires ID FIELD VALUE\n' >&2
      exit 1
    fi
    cmd_set_field "$1" "$2" "$3"
    ;;
  list)
    cmd_list "${1:-}"
    ;;
  get)
    if [ $# -lt 1 ]; then
      printf 'error: get requires ID\n' >&2
      exit 1
    fi
    cmd_get "$1"
    ;;
  *)
    printf 'error: unknown command: %s\n' "$cmd" >&2
    usage >&2
    exit 1
    ;;
esac
