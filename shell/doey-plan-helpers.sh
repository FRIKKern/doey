#!/usr/bin/env bash
# Plan CRUD helpers for Doey — sourced by other scripts, do not run directly.
set -euo pipefail

# plan_create(project_dir, title, task_id)
# Create a new plan file in .doey/plans/<id>.md, echo the new plan_id.
plan_create() {
  local project_dir="$1" title="$2" task_id="${3:-}"
  local plans_dir="${project_dir}/.doey/plans"
  mkdir -p "$plans_dir"

  # Auto-increment: find highest numeric ID
  local max_id=0
  local f base num
  for f in "$plans_dir"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .md)
    case "$base" in *[!0-9]*) continue ;; esac
    num=$((base + 0))
    [ "$num" -gt "$max_id" ] && max_id="$num"
  done
  local new_id=$((max_id + 1))

  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  cat > "${plans_dir}/${new_id}.md" <<EOF
---
plan_id: ${new_id}
task_id: ${task_id}
title: "${title}"
status: draft
created: ${now}
updated: ${now}
---

# ${title}

## Intent

## Tasks

## Architecture

## Constraints

## Success Criteria
EOF

  # Sync to DB (requires task_id for the foreign key)
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "$task_id" ]; then
    local _body; _body=$(cat "${plans_dir}/${new_id}.md")
    doey-ctl plan create --title "$title" --task-id "$task_id" \
      --body "$_body" --project-dir "$project_dir" 2>/dev/null || true
  fi

  echo "$new_id"
}

# plan_read(project_dir, plan_id)
# Output the full content of a plan file.
plan_read() {
  local project_dir="$1" plan_id="$2"
  local plan_file="${project_dir}/.doey/plans/${plan_id}.md"
  if [ ! -f "$plan_file" ]; then
    echo "ERROR: Plan ${plan_id} not found" >&2
    return 1
  fi
  cat "$plan_file"
}

# plan_list(project_dir)
# List all plans: <id>|<title>|<status>|<task_id>|<updated>
plan_list() {
  local project_dir="$1"
  local plans_dir="${project_dir}/.doey/plans"
  [ -d "$plans_dir" ] || return 0

  local f base
  for f in "$plans_dir"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .md)
    case "$base" in *[!0-9]*) continue ;; esac

    local p_title="" p_status="" p_task_id="" p_updated=""
    local in_front=false
    while IFS= read -r line; do
      case "$line" in
        "---")
          if [ "$in_front" = "true" ]; then break; fi
          in_front=true; continue ;;
      esac
      [ "$in_front" = "true" ] || continue
      case "$line" in
        title:*)    p_title="${line#title: }"; p_title="${p_title#\"}"; p_title="${p_title%\"}" ;;
        status:*)   p_status="${line#status: }" ;;
        task_id:*)  p_task_id="${line#task_id: }" ;;
        updated:*)  p_updated="${line#updated: }" ;;
      esac
    done < "$f"

    printf '%s|%s|%s|%s|%s\n' "$base" "$p_title" "$p_status" "$p_task_id" "$p_updated"
  done
}

# plan_update_status(project_dir, plan_id, new_status)
# Update the status field in frontmatter. Valid: draft, active, complete, archived.
plan_update_status() {
  local project_dir="$1" plan_id="$2" new_status="$3"
  case "$new_status" in
    draft|active|complete|archived) ;;
    *) echo "ERROR: Invalid status '${new_status}'. Must be: draft, active, complete, archived" >&2; return 1 ;;
  esac
  plan_update_field "$project_dir" "$plan_id" "status" "$new_status"
}

