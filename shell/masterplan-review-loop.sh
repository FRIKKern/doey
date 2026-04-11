#!/usr/bin/env bash
# masterplan-review-loop.sh — orchestrate the Planner/Architect/Critic round
#
# Sourced (or executed) by the Planner. Required env vars:
#   PLAN_DIR  — masterplan working dir (holds consensus.state + review files)
#   PLAN_FILE — path to the plan markdown the reviewers will read
#
# Optional env:
#   PLAN_ID              — defaults to $(basename "$PLAN_DIR")
#   DOEY_TEAM_WINDOW     — tmux window index for this masterplan team
#   DOEY_SESSION         — tmux session (defaults to current)
#   MASTERPLAN_REVIEW_TIMEOUT — per-round wait timeout seconds (default 900)
#   MASTERPLAN_MAX_ROUNDS     — max review rounds before ESCALATED (default 3)
#
# Exit codes:
#   0 — CONSENSUS reached
#   2 — REVISIONS_NEEDED (Planner must revise and re-run the loop)
#   3 — ESCALATED (round cap exceeded, human required)
#   1 — hard error (bad state, missing files, etc.)

set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "${_SELF_DIR}/masterplan-consensus.sh"

: "${PLAN_DIR:?PLAN_DIR required}"
: "${PLAN_FILE:?PLAN_FILE required}"
PLAN_ID="${PLAN_ID:-$(basename "$PLAN_DIR")}"
MASTERPLAN_REVIEW_TIMEOUT="${MASTERPLAN_REVIEW_TIMEOUT:-900}"
MASTERPLAN_MAX_ROUNDS="${MASTERPLAN_MAX_ROUNDS:-3}"

ARCH_FILE="${PLAN_DIR}/${PLAN_ID}.architect.md"
CRIT_FILE="${PLAN_DIR}/${PLAN_ID}.critic.md"

SESSION_NAME="${DOEY_SESSION:-$(tmux display-message -p '#S' 2>/dev/null || true)}"
TEAM_WIN="${DOEY_TEAM_WINDOW:-}"
if [ -z "$TEAM_WIN" ]; then
  TEAM_WIN="$(tmux display-message -p '#I' 2>/dev/null || true)"
fi

ARCH_PANE="${SESSION_NAME}:${TEAM_WIN}.2"
CRIT_PANE="${SESSION_NAME}:${TEAM_WIN}.3"

# shellcheck disable=SC1091
. "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true

_parse_verdict() {
  local file="$1"
  [ -f "$file" ] || { printf ''; return 0; }
  local line
  line="$(grep -m1 -E '^\*\*Verdict:\*\*' "$file" 2>/dev/null || true)"
  printf '%s' "${line#*Verdict:**}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

_dispatch_reviewer() {
  local pane="$1" role="$2"
  local msg
  msg="You are the ${role} reviewer for masterplan ${PLAN_ID}.

PLAN_FILE: ${PLAN_FILE}
PLAN_DIR: ${PLAN_DIR}
STATE_FILE: ${PLAN_DIR}/consensus.state

Read the plan file and write your review to:
  ${PLAN_DIR}/${PLAN_ID}.$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]').md

The review MUST contain a line of the form:
  **Verdict:** APPROVE
or
  **Verdict:** REVISE

Include specific, actionable feedback. The Planner will read your review and
either finalize (if both reviewers APPROVE) or revise and request another round."

  if command -v doey_send_verified >/dev/null 2>&1; then
    doey_send_verified "$pane" "$msg" 2>/dev/null || return 1
  else
    tmux send-keys -t "$pane" "$msg" Enter 2>/dev/null || return 1
  fi
}

masterplan_review_round() {
  local current round
  current="$(consensus_state "$PLAN_DIR")"

  case "$current" in
    DRAFT)
      consensus_advance "$PLAN_DIR" UNDER_REVIEW
      ;;
    REVISIONS_NEEDED)
      consensus_advance "$PLAN_DIR" UNDER_REVIEW
      ;;
    UNDER_REVIEW)
      : # already under review, continue
      ;;
    *)
      printf 'masterplan_review_round: cannot start review from state %s\n' "$current" >&2
      return 1
      ;;
  esac

  round="$(consensus_get "$PLAN_DIR" ROUND)"
  round=$((round + 1))
  consensus_set "$PLAN_DIR" ROUND "$round"
  consensus_set "$PLAN_DIR" ARCHITECT_VERDICT ""
  consensus_set "$PLAN_DIR" CRITIC_VERDICT ""

  if [ "$round" -gt "$MASTERPLAN_MAX_ROUNDS" ]; then
    consensus_advance "$PLAN_DIR" ESCALATED
    printf 'masterplan_review_round: round cap (%s) exceeded — ESCALATED\n' \
      "$MASTERPLAN_MAX_ROUNDS" >&2
    return 3
  fi

  rm -f "$ARCH_FILE" "$CRIT_FILE" 2>/dev/null || true

  printf 'masterplan_review_round: round %s — dispatching Architect (%s) and Critic (%s)\n' \
    "$round" "$ARCH_PANE" "$CRIT_PANE"

  _dispatch_reviewer "$ARCH_PANE" "Architect" || \
    printf 'WARN: Architect dispatch failed\n' >&2
  _dispatch_reviewer "$CRIT_PANE" "Critic" || \
    printf 'WARN: Critic dispatch failed\n' >&2

  local waited=0
  local interval=10
  local arch_verdict="" crit_verdict=""
  while [ "$waited" -lt "$MASTERPLAN_REVIEW_TIMEOUT" ]; do
    if [ -f "$ARCH_FILE" ] && [ -f "$CRIT_FILE" ]; then
      arch_verdict="$(_parse_verdict "$ARCH_FILE")"
      crit_verdict="$(_parse_verdict "$CRIT_FILE")"
      if [ -n "$arch_verdict" ] && [ -n "$crit_verdict" ]; then
        break
      fi
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done

  if [ -z "$arch_verdict" ] || [ -z "$crit_verdict" ]; then
    printf 'masterplan_review_round: timeout waiting for reviews (arch=%s crit=%s)\n' \
      "${arch_verdict:-<missing>}" "${crit_verdict:-<missing>}" >&2
    consensus_advance "$PLAN_DIR" ESCALATED
    return 3
  fi

  consensus_set "$PLAN_DIR" ARCHITECT_VERDICT "$arch_verdict"
  consensus_set "$PLAN_DIR" CRITIC_VERDICT "$crit_verdict"

  if [ "$arch_verdict" = "APPROVE" ] && [ "$crit_verdict" = "APPROVE" ]; then
    consensus_advance "$PLAN_DIR" CONSENSUS
    printf 'masterplan_review_round: CONSENSUS reached in round %s\n' "$round"
    return 0
  fi

  consensus_advance "$PLAN_DIR" REVISIONS_NEEDED
  printf 'masterplan_review_round: revisions needed (arch=%s crit=%s)\n' \
    "$arch_verdict" "$crit_verdict"
  return 2
}

# Allow direct execution for debugging/manual use
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  masterplan_review_round
fi
