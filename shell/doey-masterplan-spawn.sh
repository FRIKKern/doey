#!/usr/bin/env bash
# doey-masterplan-spawn.sh — spawn the masterplan team window for a prepared plan
#
# Usage: doey-masterplan-spawn.sh <plan-id>
#
# Preconditions:
#   /tmp/doey/<project>/<plan-id>/masterplan.env exists (written by /doey-masterplan)
#   If an interview brief was produced, it lives at ${PLANS_DIR}/${plan-id}.brief.md
#
# This helper is called from two places:
#   1. The /doey-masterplan skill in --quick mode (no interview)
#   2. The doey-interviewer agent after Phase 5 brief approval, when the
#      interview was launched as a masterplan pre-phase
#
# Both callers converge here so the team-spawn + Planner-brief logic lives once.

set -euo pipefail

# shellcheck disable=SC1091
_SPAWN_SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${_SPAWN_SELF_DIR}/masterplan-consensus.sh" ]; then
  . "${_SPAWN_SELF_DIR}/masterplan-consensus.sh"
elif [ -f "/home/doey/doey/shell/masterplan-consensus.sh" ]; then
  . "/home/doey/doey/shell/masterplan-consensus.sh"
fi

PLAN_ID="${1:-}"
if [ -z "$PLAN_ID" ]; then
  printf 'Usage: %s <plan-id>\n' "$(basename "$0")" >&2
  exit 1
fi

# Stats: record skill entry (category=skill, cmd=masterplan)
(command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill skill_invoked cmd=masterplan &) 2>/dev/null || true

SESSION_NAME="$(tmux display-message -p '#S' 2>/dev/null || true)"
if [ -z "$SESSION_NAME" ]; then
  printf 'ERROR: no tmux session (run inside a doey session)\n' >&2
  exit 1
fi

RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2- || true)"
if [ -z "$RD" ]; then
  printf 'ERROR: DOEY_RUNTIME not set in tmux session environment\n' >&2
  exit 1
fi

MP_DIR="${RD}/${PLAN_ID}"
ENV_FILE="${MP_DIR}/masterplan.env"
if [ ! -f "$ENV_FILE" ]; then
  printf 'ERROR: masterplan env not found: %s\n' "$ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$ENV_FILE"

: "${PLAN_ID:?PLAN_ID missing from env}"
: "${PLAN_FILE:?PLAN_FILE missing from env}"
: "${GOAL_FILE:?GOAL_FILE missing from env}"
: "${MP_DIR:?MP_DIR missing from env}"
: "${PLANS_DIR:?PLANS_DIR missing from env}"

BRIEF_FILE="${BRIEF_FILE:-${PLANS_DIR}/${PLAN_ID}.brief.md}"
DOEY_TASK_ID="${DOEY_TASK_ID:-}"
PLAN_DB_ID="${PLAN_DB_ID:-}"

if [ ! -f "$GOAL_FILE" ]; then
  printf 'ERROR: goal file missing: %s\n' "$GOAL_FILE" >&2
  exit 1
fi

# Initialize consensus state machine if the helper is available and state
# doesn't already exist. Idempotent re-runs leave existing state intact.
if command -v consensus_init >/dev/null 2>&1; then
  if [ ! -f "${MP_DIR}/consensus.state" ]; then
    consensus_init "$MP_DIR" "$PLAN_ID"
    printf 'Consensus state initialized at %s/consensus.state\n' "$MP_DIR"
  else
    printf 'Consensus state already exists at %s/consensus.state\n' "$MP_DIR"
  fi
fi

# Propagate env to session so panes inherit
tmux set-environment -t "$SESSION_NAME" PLAN_FILE   "$PLAN_FILE"   2>/dev/null || true
tmux set-environment -t "$SESSION_NAME" GOAL_FILE   "$GOAL_FILE"   2>/dev/null || true
tmux set-environment -t "$SESSION_NAME" MASTERPLAN_ID "$PLAN_ID"   2>/dev/null || true
[ -n "$DOEY_TASK_ID" ] && tmux set-environment -t "$SESSION_NAME" DOEY_TASK_ID "$DOEY_TASK_ID" 2>/dev/null || true
[ -n "$PLAN_DB_ID"   ] && tmux set-environment -t "$SESSION_NAME" PLAN_DB_ID   "$PLAN_DB_ID"   2>/dev/null || true
if [ -f "$BRIEF_FILE" ]; then
  tmux set-environment -t "$SESSION_NAME" BRIEF_FILE "$BRIEF_FILE" 2>/dev/null || true
fi

# Idempotency: if a masterplan team window already exists for this PLAN_ID
# (recorded via MASTERPLAN_ID in the team env), reuse it instead of spawning.
MP_WIN=""
MP_REUSED=0
for _mp_env in "${RD}"/team_*.env; do
  [ -f "$_mp_env" ] || continue
  _mp_id="$(grep '^MASTERPLAN_ID=' "$_mp_env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
  [ -z "$_mp_id" ] && continue
  if [ "$_mp_id" = "$PLAN_ID" ]; then
    MP_WIN="$(grep '^WINDOW_INDEX=' "$_mp_env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
    if [ -n "$MP_WIN" ] && tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null | grep -qx "$MP_WIN"; then
      MP_REUSED=1
      break
    fi
    MP_WIN=""
  fi