# plan_update_field(project_dir, plan_id, field, value)
# Update any frontmatter field. macOS-compatible sed (tmp+mv).
plan_update_field() {
  local project_dir="$1" plan_id="$2" field="$3" value="$4"
  local plan_file="${project_dir}/.doey/plans/${plan_id}.md"
  if [ ! -f "$plan_file" ]; then
    echo "ERROR: Plan ${plan_id} not found" >&2
    return 1
  fi

  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Update the target field (and timestamp) in one pass
  local tmp="${plan_file}.tmp.$$"
  if [ "$field" != "updated" ]; then
    sed -e "s|^${field}:.*|${field}: ${value}|" -e "s|^updated:.*|updated: ${now}|" "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"
  else
    sed "s|^${field}:.*|${field}: ${value}|" "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"
  fi
}

# plan_get_field(project_dir, plan_id, field)
# Extract a single frontmatter field value.
plan_get_field() {
  local project_dir="$1" plan_id="$2" field="$3"
  local plan_file="${project_dir}/.doey/plans/${plan_id}.md"
  if [ ! -f "$plan_file" ]; then
    echo "ERROR: Plan ${plan_id} not found" >&2
    return 1
  fi

  local in_front=false
  while IFS= read -r line; do
    case "$line" in
      "---")
        if [ "$in_front" = "true" ]; then return 0; fi
        in_front=true; continue ;;
    esac
    [ "$in_front" = "true" ] || continue
    case "$line" in
      "${field}:"*)
        local val="${line#*: }"
        val="${val#\"}"; val="${val%\"}"
        echo "$val"
        return 0 ;;
    esac
  done < "$plan_file"
}

# plan_find_by_task_id(project_dir, task_id)
# Find the first plan file whose frontmatter task_id matches. Prints path to stdout.
# Returns 0 if found, 1 if not.
plan_find_by_task_id() {
  local project_dir="$1" task_id="$2"
  local plans_dir="${project_dir}/.doey/plans"
  [ -d "$plans_dir" ] || return 1

  local f
  for f in "$plans_dir"/*.md; do
    [ -f "$f" ] || continue

    local in_front=false
    while IFS= read -r line; do
      case "$line" in
        "---")
          if [ "$in_front" = "true" ]; then break; fi
          in_front=true; continue ;;
      esac
      [ "$in_front" = "true" ] || continue
      case "$line" in
        task_id:*)
          local val="${line#task_id: }"
          val="${val#\"}"; val="${val%\"}"
          if [ "$val" = "$task_id" ]; then
            echo "$f"
            return 0
          fi
          break ;;
      esac
    done < "$f"
  done

  return 1
}

# plan_check_checkbox(plan_file, task_id, task_title)
# Check off a matching unchecked checkbox in the plan body.
# Tries <!-- task_id=N --> comment first, falls back to title text match.
# Returns 0 if a box was checked, 1 if nothing matched.
plan_check_checkbox() {
  local plan_file="$1" task_id="$2" task_title="$3"
  if [ ! -f "$plan_file" ]; then
    echo "ERROR: Plan file not found: ${plan_file}" >&2
    return 1
  fi

  local tmp="${plan_file}.tmp.$$"
  local matched=false
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  while IFS= read -r line; do
    if [ "$matched" = "false" ]; then
      # Try comment-tag match: - [ ] ... <!-- task_id=N -->
      case "$line" in
        *"- [ ]"*"<!-- task_id=${task_id} -->"*)
          line="${line/- \[ \]/- [x]}"
          matched=true ;;
        *)
          # Fallback: match unchecked box containing task_title text
          case "$line" in
            *"- [ ]"*"${task_title}"*)
              line="${line/- \[ \]/- [x]}"
              matched=true ;;
          esac ;;
      esac
    fi
    printf '%s\n' "$line"
  done < "$plan_file" > "$tmp"

  if [ "$matched" = "false" ]; then
    rm -f "$tmp"
    return 1
  fi

  # Update the updated: timestamp in frontmatter
  local tmp2="${plan_file}.tmp2.$$"
  sed "s|^updated:.*|updated: ${now}|" "$tmp" > "$tmp2" && mv "$tmp2" "$plan_file"
  rm -f "$tmp"
  return 0
}
