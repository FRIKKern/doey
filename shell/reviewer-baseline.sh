#!/usr/bin/env bash
# reviewer-baseline.sh — Phase 0 of reviewer upgrade (task 591).
#
# Replays the current reviewer against N historical tasks known to have had
# bugs missed at review time. Synthesizes a review_request body from each
# task file + the task's commit window, pipes it through `claude -p` with
# the doey-task-reviewer agent, captures verdict/latency/payload, writes
# rows into the Phase 0 metrics store, and emits a markdown report.
#
# Usage:
#   reviewer-baseline.sh                # defaults to known-buggy task set
#   reviewer-baseline.sh 446 452 464    # custom task ids
#   DRY_RUN=1 reviewer-baseline.sh ...  # build payloads but skip claude
#   MAX_TASKS=3 reviewer-baseline.sh    # cap number of tasks replayed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load the metrics emitter.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/doey-review-metrics.sh"

# Default to the known-buggy set from the task brief.
DEFAULT_IDS="446 452 464 525 536"
TASK_IDS="${*:-$DEFAULT_IDS}"
MAX_TASKS="${MAX_TASKS:-5}"
DRY_RUN="${DRY_RUN:-0}"

RUNTIME_DIR="/tmp/doey/$(basename "$PROJECT_DIR")"
mkdir -p "$RUNTIME_DIR/metrics" "$RUNTIME_DIR/results" 2>/dev/null || true

STAMP="$(date +%Y%m%d)"
REPORT="$RUNTIME_DIR/results/reviewer_baseline_${STAMP}.md"

_log() { printf '[baseline] %s\n' "$*" >&2; }

_timeout_bin=""
command -v timeout >/dev/null 2>&1 && _timeout_bin="timeout"
command -v gtimeout >/dev/null 2>&1 && _timeout_bin="gtimeout"

_claude_bin=""
command -v claude >/dev/null 2>&1 && _claude_bin="claude"

_task_field() {
  local task_file="$1" field="$2"
  grep -m1 "^${field}=" "$task_file" 2>/dev/null | sed "s/^${field}=//"
}

# Build a synthetic review_request body matching what the reviewer historically
# received: task brief, acceptance criteria, files changed, worker output
# placeholder. Written to a tmpfile; path echoed on stdout.
_build_payload() {
  local task_file="$1" task_id="$2"
  local title desc files updated
  title=$(_task_field "$task_file" TASK_TITLE)
  desc=$(_task_field  "$task_file" TASK_DESCRIPTION)
  files=$(_task_field "$task_file" TASK_FILES)
  updated=$(_task_field "$task_file" TASK_UPDATED)

  # Find the commit(s) that touched this task, best-effort. We look for the
  # task id in commit messages OR touched files named after the task.
  local commits=""
  if [ -d "$PROJECT_DIR/.git" ]; then
    commits=$(cd "$PROJECT_DIR" && git log --oneline --grep="task ${task_id}\b" --grep="#${task_id}\b" --grep="task ${task_id}:" -i 2>/dev/null | head -5 || true)
  fi

  # Synthetic worker output: git show stat for the last matching commit.
  local worker_output="(historical replay — no live worker output)"
  local first_commit
  first_commit=$(printf '%s\n' "$commits" | awk 'NR==1 {print $1}')
  if [ -n "$first_commit" ]; then
    worker_output=$(cd "$PROJECT_DIR" && git show --stat "$first_commit" 2>/dev/null | head -40 || true)
  fi

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/baseline_payload_${task_id}.XXXXXX")
  {
    printf 'TASK_ID=%s\n' "$task_id"
    printf 'TITLE=%s\n' "$title"
    printf 'FILES_CHANGED=%s\n' "$files"
    printf 'COMMIT_WINDOW=%s\n' "${first_commit:-unknown}"
    printf 'WORKER_PROOF=%s\n' "(historical)"
    printf '\nTASK_DESCRIPTION:\n%s\n' "$desc"
    printf '\nWORKER_OUTPUT:\n%s\n' "$worker_output"
    printf '\nHISTORICAL_COMMITS:\n%s\n' "$commits"
    printf '\nREPLAY_INSTRUCTIONS:\nYou are being replayed on a historical task for baseline measurement. Read the files listed in FILES_CHANGED at their current state. Produce a REVIEW VERDICT: PASS or FAIL per your normal review protocol.\n'
  } > "$tmp"
  printf '%s' "$tmp"
}

