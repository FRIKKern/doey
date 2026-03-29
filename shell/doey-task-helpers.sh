#!/usr/bin/env bash
# doey-task-helpers.sh — Schema v2 task management helpers
# Sourceable library, not standalone. Extends the basic task system in doey.sh.
set -euo pipefail

# ── task_create ──────────────────────────────────────────────────────
# Creates a .task file (schema v2) and companion .json file.
# Args: runtime_dir title [type] [owner] [priority] [summary] [description]
task_create() {
  local runtime_dir="$1" title="$2"
  local task_type="${3:-feature}" task_owner="${4:-Boss}" priority="${5:-P2}"
  local summary="${6:-$title}" description="${7:-}"
  local tasks_dir="${runtime_dir}/tasks"
  mkdir -p "$tasks_dir"

  # Next ID (same pattern as _task_next_id)
  local counter_file="${tasks_dir}/.next_id" id=1
  if [ -f "$counter_file" ]; then
    id=$(cat "$counter_file")
  fi
  echo $((id + 1)) > "$counter_file"

  local now
  now=$(date +%s)
  local task_file="${tasks_dir}/${id}.task"
  local json_file="${tasks_dir}/${id}.json"

  # Write .task (schema v2)
  local tmp="${task_file}.tmp"
  printf 'TASK_ID=%s\nTASK_TITLE=%s\nTASK_STATUS=active\nTASK_CREATED=%s\nTASK_TYPE=%s\nTASK_OWNER=%s\nTASK_PRIORITY=%s\nTASK_SUMMARY=%s\nTASK_SCHEMA_VERSION=2\nTASK_DESCRIPTION=%s\nTASK_ATTACHMENTS=\n' \
    "$id" "$title" "$now" "$task_type" "$task_owner" "$priority" "$summary" "$description" > "$tmp"
  mv "$tmp" "$task_file"

  # Write companion .json
  tmp="${json_file}.tmp"
  printf '{\n  "schema_version": 2,\n  "task_id": %s,\n  "title": "%s",\n  "task_type": "%s",\n  "intent": "",\n  "hypotheses": [],\n  "constraints": [],\n  "success_criteria": [],\n  "deliverables": [],\n  "dispatch_plan": {}\n}\n' \
    "$id" "$title" "$task_type" > "$tmp"
  mv "$tmp" "$json_file"

  echo "$id"
}

