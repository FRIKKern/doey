#!/usr/bin/env bash
# stop-reviewer-metrics.sh — Phase 0 reviewer metrics emission (task 591).
#
# WHY a dedicated hook (not piggy-backed on stop-results.sh)?
#   stop-results.sh gates on `is_worker` and returns early for core-team
#   panes. The Task Reviewer IS core-team (pane 1.1), so it never runs
#   through stop-results. Rather than drill a role-carve-out into that hook,
#   Phase 0 keeps metrics in a separate hook that is cheap, guarded to only
#   the reviewer pane, and easy to remove in later phases.
#
# Emits ONE JSONL row to both metric stores when the Task Reviewer finishes
# a turn. Fires ONLY when DOEY_ROLE_ID == task_reviewer. Other panes no-op.
#
# Row schema is documented in shell/doey-review-metrics.sh.

set -euo pipefail

source "$(dirname "$0")/common.sh"
init_named_hook "stop-reviewer-metrics" 2>/dev/null || true

# Guard: only the Task Reviewer pane (core team, pane index 1).
type is_task_reviewer >/dev/null 2>&1 || exit 0
is_task_reviewer || exit 0

# Locate the metrics emitter lib.
_rm_lib=""
for _cand in \
    "$(dirname "$0")/../../shell/doey-review-metrics.sh" \
    "$HOME/.local/bin/doey-review-metrics.sh"; do
  [ -f "$_cand" ] && { _rm_lib="$_cand"; break; }
done
[ -z "$_rm_lib" ] && exit 0
# shellcheck disable=SC1090
. "$_rm_lib"

PROJECT_DIR_RESOLVED=$(_resolve_project_dir 2>/dev/null || printf '')
[ -z "$PROJECT_DIR_RESOLVED" ] && [ -d "${CLAUDE_PROJECT_DIR:-}" ] && PROJECT_DIR_RESOLVED="$CLAUDE_PROJECT_DIR"

# Capture recent output — enough lines to find the last verdict block.
REVIEWER_OUT=$(tmux capture-pane -t "$PANE" -p -S -120 2>/dev/null) || REVIEWER_OUT=""

# Parse verdict: look for the most recent "REVIEW VERDICT: PASS|FAIL".
# Tolerates schema drift (task 559 wrote "accepted" instead of PASS).
_verdict_line=$(printf '%s\n' "$REVIEWER_OUT" \
  | grep -E 'REVIEW VERDICT:|review_verdict|verdict[= ]' \
  | tail -1)
_verdict=""
case "$_verdict_line" in
  *PASS*|*pass*|*accepted*|*ACCEPTED*|*Accepted*) _verdict="PASS" ;;
  *FAIL*|*fail*|*rejected*|*REJECTED*|*Rejected*) _verdict="FAIL" ;;
  *)                                               _verdict="UNKNOWN" ;;
esac

# Task / subtask id: try to scrape from pane output first (reviewer echoes
# "TASK: #<id>" in its verdict block), fall back to in-flight status files.
TASK_ID=$(printf '%s\n' "$REVIEWER_OUT" \
  | grep -Eo 'TASK[: ]+#?[0-9]+' \
  | tail -1 \
  | grep -Eo '[0-9]+' || true)
SUBTASK_ID=$(printf '%s\n' "$REVIEWER_OUT" \
  | grep -Eo 'SUBTASK[ _-]*ID[: =]+[0-9]+' \
  | tail -1 \
  | grep -Eo '[0-9]+' || true)
[ -z "$TASK_ID" ] && TASK_ID="unknown"
[ -z "$SUBTASK_ID" ] && SUBTASK_ID="-"

# Latency: mtime delta of the BUSY status file → now. stop-status writes
# READY/FINISHED after this hook chain, so the status file's last mtime is
# when the turn started (BUSY). Seconds → ms.
LATENCY_MS=0
_status_file="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
if [ -f "$_status_file" ]; then
  _start_s=$(stat -c %Y "$_status_file" 2>/dev/null || stat -f %m "$_status_file" 2>/dev/null || echo 0)
  _now_s=$(date +%s)
  if [ "$_start_s" -gt 0 ] 2>/dev/null; then
    _delta=$(( _now_s - _start_s ))
    [ "$_delta" -lt 0 ] && _delta=0
    LATENCY_MS=$(( _delta * 1000 ))
  fi
fi

# Payload size: length of the most recent review_request / subtask_review_request
# message addressed to the reviewer pane. Best-effort via doey msg list --json.
PAYLOAD_BYTES=0
if command -v doey >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  _me_pane_id="${DOEY_PANE_ID:-doey_doey_1_1}"
  _last_body=$(doey msg list --json 2>/dev/null \
    | jq -r --arg me "$_me_pane_id" '
        [ .[]
          | select(.to_pane == $me)
          | select(.subject == "review_request" or .subject == "subtask_review_request")
        ] | last | .body // empty
      ' 2>/dev/null) || _last_body=""
  if [ -n "$_last_body" ]; then
    PAYLOAD_BYTES=$(printf '%s' "$_last_body" | wc -c | tr -d ' ')
  fi
fi

# Worker proof type: from the result JSON for this task, if present.
PROOF_TYPE="unknown"
if [ -n "$PROJECT_DIR_RESOLVED" ] && [ "$TASK_ID" != "unknown" ]; then
  _result_json="${PROJECT_DIR_RESOLVED}/.doey/tasks/${TASK_ID}.result.json"
  if [ -f "$_result_json" ] && command -v jq >/dev/null 2>&1; then
    PROOF_TYPE=$(jq -r '.proof_type // .PROOF_TYPE // "unknown"' "$_result_json" 2>/dev/null || printf 'unknown')
    [ -z "$PROOF_TYPE" ] && PROOF_TYPE="unknown"
  fi
fi

REVIEWER_PANE="${WINDOW_INDEX:-1}.${PANE_INDEX:-1}"

doey_review_metrics_emit \
  "$TASK_ID" \
  "$SUBTASK_ID" \
  "$REVIEWER_PANE" \
  "$_verdict" \
  "$LATENCY_MS" \
  "$PAYLOAD_BYTES" \
  "$PROOF_TYPE" \
  "$PROJECT_DIR_RESOLVED" \
  "${RUNTIME_DIR:-}" \
  2>/dev/null || true

exit 0
