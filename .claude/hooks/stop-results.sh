#!/usr/bin/env bash
# Stop hook: capture worker results and write completion event (async)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "stop-results"

mkdir -p "${RUNTIME_DIR}/errors" 2>/dev/null || true
trap '_err=$?; printf "[%s] ERR in stop-results at line %s (exit %s)\n" "$(date +%H:%M:%S)" "$LINENO" "$_err" >> "${RUNTIME_DIR}/errors/errors.log" 2>/dev/null; exit 0' ERR

is_worker || exit 0

mkdir -p "$RUNTIME_DIR/tasks" 2>/dev/null || true

RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
TMPFILE=""
trap '[ -n "${TMPFILE:-}" ] && rm -f "$TMPFILE" 2>/dev/null' EXIT

_append_attachment() {
  local task_file="$1" att_path="$2"
  [ -f "$task_file" ] || return 0
  local current; current=$(grep '^TASK_ATTACHMENTS=' "$task_file" 2>/dev/null | head -1 | cut -d= -f2-) || current=""
  case "|${current}|" in *"|${att_path}|"*) return 0 ;; esac
  local new_val="${att_path}"; [ -n "$current" ] && new_val="${current}|${att_path}"
  local tmp_att="${task_file}.tmp.$$"
  if grep -q '^TASK_ATTACHMENTS=' "$task_file" 2>/dev/null; then
    sed "s|^TASK_ATTACHMENTS=.*|TASK_ATTACHMENTS=${new_val}|" "$task_file" > "$tmp_att" && mv "$tmp_att" "$task_file"
  else
    cp "$task_file" "$tmp_att" && echo "TASK_ATTACHMENTS=${new_val}" >> "$tmp_att" && mv "$tmp_att" "$task_file"
  fi
}

OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -80 2>/dev/null) || OUTPUT=""
[ -z "$OUTPUT" ] && _log_error "HOOK_ERROR" "tmux capture-pane returned empty" "pane=$PANE"

PROJECT_DIR=$(_resolve_project_dir)
FILES_LIST=""
if [ -n "$PROJECT_DIR" ]; then
  _to=""; command -v timeout >/dev/null 2>&1 && _to="timeout 2"; command -v gtimeout >/dev/null 2>&1 && _to="gtimeout 2"
  FILES_LIST=$(cd "$PROJECT_DIR" 2>/dev/null && $_to git diff --name-only HEAD 2>/dev/null | head -20) || FILES_LIST=""
  [ -z "$FILES_LIST" ] && _log "stop-results: git diff empty"
fi
FILES_JSON="[]"
if [ -n "$FILES_LIST" ]; then
  FILES_JSON=$(echo "$FILES_LIST" | jq -R '.' | jq -s '.' 2>/dev/null) || FILES_JSON="[]"
fi

FILTERED=""
STATUS="done"
TOOL_COUNT=0
# Pass 1: build FILTERED output and count tools (no error detection here)
while IFS= read -r line; do
  case "$line" in
    *"Read("*|*"Edit("*|*"Write("*|*"Bash("*|*"Grep("*|*"Glob("*|*"Agent("*) TOOL_COUNT=$((TOOL_COUNT + 1)) ;;
  esac
  case "$line" in
    *"❯"*|*"───"*|*"Ctx █"*|*"bypass permissions"*|*"shift+tab"*|*"MCP server"*|*/doctor*) continue ;;
  esac
  FILTERED="${FILTERED}${line}${NL}"
done <<HEREDOC_EOF
$OUTPUT
HEREDOC_EOF

# Pass 2: check only last 8 lines for genuine errors (avoids false positives
# from session-start messages, error mentions in code discussion, file names, etc.)
_tail_lines=$(printf '%s' "$FILTERED" | tail -8)
_found_error=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Skip known false-positive patterns
  case "$line" in
    *"startup hook"*|*"SessionStart"*|*"hook error"*) continue ;;
    *"_log_error"*|*"log_error"*) continue ;;
    *"ErrorBoundary"*|*"error.go"*|*"errors.ts"*|*"error.ts"*) continue ;;
    *"0 "*[Ff]ailed*|*"no "[Ee]rror*) continue ;;
    *"stop hooks"*) continue ;;
  esac
  case "$line" in
    *[Ee]rror*|*ERROR*|*[Ff]ailed*|*FAILED*|*[Ee]xception*|*EXCEPTION*) _found_error="true"; break ;;
  esac
done <<HEREDOC_TAIL
$_tail_lines
HEREDOC_TAIL

