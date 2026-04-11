#!/usr/bin/env bash
# plan-to-tasks.sh — convert a masterplan markdown file into Doey tasks+subtasks
#
# Usage: plan-to-tasks.sh [--plan PATH] [--parent TASK_ID] [--dry-run]
#
# Refuses to proceed unless the plan's consensus.state file reports
# CONSENSUS_STATE=CONSENSUS. One task is created per phase (### Phase N:),
# one subtask per step (numbered items or "- [ ]" checkboxes inside the phase).
#
# Exit codes:
#   0  success (or dry-run)
#   1  usage / unexpected error
#   2  plan file missing or unreadable
#   3  CONSENSUS_STATE is not CONSENSUS (or state file missing)

set -euo pipefail

plan_path=""
parent_id=""
dry_run=0

_err() { printf 'plan-to-tasks: %s\n' "$*" >&2; }

_usage() {
  cat <<'USG'
Usage: doey plan to-tasks [--plan PATH] [--parent TASK_ID] [--dry-run]

  --plan PATH     Path to masterplan markdown file (default: newest
                  .doey/plans/masterplan-*.md in CWD).
  --parent ID     Record this task ID as the parent of all created tasks
                  (stored in task description).
  --dry-run       Print what would be created without calling doey task.

Refuses unless consensus.state reports CONSENSUS_STATE=CONSENSUS.
USG
}

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) shift; plan_path="${1:-}" ;;
    --parent) shift; parent_id="${1:-}" ;;
    --dry-run) dry_run=1 ;;
    -h|--help) _usage; exit 0 ;;
    *) _err "unknown flag: $1"; _usage >&2; exit 1 ;;
  esac
  shift || true
done

# Default plan: newest .doey/plans/masterplan-*.md
if [ -z "$plan_path" ]; then
  newest=""
  for f in .doey/plans/masterplan-*.md; do
    [ -f "$f" ] || continue
    if [ -z "$newest" ] || [ "$f" \> "$newest" ]; then
      newest="$f"
    fi
  done
  plan_path="$newest"
fi

if [ -z "$plan_path" ] || [ ! -f "$plan_path" ]; then
  _err "plan file not found: ${plan_path:-<none>}"
  exit 2
fi

plan_dir="$(cd "$(dirname "$plan_path")" && pwd)"
plan_base="$(basename "$plan_path" .md)"

# Locate consensus.state (sidecar, then subdir, then /tmp runtime layout).
state_file=""
for candidate in \
  "${plan_dir}/consensus.state" \
  "${plan_dir}/${plan_base}/consensus.state" \
  "${plan_dir}/${plan_base}.state"; do
  if [ -f "$candidate" ]; then
    state_file="$candidate"
    break
  fi
done

if [ -z "$state_file" ] && [ -n "${DOEY_RUNTIME_DIR:-}" ]; then
  candidate="${DOEY_RUNTIME_DIR}/${plan_base}/consensus.state"
  [ -f "$candidate" ] && state_file="$candidate"
fi

if [ -z "$state_file" ]; then
  _err "no consensus.state file found for $plan_path"
  _err "  looked next to plan file and under DOEY_RUNTIME_DIR"
  exit 3
fi

state_value="$(grep -E '^CONSENSUS_STATE=' "$state_file" 2>/dev/null | tail -1 || true)"
state_value="${state_value#CONSENSUS_STATE=}"

if [ "$state_value" != "CONSENSUS" ]; then
  _err "plan is not ready for execution (CONSENSUS_STATE=${state_value:-<unset>}) in $state_file"
  _err "  refusing to create tasks"
  exit 3
fi

# Parse phases and steps. Shell-only.
# Phase: ^### Phase N: Title   (tolerant of emoji prefix and trailing status)
# Step inside a phase:
#   1. text           (numbered list)
#   - [ ] text        (checkbox)
#   - [x] text        (done checkbox)