# ── task_list ────────────────────────────────────────────────────────
# Lists tasks with structured info. Pass --all to include terminal statuses.
# Args: runtime_dir [--all]
task_list() {
  local runtime_dir="$1"; shift
  local show_all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) show_all=1 ;;
    esac
    shift
  done

  local tasks_dir="${runtime_dir}/tasks"
  if [ ! -d "$tasks_dir" ]; then
    echo "No tasks directory."
    return 0
  fi

  # Collect tasks into sortable lines: priority_num|id|line
  local entries="" f
  for f in "${tasks_dir}"/*.task; do
    [ -f "$f" ] || continue

    local TASK_ID="" TASK_TITLE="" TASK_STATUS="" TASK_CREATED=""
    local TASK_TYPE="" TASK_OWNER="" TASK_PRIORITY="" TASK_SUMMARY=""
    local TASK_SCHEMA_VERSION="" TASK_DESCRIPTION="" TASK_ATTACHMENTS=""
    task_read "$f"

    # Skip terminal unless --all
    if [ "$show_all" -eq 0 ]; then
      case "$TASK_STATUS" in
        done|cancelled|failed) continue ;;
      esac
    fi

    # Read type/priority from .json if present and not already set
    local json_file="${f%.task}.json"
    if [ -f "$json_file" ] && [ -z "$TASK_TYPE" ]; then
      local jline
      while IFS= read -r jline; do
        case "$jline" in
          *\"task_type\"*) TASK_TYPE=$(echo "$jline" | sed 's/.*"task_type"[^"]*"\([^"]*\)".*/\1/') ;;
        esac
      done < "$json_file"
    fi

    if [ -z "$TASK_TYPE" ]; then TASK_TYPE="feature"; fi
    if [ -z "$TASK_PRIORITY" ]; then TASK_PRIORITY="P2"; fi

    # Priority sort key
    local pnum=2
    case "$TASK_PRIORITY" in
      P0) pnum=0 ;; P1) pnum=1 ;; P2) pnum=2 ;; P3) pnum=3 ;;
    esac

    # Age
    local age=""
    if [ -n "$TASK_CREATED" ]; then
      local now elapsed
      now=$(date +%s)
      elapsed=$((now - TASK_CREATED))
      if [ "$elapsed" -lt 60 ]; then age="${elapsed}s"
      elif [ "$elapsed" -lt 3600 ]; then age="$((elapsed / 60))m"
      elif [ "$elapsed" -lt 86400 ]; then age="$((elapsed / 3600))h"
      else age="$((elapsed / 86400))d"; fi
    fi

    local line
    line=$(printf '#%s [%s] [%s] [%s] %s (%s)' \
      "$TASK_ID" "$TASK_STATUS" "$TASK_TYPE" "$TASK_PRIORITY" "$TASK_TITLE" "$age")
    entries="${entries}${pnum}|${TASK_ID}|${line}"$'\n'
  done

  # Sort by priority then ID and print
  if [ -n "$entries" ]; then
    printf '%s' "$entries" | sort -t'|' -k1,1n -k2,2n | while IFS='|' read -r _ _ line; do
      echo "$line"
    done
  else
    echo "No tasks found."
  fi
}

# ── task_update_status ───────────────────────────────────────────────
# Updates TASK_STATUS in a .task file.
# Args: runtime_dir task_id new_status
# Returns: 0 on success, 1 on error
task_update_status() {
  local runtime_dir="$1" task_id="$2" new_status="$3"
  local tasks_dir="${runtime_dir}/tasks"
  local task_file="${tasks_dir}/${task_id}.task"

  if [ ! -f "$task_file" ]; then
    printf 'Error: task %s not found\n' "$task_id" >&2
    return 1
  fi

  case "$new_status" in
    active|in_progress|pending_user_confirmation|done|cancelled|failed) ;;
    *)
      printf 'Error: invalid status "%s" (valid: active, in_progress, pending_user_confirmation, done, cancelled, failed)\n' "$new_status" >&2
      return 1
      ;;
  esac

  local tmp="${task_file}.tmp" line
  while IFS= read -r line; do
    case "${line%%=*}" in
      TASK_STATUS) printf 'TASK_STATUS=%s\n' "$new_status" ;;
      *)           printf '%s\n' "$line" ;;
    esac
  done < "$task_file" > "$tmp"
  mv "$tmp" "$task_file"
  return 0
}