# Positive completion signals override incidental error mentions
if [ "$_found_error" = "true" ]; then
  case "$_tail_lines" in
    *"completed"*|*"successfully"*|*"All tests passed"*|*"Done"*|*"Finished"*) _found_error="" ;;
  esac
fi
[ "$_found_error" = "true" ] && STATUS="error"

# Extract proof fields from captured output
PROOF_TYPE=""
PROOF_CONTENT=""
_proof_line=$(printf '%s' "$FILTERED" | grep '^PROOF_TYPE:' | tail -1) || true
if [ -n "$_proof_line" ]; then
  PROOF_TYPE=$(printf '%s' "$_proof_line" | sed 's/^PROOF_TYPE:[[:space:]]*//')
fi
_proof_body=$(printf '%s' "$FILTERED" | grep '^PROOF:' | tail -1) || true
if [ -n "$_proof_body" ]; then
  PROOF_CONTENT=$(printf '%s' "$_proof_body" | sed 's/^PROOF:[[:space:]]*//')
fi

# Fallback: auto-generate proof if worker didn't emit one
if [ -z "$PROOF_TYPE" ]; then
  PROOF_TYPE="agent"
  _fallback_summary="${DOEY_SUMMARY:-}"
  if [ -n "$_fallback_summary" ]; then
    PROOF_CONTENT="Task completed — $_fallback_summary"
  else
    PROOF_CONTENT="Task completed — no summary available"
  fi
fi

PANE_TITLE=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="worker-$PANE_INDEX"
LAST_JSON=$(printf '%s' "$FILTERED" | jq -Rs '.' 2>/dev/null) || \
  LAST_JSON=$(printf '%s' "$FILTERED" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || \
  LAST_JSON='""'
TITLE_JSON=$(printf '%s' "$PANE_TITLE" | jq -Rs '.' 2>/dev/null) || TITLE_JSON='"worker-'"$PANE_INDEX"'"'
PROOF_TYPE_JSON=$(printf '%s' "$PROOF_TYPE" | jq -Rs '.' 2>/dev/null) || PROOF_TYPE_JSON='""'
PROOF_CONTENT_JSON=$(printf '%s' "$PROOF_CONTENT" | jq -Rs '.' 2>/dev/null) || PROOF_CONTENT_JSON='""'

# Extract verification steps from VERIFICATION_STEP: lines into JSON array
VERIFICATION_STEPS_JSON="[]"
_vsteps=$(printf '%s' "$FILTERED" | grep '^VERIFICATION_STEP:' | sed 's/^VERIFICATION_STEP:[[:space:]]*//' ) || true
if [ -n "$_vsteps" ]; then
  VERIFICATION_STEPS_JSON=$(printf '%s\n' "$_vsteps" | jq -Rsc '[.]' 2>/dev/null) || true
  # jq -Rsc with single input gives ["all\nlines"] — split properly
  VERIFICATION_STEPS_JSON=$(printf '%s\n' "$_vsteps" | jq -Rs 'split("\n") | map(select(length > 0))' 2>/dev/null) || VERIFICATION_STEPS_JSON="[]"
fi

TMPFILE=$(mktemp "${RUNTIME_DIR}/results/.tmp_XXXXXX" 2>/dev/null)
if [ -z "$TMPFILE" ] || [ ! -f "$TMPFILE" ]; then
  echo "[WARN] mktemp failed in $(basename "$0") — writing non-atomically" >> "${RUNTIME_DIR}/doey-warnings.log" 2>/dev/null
  _log_error "HOOK_ERROR" "mktemp failed, using non-atomic write" "result_file=$RESULT_FILE"
  TMPFILE="$RESULT_FILE"
fi

local_task_id="${DOEY_TASK_ID:-}"
# Fallback: read task ID persisted by on-prompt-submit
if [ -z "$local_task_id" ]; then
  local_task_id=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.task_id" 2>/dev/null) || local_task_id=""
fi
local_subtask_id=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.subtask_id" 2>/dev/null) || local_subtask_id=""
# Note: task_id/subtask_id files preserved for parallel async hooks
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
  "subtask_id": "$local_subtask_id",
  "hypothesis_updates": ${DOEY_HYPOTHESIS_UPDATES:-[]},
  "evidence": ${DOEY_EVIDENCE:-[]},
  "needs_follow_up": ${DOEY_NEEDS_FOLLOW_UP:-false},
  "summary": "$local_summary_escaped",
  "proof_type": $PROOF_TYPE_JSON,
  "proof_content": $PROOF_CONTENT_JSON,
  "verification_steps": $VERIFICATION_STEPS_JSON
}
EOF
[ "$TMPFILE" != "$RESULT_FILE" ] && mv "$TMPFILE" "$RESULT_FILE"
TMPFILE=""
_log "stop-results: wrote result to $RESULT_FILE (status=$STATUS, tools=$TOOL_COUNT)"