done

if [ "$MP_REUSED" = "1" ]; then
  printf 'Masterplan window already live for plan %s — reusing window %s\n' "$PLAN_ID" "$MP_WIN"
else
  printf 'Spawning masterplan team window for plan %s...\n' "$PLAN_ID"
  if ! doey add-team masterplan; then
    printf 'ERROR: doey add-team masterplan failed\n' >&2
    exit 1
  fi

  # Find the masterplan window (exact name match — "masterplan", not "masterplan-*")
  MP_WIN="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index} #{window_name}' 2>/dev/null \
    | awk '$2=="masterplan"{w=$1} END{print w}')"
  if [ -z "$MP_WIN" ]; then
    printf 'ERROR: masterplan window not found after add-team\n' >&2
    exit 1
  fi
  printf 'Masterplan window: %s (newly created)\n' "$MP_WIN"

  # Tag the team env with MASTERPLAN_ID so future calls can detect and reuse.
  _mp_new_env="${RD}/team_${MP_WIN}.env"
  if [ -f "$_mp_new_env" ] && ! grep -q '^MASTERPLAN_ID=' "$_mp_new_env" 2>/dev/null; then
    printf 'MASTERPLAN_ID="%s"\n' "$PLAN_ID" >> "$_mp_new_env"
  fi
fi

if [ "$MP_REUSED" = "1" ]; then
  printf 'Masterplan spawn: reused existing window=%s plan=%s (Planner already briefed, skipping re-briefing)\n' "$MP_WIN" "$PLAN_ID"
  exit 0
fi

# Wait for Planner to boot
sleep "${DOEY_MANAGER_BRIEF_DELAY:-10}"

PLANNER_PANE="${SESSION_NAME}:${MP_WIN}.0"
# shellcheck disable=SC1090
. "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true

# Build briefing — inject brief path and excerpt if interview produced one
BRIEF_SECTION=""
if [ -f "$BRIEF_FILE" ]; then
  BRIEF_SECTION="
## Interview Brief (PRIMARY INPUT — read first)
A structured interview brief has been produced by the Deep Interviewer.
**Brief file:** ${BRIEF_FILE}

This brief contains the extracted intent, scope, non-goals, constraints, and
success criteria for the goal. Read it before dispatching any research — it is
the source of truth for WHAT to plan. Do NOT re-ask the user questions that are
already answered in the brief."
fi

BRIEFING="You are the Masterplanner for plan ${PLAN_ID}.

## Goal
$(cat "$GOAL_FILE")
${BRIEF_SECTION}

## Context
- Plan ID: ${PLAN_ID}
- Goal file: ${GOAL_FILE}
- Brief file: ${BRIEF_FILE}$( [ -f "$BRIEF_FILE" ] || printf ' (not produced — quick mode)')
- Plan file: ${PLAN_FILE}
- Working directory: ${MP_DIR}
- Research directory: ${MP_DIR}/research/
- Plans directory: ${PLANS_DIR}
- Task ID: ${DOEY_TASK_ID:-none}
- Plan DB ID: ${PLAN_DB_ID:-none}

Read the goal file and the brief file (if present), then begin the masterplan
process. Use workers (panes 2-5) for parallel research. Write the plan to the
plan file path above — the TUI (pane 1) will display it.

IMPORTANT: After each major update to the plan file, sync it to the DB so the
TUI Plans tab stays current:
  doey plan update --id ${PLAN_DB_ID:-0} --body \"\$(cat ${PLAN_FILE})\"
Skip this step if Plan DB ID is 'none' or '0'."

if doey_send_verified "$PLANNER_PANE" "$BRIEFING" 2>/dev/null; then
  printf 'Planner briefed successfully\n'
else
  printf 'WARNING: Planner briefing delivery failed — Planner will fall back to %s\n' "$GOAL_FILE" >&2
fi

# Informational notification to Taskmaster
RD="$(tmux show-environment "$SESSION_NAME" DOEY_RUNTIME 2>/dev/null | cut -d= -f2- || true)"
if [ -n "$RD" ] && [ -f "${RD}/session.env" ]; then
  TASKMASTER_PANE="$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)"
  TASKMASTER_PANE="${TASKMASTER_PANE:-1.0}"
  FROM_PANE="${DOEY_PANE_ID:-${SESSION_NAME}:${MP_WIN}.0}"
  doey msg send --to "${SESSION_NAME}:${TASKMASTER_PANE}" --from "$FROM_PANE" \
    --subject "masterplan_spawned" \
    --body "MASTERPLAN_ID: ${PLAN_ID}
PLAN_FILE: ${PLAN_FILE}
GOAL_FILE: ${GOAL_FILE}
BRIEF_FILE: ${BRIEF_FILE}$( [ -f "$BRIEF_FILE" ] || printf ' (none)')
TASK_ID: ${DOEY_TASK_ID:-}
PLAN_DB_ID: ${PLAN_DB_ID:-}
WINDOW: ${MP_WIN}
Masterplan window ${MP_WIN} is live. Planner is briefed." 2>/dev/null || true
  doey msg trigger --pane "${SESSION_NAME}:${TASKMASTER_PANE}" 2>/dev/null || true
fi

printf 'Masterplan spawn complete: window=%s plan=%s\n' "$MP_WIN" "$PLAN_ID"