# ── task_read ────────────────────────────────────────────────────────
# Parse a task file and set shell variables (v1 + v2 fields).
# Args: task_file_path
task_read() {
  local file="$1"
  TASK_ID=""; TASK_TITLE=""; TASK_STATUS=""; TASK_CREATED=""
  TASK_DESCRIPTION=""; TASK_ATTACHMENTS=""
  TASK_TYPE=""; TASK_OWNER=""; TASK_PRIORITY=""; TASK_SUMMARY=""
  TASK_SCHEMA_VERSION=""

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "${line%%=*}" in
      TASK_ID)             TASK_ID="${line#*=}" ;;
      TASK_TITLE)          TASK_TITLE="${line#*=}" ;;
      TASK_STATUS)         TASK_STATUS="${line#*=}" ;;
      TASK_CREATED)        TASK_CREATED="${line#*=}" ;;
      TASK_DESCRIPTION)    TASK_DESCRIPTION="${line#*=}" ;;
      TASK_ATTACHMENTS)    TASK_ATTACHMENTS="${line#*=}" ;;
      TASK_TYPE)           TASK_TYPE="${line#*=}" ;;
      TASK_OWNER)          TASK_OWNER="${line#*=}" ;;
      TASK_PRIORITY)       TASK_PRIORITY="${line#*=}" ;;
      TASK_SUMMARY)        TASK_SUMMARY="${line#*=}" ;;
      TASK_SCHEMA_VERSION) TASK_SCHEMA_VERSION="${line#*=}" ;;
    esac
  done < "$file" || true

  # Legacy v1 defaults
  if [ -z "$TASK_SCHEMA_VERSION" ]; then
    TASK_SCHEMA_VERSION="1"
    if [ -z "$TASK_TYPE" ]; then TASK_TYPE="feature"; fi
    if [ -z "$TASK_OWNER" ]; then TASK_OWNER="Boss"; fi
    if [ -z "$TASK_PRIORITY" ]; then TASK_PRIORITY="P2"; fi
  fi
  if [ -z "$TASK_SUMMARY" ]; then TASK_SUMMARY="$TASK_TITLE"; fi
}

# ── task_upgrade_schema ──────────────────────────────────────────────
# Upgrades a legacy v1 .task file to v2 format. Idempotent.
# Args: task_file_path
task_upgrade_schema() {
  local file="$1"
  [ -f "$file" ] || { printf 'Error: file not found: %s\n' "$file" >&2; return 1; }

  # Read current fields
  local TASK_ID TASK_TITLE TASK_STATUS TASK_CREATED
  local TASK_DESCRIPTION TASK_ATTACHMENTS
  local TASK_TYPE TASK_OWNER TASK_PRIORITY TASK_SUMMARY TASK_SCHEMA_VERSION
  task_read "$file"

  # Already v2 — nothing to do
  if [ "$TASK_SCHEMA_VERSION" = "2" ]; then
    return 0
  fi

  # Apply v2 defaults
  if [ -z "$TASK_TYPE" ]; then TASK_TYPE="feature"; fi
  if [ -z "$TASK_OWNER" ]; then TASK_OWNER="Boss"; fi
  if [ -z "$TASK_PRIORITY" ]; then TASK_PRIORITY="P2"; fi
  if [ -z "$TASK_SUMMARY" ]; then TASK_SUMMARY="$TASK_TITLE"; fi

  # Rewrite the file with all v2 fields
  local tmp="${file}.tmp"
  printf 'TASK_ID=%s\nTASK_TITLE=%s\nTASK_STATUS=%s\nTASK_CREATED=%s\nTASK_TYPE=%s\nTASK_OWNER=%s\nTASK_PRIORITY=%s\nTASK_SUMMARY=%s\nTASK_SCHEMA_VERSION=2\nTASK_DESCRIPTION=%s\nTASK_ATTACHMENTS=%s\n' \
    "$TASK_ID" "$TASK_TITLE" "$TASK_STATUS" "$TASK_CREATED" \
    "$TASK_TYPE" "$TASK_OWNER" "$TASK_PRIORITY" "$TASK_SUMMARY" \
    "$TASK_DESCRIPTION" "$TASK_ATTACHMENTS" > "$tmp"
  mv "$tmp" "$file"

  # Create companion .json if missing
  local json_file="${file%.task}.json"
  if [ ! -f "$json_file" ]; then
    tmp="${json_file}.tmp"
    printf '{\n  "schema_version": 2,\n  "task_id": %s,\n  "title": "%s",\n  "task_type": "%s",\n  "intent": "",\n  "hypotheses": [],\n  "constraints": [],\n  "success_criteria": [],\n  "deliverables": [],\n  "dispatch_plan": {}\n}\n' \
      "$TASK_ID" "$TASK_TITLE" "$TASK_TYPE" > "$tmp"
    mv "$tmp" "$json_file"
  fi

  return 0
}