if [ -n "$local_task_id" ] && [ -n "$PROJECT_DIR" ] && [ -d "${PROJECT_DIR}/.doey/tasks" ]; then
  cp "$RESULT_FILE" "${PROJECT_DIR}/.doey/tasks/${local_task_id}.result.json" 2>/dev/null || true
  _local_task_file="${PROJECT_DIR}/.doey/tasks/${local_task_id}.task"
  _append_attachment "$_local_task_file" ".doey/tasks/${local_task_id}.result.json" 2>/dev/null || true

  _local_report="${RUNTIME_DIR}/reports/pane_${WINDOW_INDEX}_${PANE_INDEX}.report"
  if [ -f "$_local_report" ]; then
    cp "$_local_report" "${PROJECT_DIR}/.doey/tasks/${local_task_id}.report" 2>/dev/null || true
    _append_attachment "$_local_task_file" ".doey/tasks/${local_task_id}.report" 2>/dev/null || true
  fi

  if [ -n "$FILTERED" ]; then
    _PANE_SAFE="${WINDOW_INDEX}_${PANE_INDEX}"
    _ATTACH_TS=$(date +%s)
    _ATTACH_DIR="${PROJECT_DIR}/.doey/tasks/${local_task_id}/attachments"
    mkdir -p "$_ATTACH_DIR" 2>/dev/null || true
    cat > "${_ATTACH_DIR}/${_ATTACH_TS}_completion_${_PANE_SAFE}.md" 2>/dev/null <<ATTACH_EOF
---
type: completion
title: ${DOEY_ROLE_WORKER} ${WINDOW_INDEX}.${PANE_INDEX} output
author: ${DOEY_ROLE_WORKER}_${_PANE_SAFE}
timestamp: ${_ATTACH_TS}
task_id: ${local_task_id}
---

${FILTERED}
ATTACH_EOF
    _append_attachment "$_local_task_file" ".doey/tasks/${local_task_id}/attachments/${_ATTACH_TS}_completion_${_PANE_SAFE}.md" 2>/dev/null || true
  fi

  # Copy research reports to persistent task attachments
  _RES_DIR="${RUNTIME_DIR}/research"
  if [ -d "$_RES_DIR" ]; then
    _RES_PANE="${WINDOW_INDEX}_${PANE_INDEX}"
    _RES_ATTACH_DIR="${PROJECT_DIR}/.doey/tasks/${local_task_id}/attachments"
    mkdir -p "$_RES_ATTACH_DIR" 2>/dev/null || true
    _RES_TS=$(date +%s)
    for _rfile in "${_RES_DIR}/task_${local_task_id}"*.md "${_RES_DIR}/${_RES_PANE}"*.md "${_RES_DIR}/pane_${_RES_PANE}"*.md; do
      [ -f "$_rfile" ] || continue
      _rbase=$(basename "$_rfile")
      _rdest_name="${_RES_TS}_research_${_rbase}"
      _rdest="${_RES_ATTACH_DIR}/${_rdest_name}"
      [ -f "$_rdest" ] && continue
      {
        printf '%s\n' "---"
        printf '%s\n' "type: research"
        printf 'title: Research report from %s %s.%s\n' "${DOEY_ROLE_WORKER:-Worker}" "$WINDOW_INDEX" "$PANE_INDEX"
        printf 'author: %s_%s\n' "${DOEY_ROLE_WORKER:-Worker}" "$_RES_PANE"
        printf 'timestamp: %s\n' "$_RES_TS"
        printf 'task_id: %s\n' "$local_task_id"
        printf 'source: %s\n' "$_rbase"
        printf '%s\n' "---"
        printf '\n'
        cat "$_rfile"
      } > "$_rdest" 2>/dev/null || true
      _append_attachment "$_local_task_file" ".doey/tasks/${local_task_id}/attachments/${_rdest_name}" 2>/dev/null || true
    done
  fi

  # Compute files changed count before subshell (value would be lost inside)
  _FILES_COUNT=0
  [ -n "$FILES_LIST" ] && _FILES_COUNT=$(printf '%s\n' "$FILES_LIST" | wc -l | tr -d ' ')

  # Add completion report to task (Task Accountability)
  if [ -f "${PROJECT_DIR}/shell/doey-task-helpers.sh" ]; then
    (
      source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
      _rpt_body="${local_summary:-Worker ${WINDOW_INDEX}.${PANE_INDEX} completed with ${TOOL_COUNT} tool calls, ${_FILES_COUNT:-0} files changed}"
      doey_task_add_report "$PROJECT_DIR" "$local_task_id" "completion" \
        "Worker ${WINDOW_INDEX}.${PANE_INDEX} ${STATUS}" "$_rpt_body" \
        "worker_${WINDOW_INDEX}_${PANE_INDEX}"
    ) 2>/dev/null || true
  fi

  # Import proof fields into SQLite (task #275)
  if command -v doey-ctl >/dev/null 2>&1; then
    (
      [ -n "$PROOF_TYPE" ] && doey-ctl task update --id "$local_task_id" --field proof_type --value "$PROOF_TYPE" --project-dir "$PROJECT_DIR" 2>/dev/null || true
      [ -n "$PROOF_CONTENT" ] && doey-ctl task update --id "$local_task_id" --field proof_content --value "$PROOF_CONTENT" --project-dir "$PROJECT_DIR" 2>/dev/null || true
      [ "$VERIFICATION_STEPS_JSON" != "[]" ] && doey-ctl task update --id "$local_task_id" --field verification_steps --value "$VERIFICATION_STEPS_JSON" --project-dir "$PROJECT_DIR" 2>/dev/null || true
      if [ -n "$FILES_LIST" ]; then
        _files_csv=$(printf '%s' "$FILES_LIST" | tr '\n' ',' | sed 's/,$//')
        doey-ctl task update --id "$local_task_id" --field files --value "$_files_csv" --project-dir "$PROJECT_DIR" 2>/dev/null || true
      fi
    ) &
  fi