_run_reviewer() {
  local payload_file="$1"
  if [ "$DRY_RUN" = "1" ] || [ -z "$_claude_bin" ]; then
    # Deterministic synthetic verdict so the harness still exercises the
    # emit/report path when claude is unavailable or we want a dry run.
    printf 'REVIEW VERDICT: PASS (dry-run synthetic)\n'
    return 0
  fi
  local cmd=""
  if [ -n "$_timeout_bin" ]; then
    cmd="$_timeout_bin 240 $_claude_bin -p --model sonnet --agent doey-task-reviewer --no-session-persistence --max-turns 8 --output-format text"
  else
    cmd="$_claude_bin -p --model sonnet --agent doey-task-reviewer --no-session-persistence --max-turns 8 --output-format text"
  fi
  cat "$payload_file" | eval "$cmd" 2>/dev/null || printf 'REVIEW VERDICT: UNKNOWN (claude invocation failed)\n'
}

_extract_verdict() {
  local out="$1"
  local line
  line=$(printf '%s\n' "$out" | grep -E 'REVIEW VERDICT:|verdict' | tail -1)
  case "$line" in
    *PASS*|*pass*)     printf 'PASS' ;;
    *FAIL*|*fail*)     printf 'FAIL' ;;
    *)                 printf 'UNKNOWN' ;;
  esac
}

# Report header.
{
  printf '# Reviewer baseline report — %s\n\n' "$STAMP"
  printf 'Task 591 Phase 0 · historical replay of known-buggy tasks against the current reviewer.\n\n'
  printf '| task_id | title | verdict | latency_ms | payload_bytes | expected |\n'
  printf '|---------|-------|---------|------------|---------------|----------|\n'
} > "$REPORT"

TOTAL=0
PASS=0
FAIL=0
UNKNOWN=0
REPLAYED_IDS=""

for tid in $TASK_IDS; do
  [ "$TOTAL" -ge "$MAX_TASKS" ] && break
  task_file="$PROJECT_DIR/.doey/tasks/${tid}.task"
  if [ ! -f "$task_file" ]; then
    _log "skip: $tid.task not found"
    continue
  fi

  title=$(_task_field "$task_file" TASK_TITLE)
  _log "replaying task ${tid}: ${title:0:60}"

  payload=$(_build_payload "$task_file" "$tid")
  bytes=$(wc -c < "$payload" | tr -d ' ')

  start_s=$(date +%s)
  reviewer_out=$(_run_reviewer "$payload")
  end_s=$(date +%s)
  latency_ms=$(( (end_s - start_s) * 1000 ))

  verdict=$(_extract_verdict "$reviewer_out")

  rm -f "$payload" 2>/dev/null || true

  TOTAL=$((TOTAL + 1))
  case "$verdict" in
    PASS)    PASS=$((PASS + 1)) ;;
    FAIL)    FAIL=$((FAIL + 1)) ;;
    *)       UNKNOWN=$((UNKNOWN + 1)) ;;
  esac
  REPLAYED_IDS="${REPLAYED_IDS} ${tid}"

  # Emit a metrics row tagged as a historical replay.
  doey_review_metrics_emit \
    "$tid" \
    "replay" \
    "baseline" \
    "$verdict" \
    "$latency_ms" \
    "$bytes" \
    "historical_replay" \
    "$PROJECT_DIR" \
    "$RUNTIME_DIR" \
    2>/dev/null || true

  # Append row to the report table.
  title_short=${title:0:60}
  printf '| %s | %s | %s | %s | %s | known-buggy (FAIL) |\n' \
    "$tid" "${title_short//|/\\|}" "$verdict" "$latency_ms" "$bytes" >> "$REPORT"
done

# Aggregates & notes.
{
  printf '\n## Aggregates\n\n'
  printf -- '- Total replayed: %s\n' "$TOTAL"
  printf -- '- PASS: %s\n' "$PASS"
  printf -- '- FAIL: %s\n' "$FAIL"
  printf -- '- UNKNOWN: %s\n' "$UNKNOWN"
  if [ "$TOTAL" -gt 0 ]; then
    pct=$(awk -v p="$PASS" -v t="$TOTAL" 'BEGIN { printf "%.1f", (p/t)*100 }')
    printf -- '- PASS rate: %s%%\n' "$pct"
  fi
  printf '\n## Interpretation\n\n'
  printf 'Every task in the replay set is KNOWN BUGGY — the reviewer PASSing any of them\n'
  printf 'is evidence of rubber-stamping. A healthy reviewer should FAIL the majority.\n'
  printf 'PASSes on this set are the signal Phase 0 exists to measure.\n'
  printf '\nTasks replayed:%s\n' "$REPLAYED_IDS"
  if [ "$DRY_RUN" = "1" ] || [ -z "$_claude_bin" ]; then
    printf '\n> **Note:** DRY_RUN or no `claude` binary — verdicts are synthetic.\n'
  fi
} >> "$REPORT"

_log "report: $REPORT"
printf '%s\n' "$REPORT"
