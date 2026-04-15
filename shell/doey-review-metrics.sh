#!/usr/bin/env bash
# doey-review-metrics.sh — Reviewer metrics store (Phase 0 of reviewer upgrade, task 591)
#
# SCHEMA (one JSONL row per reviewer completion):
#   {
#     "task_id":             <int|str>,     # task id from .task file
#     "subtask_id":          <int|str|null>,# subtask id if this was a subtask review
#     "reviewer_pane":       <str>,         # e.g. "1.1"
#     "verdict":             "PASS|FAIL",   # normalized; schema drift → "UNKNOWN"
#     "reviewer_latency_ms": <int>,         # wall clock of the review turn
#     "payload_size_bytes":  <int>,         # size of the review_request body
#     "worker_proof_type":   <str>,         # proof type from result JSON, or "unknown"
#     "timestamp_iso":       <str>,         # UTC ISO8601 of emission
#     "reverted_after_pass": <bool>         # backfilled later; default false
#   }
#
# TWO STORES (both written on every emit):
#   runtime:    $RUNTIME_DIR/metrics/reviews.jsonl       # ephemeral, /tmp/doey/<project>/
#   persistent: <project>/.doey/metrics/reviews.jsonl    # survives reboots
#
# Used by:
#   - .claude/hooks/stop-results.sh      (emits rows on reviewer stop)
#   - shell/reviewer-baseline.sh         (emits rows for historical replays)
#   - shell/doey-reviewer.sh             (reads both stores for `doey reviewer stats`)

set -euo pipefail

# Resolve both metric file paths. Caller must set PROJECT_DIR and RUNTIME_DIR,
# or pass them as $1 and $2. Echoes two lines: runtime path, persistent path.
doey_review_metrics_paths() {
  local project_dir="${1:-${PROJECT_DIR:-}}"
  local runtime_dir="${2:-${RUNTIME_DIR:-}}"
  if [ -z "$runtime_dir" ] && [ -n "$project_dir" ]; then
    runtime_dir="/tmp/doey/$(basename "$project_dir")"
  fi
  local runtime_file="${runtime_dir}/metrics/reviews.jsonl"
  local persist_file=""
  [ -n "$project_dir" ] && persist_file="${project_dir}/.doey/metrics/reviews.jsonl"
  printf '%s\n%s\n' "$runtime_file" "$persist_file"
}

# JSON-escape a string value (bash 3.2 safe).
_doey_rm_jsonesc() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Normalize a free-form verdict string → PASS | FAIL | UNKNOWN.
doey_review_metrics_normalize_verdict() {
  local v="${1:-}"
  v=$(printf '%s' "$v" | tr '[:lower:]' '[:upper:]')
  case "$v" in
    *PASS*|ACCEPT|ACCEPTED|APPROVE|APPROVED|OK)  printf 'PASS' ;;
    *FAIL*|REJECT|REJECTED|BLOCK|BLOCKED)         printf 'FAIL' ;;
    *)                                             printf 'UNKNOWN' ;;
  esac
}

# doey_review_metrics_emit <task_id> <subtask_id|-> <reviewer_pane> <verdict> \
#                          <latency_ms> <payload_bytes> <worker_proof_type> [project_dir] [runtime_dir]
# Returns 0 on success, non-zero only on unrecoverable error (missing project dir).
doey_review_metrics_emit() {
  local task_id="${1:-}"
  local subtask_id="${2:--}"
  local reviewer_pane="${3:-}"
  local verdict
  verdict=$(doey_review_metrics_normalize_verdict "${4:-}")
  local latency_ms="${5:-0}"
  local payload_bytes="${6:-0}"
  local proof_type="${7:-unknown}"
  local project_dir="${8:-${PROJECT_DIR:-}}"
  local runtime_dir="${9:-${RUNTIME_DIR:-}}"

  case "$latency_ms"    in ''|*[!0-9]*) latency_ms=0 ;; esac
  case "$payload_bytes" in ''|*[!0-9]*) payload_bytes=0 ;; esac
  [ -z "$proof_type" ] && proof_type="unknown"

  local ts_iso
  ts_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)

  local task_j subj_j pane_j proof_j
  task_j=$(_doey_rm_jsonesc "$task_id")
  pane_j=$(_doey_rm_jsonesc "$reviewer_pane")
  proof_j=$(_doey_rm_jsonesc "$proof_type")

  local subtask_field
  if [ -z "$subtask_id" ] || [ "$subtask_id" = "-" ] || [ "$subtask_id" = "null" ]; then
    subtask_field='null'
  else
    subj_j=$(_doey_rm_jsonesc "$subtask_id")
    subtask_field="\"${subj_j}\""
  fi

  local row
  row=$(printf '{"task_id":"%s","subtask_id":%s,"reviewer_pane":"%s","verdict":"%s","reviewer_latency_ms":%s,"payload_size_bytes":%s,"worker_proof_type":"%s","timestamp_iso":"%s","reverted_after_pass":false}' \
    "$task_j" "$subtask_field" "$pane_j" "$verdict" "$latency_ms" "$payload_bytes" "$proof_j" "$ts_iso")

  local paths runtime_file persist_file
  paths=$(doey_review_metrics_paths "$project_dir" "$runtime_dir") || return 1
  runtime_file=$(printf '%s\n' "$paths" | sed -n '1p')
  persist_file=$(printf '%s\n' "$paths" | sed -n '2p')

  if [ -n "$runtime_file" ]; then
    mkdir -p "$(dirname "$runtime_file")" 2>/dev/null || true
    printf '%s\n' "$row" >> "$runtime_file" 2>/dev/null || true
  fi
  if [ -n "$persist_file" ]; then
    mkdir -p "$(dirname "$persist_file")" 2>/dev/null || true
    printf '%s\n' "$row" >> "$persist_file" 2>/dev/null || true
  fi
  return 0
}

# When executed directly: CLI for testing/backfill.
#   doey-review-metrics.sh emit <task_id> <subtask|-> <pane> <verdict> <latency> <bytes> <proof>
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  case "${1:-}" in
    emit) shift; doey_review_metrics_emit "$@" ;;
    paths) shift; doey_review_metrics_paths "$@" ;;
    *)
      printf 'usage: doey-review-metrics.sh {emit|paths} ...\n' >&2
      exit 1
      ;;
  esac
fi