fi

type _debug_log >/dev/null 2>&1 && _debug_log lifecycle "result_captured" "files_changed=${_FILES_COUNT}" "tool_calls=${TOOL_COUNT}"
write_activity "task_completed" "{\"status\":\"${STATUS}\",\"tools\":${TOOL_COUNT},\"files\":${_FILES_COUNT}}"

# Emit result_captured event to TUI event log (fire-and-forget)
if command -v doey >/dev/null 2>&1; then
  (doey event log --type result_captured --source "$PANE" --message "Result: ${_FILES_COUNT} files, ${TOOL_COUNT} tools" &) 2>/dev/null
fi

COMPLETION="${RUNTIME_DIR}/status/completion_pane_${WINDOW_INDEX}_${PANE_INDEX}"
cat > "${COMPLETION}.tmp" <<COMPLETE
PANE_INDEX="$PANE_INDEX"
PANE_TITLE="$PANE_TITLE"
STATUS="$STATUS"
TIMESTAMP=$(date +%s)
COMPLETE
mv "${COMPLETION}.tmp" "$COMPLETION"
[ ! -f "$COMPLETION" ] && _log_error "HOOK_ERROR" "Completion event file not written" "path=$COMPLETION"

# Update .task file to error if errors detected (stop-status.sh already set "done")
if [ "$STATUS" = "error" ] && [ -n "$local_task_id" ] && [ -n "$PROJECT_DIR" ]; then
  if [ -f "${PROJECT_DIR}/shell/doey-task-helpers.sh" ]; then
    (
      source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
      _task_file="${PROJECT_DIR}/.doey/tasks/${local_task_id}.task"
      [ -f "$_task_file" ] && task_update_field "$_task_file" "TASK_STATUS" "error"
      if [ -n "$local_subtask_id" ]; then
        doey_task_update_subtask "$PROJECT_DIR" "$local_task_id" "$local_subtask_id" "failed"
      fi
    ) 2>/dev/null || true
  fi
fi

# Auto-rebuild doey CLI tools if Go sources changed
case "$FILES_LIST" in
  *tui/cmd/doey-ctl/*.go*|*tui/internal/store/*.go*)
    if [ -x /usr/local/go/bin/go ] && [ -d "${PROJECT_DIR}/tui" ]; then
      mkdir -p "$HOME/.local/bin"
      (cd "${PROJECT_DIR}/tui" && /usr/local/go/bin/go build -o "$HOME/.local/bin/doey-ctl" ./cmd/doey-ctl/) 2>/dev/null \
        || echo "doey CLI tools auto-build failed" >&2
    fi
    ;;
esac

# Taskmaster wake trigger removed — stop-notify.sh is the sole wake source