_strip_inline() {
  # remove surrounding **bold**, trailing spaces, trailing colons.
  v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

tmp_phases="$(mktemp -t plan2tasks.phases.XXXXXX)"
tmp_steps="$(mktemp -t plan2tasks.steps.XXXXXX)"
trap 'rm -f "$tmp_phases" "$tmp_steps"' EXIT

current_phase_idx=0
in_phase=0
phase_title=""

# Write phases file as TAB-separated: idx<TAB>title
# Write steps file as TAB-separated: phase_idx<TAB>step_text
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '## '*)
      in_phase=0
      ;;
    '### '*)
      rest="${line#'### '}"
      # Match "Phase N: ..." (case-insensitive via tr)
      lcase="$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')"
      case "$lcase" in
        phase\ [0-9]*|phase\ [0-9]*:*|*phase\ [0-9]*)
          current_phase_idx=$((current_phase_idx + 1))
          phase_title="$(_strip_inline "$rest")"
          printf '%s\t%s\n' "$current_phase_idx" "$phase_title" >> "$tmp_phases"
          in_phase=1
          ;;
        *)
          in_phase=0
          ;;
      esac
      ;;
    *)
      if [ "$in_phase" = "1" ]; then
        # Checkbox step
        cb="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*[-*][[:space:]]*\[[[:space:]xX]\][[:space:]]*\(.*\)$/\1/p')"
        if [ -n "$cb" ]; then
          cb="$(_strip_inline "$cb")"
          printf '%s\t%s\n' "$current_phase_idx" "$cb" >> "$tmp_steps"
          continue
        fi
        # Numbered step
        num="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*[0-9][0-9]*\.[[:space:]]\{1,\}\(.*\)$/\1/p')"
        if [ -n "$num" ]; then
          num="$(_strip_inline "$num")"
          printf '%s\t%s\n' "$current_phase_idx" "$num" >> "$tmp_steps"
        fi
      fi
      ;;
  esac
done < "$plan_path"

phase_count=0
if [ -s "$tmp_phases" ]; then
  phase_count=$(wc -l < "$tmp_phases" | tr -d ' ')
fi

if [ "$phase_count" = "0" ]; then
  _err "no phases (### Phase N: ...) found in $plan_path"
  exit 1
fi

printf 'plan: %s\n' "$plan_path"
printf 'state: CONSENSUS (%s)\n' "$state_file"
[ -n "$parent_id" ] && printf 'parent: %s\n' "$parent_id"
printf 'phases: %s\n' "$phase_count"
printf '\n'

_origin_of_parent=""
if [ -n "$parent_id" ]; then
  _origin_of_parent="Parent task: ${parent_id}. "
fi

rc=0
while IFS="$(printf '\t')" read -r pidx ptitle; do
  [ -z "$pidx" ] && continue
  nsteps=0
  if [ -s "$tmp_steps" ]; then
    nsteps=$(awk -F'\t' -v p="$pidx" '$1==p{c++} END{print c+0}' "$tmp_steps")
  fi

  if [ "$dry_run" = "1" ]; then
    printf '[DRY-RUN] task create --title "%s" --type feature  (%s steps)\n' "$ptitle" "$nsteps"
    awk -F'\t' -v p="$pidx" '$1==p{print "            subtask: " $2}' "$tmp_steps"
    printf '\n'
    continue
  fi

  # Create the phase task
  desc="${_origin_of_parent}From plan: $(basename "$plan_path") phase ${pidx}"
  task_id=""
  if ! task_id=$(doey task create \
        --title "$ptitle" \
        --type feature \
        --description "$desc" 2>/dev/null); then
    _err "failed to create task for phase ${pidx}: ${ptitle}"
    rc=1
    continue
  fi
  task_id="$(printf '%s' "$task_id" | tr -d '[:space:]')"
  printf 'phase %s → task %s: %s\n' "$pidx" "$task_id" "$ptitle"

  # Append subtasks
  while IFS="$(printf '\t')" read -r spidx stext; do
    [ "$spidx" = "$pidx" ] || continue
    [ -z "$stext" ] && continue
    if ! doey task subtask add --task-id "$task_id" --description "$stext" >/dev/null 2>&1; then
      _err "  failed to add subtask: $stext"
      rc=1
    else
      printf '  + subtask: %s\n' "$stext"
    fi
  done < "$tmp_steps"

  # Append a marker line back to the plan file
  marker="<!-- plan-to-tasks: phase ${pidx} → task ${task_id} ($(date -u +%Y-%m-%dT%H:%M:%SZ)) -->"
  tmp_plan="${plan_path}.tmp.$$"
  cp "$plan_path" "$tmp_plan"
  printf '\n%s\n' "$marker" >> "$tmp_plan"
  mv "$tmp_plan" "$plan_path"
done < "$tmp_phases"

exit "$rc"
