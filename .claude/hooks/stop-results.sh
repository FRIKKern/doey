#!/usr/bin/env bash
# Stop hook: capture worker results and write completion event (async)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook
_DOEY_HOOK_NAME="stop-results"
type _debug_hook_entry >/dev/null 2>&1 && _debug_hook_entry

is_worker || exit 0

mkdir -p "$RUNTIME_DIR/tasks" 2>/dev/null || true  # crash-recovery prompt storage

RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
TMPFILE=""
trap '[ -n "${TMPFILE:-}" ] && rm -f "$TMPFILE" 2>/dev/null' EXIT

# Append a path to the pipe-delimited TASK_ATTACHMENTS field in a .task file.
_append_attachment() {
  local task_file="$1" att_path="$2"
  [ -f "$task_file" ] || return 0
  local current
  current=$(grep '^TASK_ATTACHMENTS=' "$task_file" 2>/dev/null | head -1 | cut -d= -f2-) || current=""
  # Skip if already present
  case "|${current}|" in *"|${att_path}|"*) return 0 ;; esac
  local new_val
  if [ -n "$current" ]; then
    new_val="${current}|${att_path}"
  else
    new_val="${att_path}"
  fi
  # Update or append — use tmp+mv for macOS compat (no sed -i)
  local tmp_att="${task_file}.tmp.$$"
  if grep -q '^TASK_ATTACHMENTS=' "$task_file" 2>/dev/null; then
    sed "s|^TASK_ATTACHMENTS=.*|TASK_ATTACHMENTS=${new_val}|" "$task_file" > "$tmp_att" && mv "$tmp_att" "$task_file"
  else
    cp "$task_file" "$tmp_att" && echo "TASK_ATTACHMENTS=${new_val}" >> "$tmp_att" && mv "$tmp_att" "$task_file"
  fi
}

OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -80 2>/dev/null) || OUTPUT=""
[ -z "$OUTPUT" ] && _log_error "HOOK_ERROR" "tmux capture-pane returned empty" "pane=$PANE"

PROJECT_DIR="${DOEY_PROJECT_DIR:-${DOEY_TEAM_DIR:-}}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || PROJECT_DIR=""
fi
FILES_LIST=""
if [ -n "$PROJECT_DIR" ]; then
  _timeout_cmd=""
  command -v timeout >/dev/null 2>&1 && _timeout_cmd="timeout 2"
  command -v gtimeout >/dev/null 2>&1 && _timeout_cmd="gtimeout 2"  # macOS fallback
  FILES_LIST=$(cd "$PROJECT_DIR" 2>/dev/null && $_timeout_cmd git diff --name-only HEAD 2>/dev/null | head -20) || FILES_LIST=""
fi
[ -n "$PROJECT_DIR" ] && [ -z "$FILES_LIST" ] && _log "stop-results: git diff empty" || true
FILES_JSON="[]"
if [ -n "$FILES_LIST" ]; then
  FILES_JSON=$(echo "$FILES_LIST" | jq -R '.' | jq -s '.' 2>/dev/null) || FILES_JSON="[]"
fi

FILTERED=""
STATUS="done"
TOOL_COUNT=0
while IFS= read -r line; do
  # Count tool calls
  case "$line" in
    *"Read("*|*"Edit("*|*"Write("*|*"Bash("*|*"Grep("*|*"Glob("*|*"Agent("*) TOOL_COUNT=$((TOOL_COUNT + 1)) ;;
  esac
  # UI chrome filters — update if Claude Code output format changes
  case "$line" in
    *"❯"*|*"───"*|*"Ctx █"*|*"bypass permissions"*|*"shift+tab"*|*"MCP server"*|*/doctor*) continue ;;
  esac
  FILTERED="${FILTERED}${line}${NL}"
  if [ "$STATUS" = "done" ]; then
    case "$line" in
      *[Ee]rror*|*ERROR*|*[Ff]ailed*|*FAILED*|*[Ee]xception*|*EXCEPTION*) STATUS="error" ;;
    esac
  fi
done <<HEREDOC_EOF
$OUTPUT
HEREDOC_EOF

PANE_TITLE=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="worker-$PANE_INDEX"
LAST_JSON=$(printf '%s' "$FILTERED" | jq -Rs '.' 2>/dev/null) || \
  LAST_JSON=$(printf '%s' "$FILTERED" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || \
  LAST_JSON='""'
TITLE_JSON=$(printf '%s' "$PANE_TITLE" | jq -Rs '.' 2>/dev/null) || TITLE_JSON='"worker-'"$PANE_INDEX"'"'

TMPFILE=$(mktemp "${RUNTIME_DIR}/results/.tmp_XXXXXX" 2>/dev/null)
if [ -z "$TMPFILE" ] || [ ! -f "$TMPFILE" ]; then
  echo "[WARN] mktemp failed in $(basename "$0") — writing non-atomically" >> "${RUNTIME_DIR}/doey-warnings.log" 2>/dev/null
  _log_error "HOOK_ERROR" "mktemp failed, using non-atomic write" "result_file=$RESULT_FILE"
  TMPFILE="$RESULT_FILE"
fi

local_task_id="${DOEY_TASK_ID:-}"
local_summary="${DOEY_SUMMARY:-}"
local_summary_escaped=$(printf '%s' "$local_summary" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g' -e 's/	/\\t/g')

cat > "$TMPFILE" <<EOF
{
  "pane": "$WINDOW_INDEX.$PANE_INDEX",
  "pane_id": "${DOEY_PANE_ID:-unknown}",
  "full_pane_id": "${DOEY_FULL_PANE_ID:-unknown}",
  "title": $TITLE_JSON,
  "status": "$STATUS",
  "timestamp": $(date +%s),
  "files_changed": $FILES_JSON,
  "tool_calls": $TOOL_COUNT,
  "last_output": $LAST_JSON,
  "task_id": "$local_task_id",
  "hypothesis_updates": ${DOEY_HYPOTHESIS_UPDATES:-[]},
  "evidence": ${DOEY_EVIDENCE:-[]},
  "needs_follow_up": ${DOEY_NEEDS_FOLLOW_UP:-false},
  "summary": "$local_summary_escaped"
}
EOF
[ "$TMPFILE" != "$RESULT_FILE" ] && mv "$TMPFILE" "$RESULT_FILE"
TMPFILE=""
_log "stop-results: wrote result to $RESULT_FILE (status=$STATUS, tools=$TOOL_COUNT)"

if [ -n "$local_task_id" ] && [ -n "$PROJECT_DIR" ] && [ -d "${PROJECT_DIR}/.doey/tasks" ]; then
  cp "$RESULT_FILE" "${PROJECT_DIR}/.doey/tasks/${local_task_id}.result.json" 2>/dev/null || true

  # Auto-attach result and research report to task
  _local_task_file="${PROJECT_DIR}/.doey/tasks/${local_task_id}.task"
  _result_att=".doey/tasks/${local_task_id}.result.json"
  _append_attachment "$_local_task_file" "$_result_att" 2>/dev/null || true

  _local_report="${RUNTIME_DIR}/reports/pane_${WINDOW_INDEX}_${PANE_INDEX}.report"
  if [ -f "$_local_report" ]; then
    _report_dest="${PROJECT_DIR}/.doey/tasks/${local_task_id}.report"
    cp "$_local_report" "$_report_dest" 2>/dev/null || true
    _report_att=".doey/tasks/${local_task_id}.report"
    _append_attachment "$_local_task_file" "$_report_att" 2>/dev/null || true
  fi

  # Write captured output as a task attachment (completion report)
  if [ -n "$FILTERED" ]; then
    _PANE_SAFE="${WINDOW_INDEX}_${PANE_INDEX}"
    _ATTACH_TS=$(date +%s)
    if [ -f "$PROJECT_DIR/shell/doey-task-helpers.sh" ] && \
       grep -q 'task_write_attachment' "$PROJECT_DIR/shell/doey-task-helpers.sh" 2>/dev/null; then
      # Use the helper if available
      # shellcheck disable=SC1091
      source "$PROJECT_DIR/shell/doey-task-helpers.sh" && \
        task_write_attachment "$PROJECT_DIR" "$local_task_id" "completion" \
          "Worker ${WINDOW_INDEX}.${PANE_INDEX} output" "$FILTERED" \
          "Worker_${_PANE_SAFE}" 2>/dev/null || true
    else
      # Fallback: write attachment directly
      _ATTACH_DIR="${PROJECT_DIR}/.doey/tasks/${local_task_id}/attachments"
      mkdir -p "$_ATTACH_DIR" 2>/dev/null || true
      _ATTACH_FILE="${_ATTACH_DIR}/${_ATTACH_TS}_completion_${_PANE_SAFE}.md"
      cat > "$_ATTACH_FILE" <<ATTACH_EOF
---
type: completion
title: Worker ${WINDOW_INDEX}.${PANE_INDEX} output
author: Worker_${_PANE_SAFE}
timestamp: ${_ATTACH_TS}
task_id: ${local_task_id}
---

${FILTERED}
ATTACH_EOF
      _attach_rel=".doey/tasks/${local_task_id}/attachments/${_ATTACH_TS}_completion_${_PANE_SAFE}.md"
      _append_attachment "$_local_task_file" "$_attach_rel" 2>/dev/null || true
    fi
  fi
fi

_FILES_COUNT=0
[ -n "$FILES_LIST" ] && _FILES_COUNT=$(printf '%s\n' "$FILES_LIST" | wc -l | tr -d ' ')
type _debug_log >/dev/null 2>&1 && _debug_log lifecycle "result_captured" "files_changed=${_FILES_COUNT}" "tool_calls=${TOOL_COUNT}"

COMPLETION="${RUNTIME_DIR}/status/completion_pane_${WINDOW_INDEX}_${PANE_INDEX}"
cat > "${COMPLETION}.tmp" <<COMPLETE
PANE_INDEX="$PANE_INDEX"
PANE_TITLE="$PANE_TITLE"
STATUS="$STATUS"
TIMESTAMP=$(date +%s)
COMPLETE
mv "${COMPLETION}.tmp" "$COMPLETION"
[ ! -f "$COMPLETION" ] && _log_error "HOOK_ERROR" "Completion event file not written" "path=$COMPLETION"

touch "${RUNTIME_DIR}/status/sm_trigger" 2>/dev/null || true  # wake SM
