#!/usr/bin/env bash
# masterplan-consensus.sh — Planner/Architect/Critic consensus state machine
#
# Sourceable bash 3.2 compatible helper library. Manages a simple key=value
# state file (${plan_dir}/consensus.state) that tracks the review loop for a
# masterplan: DRAFT → UNDER_REVIEW → (REVISIONS_NEEDED → UNDER_REVIEW)* → CONSENSUS.
# Any state can transition to ESCALATED if the review loop gives up.
#
# File format (one key=value per line, empty values allowed):
#   CONSENSUS_STATE=DRAFT
#   ROUND=0
#   PLAN_ID=masterplan-20260411-120000
#   UPDATED=1712837400
#   ARCHITECT_VERDICT=
#   CRITIC_VERDICT=
#
# All writes go through an atomic tmp+mv. No declare -A, no bash 4+ features.

set -euo pipefail

_consensus_state_file() {
  printf '%s/consensus.state' "$1"
}

_consensus_now() {
  date +%s
}

# consensus_init <plan_dir> [plan_id]
consensus_init() {
  local plan_dir="$1"
  local plan_id="${2:-}"
  local state_file
  state_file="$(_consensus_state_file "$plan_dir")"

  if [ -z "$plan_dir" ]; then
    printf 'consensus_init: plan_dir required\n' >&2
    return 1
  fi
  mkdir -p "$plan_dir"

  if [ -z "$plan_id" ]; then
    plan_id="$(basename "$plan_dir")"
  fi

  local tmp="${state_file}.tmp.$$"
  {
    printf 'CONSENSUS_STATE=DRAFT\n'
    printf 'ROUND=0\n'
    printf 'PLAN_ID=%s\n' "$plan_id"
    printf 'UPDATED=%s\n' "$(_consensus_now)"
    printf 'ARCHITECT_VERDICT=\n'
    printf 'CRITIC_VERDICT=\n'
  } > "$tmp"
  mv "$tmp" "$state_file"
}

# consensus_get <plan_dir> <key>
consensus_get() {
  local plan_dir="$1" key="$2"
  local state_file
  state_file="$(_consensus_state_file "$plan_dir")"
  [ -f "$state_file" ] || return 0
  local line
  line="$(grep -E "^${key}=" "$state_file" 2>/dev/null | tail -1 || true)"
  printf '%s' "${line#*=}"
}

# consensus_set <plan_dir> <key> <value>
# Atomic update: rewrites the whole file via tmp+mv, preserving other keys,
# replacing the target key if present, appending if not.
consensus_set() {
  local plan_dir="$1" key="$2" value="$3"
  local state_file
  state_file="$(_consensus_state_file "$plan_dir")"
  if [ ! -f "$state_file" ]; then
    printf 'consensus_set: no state file at %s\n' "$state_file" >&2
    return 1
  fi

  local tmp="${state_file}.tmp.$$"
  local wrote_key=0
  local line lhs
  while IFS= read -r line || [ -n "$line" ]; do
    lhs="${line%%=*}"
    if [ "$lhs" = "$key" ]; then
      printf '%s=%s\n' "$key" "$value" >> "$tmp"
      wrote_key=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$state_file"

  if [ "$wrote_key" = "0" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi

  mv "$tmp" "$state_file"

  if [ "$key" != "UPDATED" ]; then
    _consensus_set_raw "$plan_dir" "UPDATED" "$(_consensus_now)"
  fi
}

# Internal: single-key update without recursing on UPDATED.
_consensus_set_raw() {
  local plan_dir="$1" key="$2" value="$3"
  local state_file
  state_file="$(_consensus_state_file "$plan_dir")"
  [ -f "$state_file" ] || return 0

  local tmp="${state_file}.tmp.$$"
  local wrote_key=0
  local line lhs
  while IFS= read -r line || [ -n "$line" ]; do
    lhs="${line%%=*}"
    if [ "$lhs" = "$key" ]; then
      printf '%s=%s\n' "$key" "$value" >> "$tmp"
      wrote_key=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$state_file"

  if [ "$wrote_key" = "0" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  mv "$tmp" "$state_file"
}

# consensus_state <plan_dir>
consensus_state() {
  consensus_get "$1" "CONSENSUS_STATE"
}

# consensus_require <plan_dir> <expected_state>
consensus_require() {
  local plan_dir="$1" expected="$2"
  local actual
  actual="$(consensus_state "$plan_dir")"
  if [ "$actual" != "$expected" ]; then
    printf 'consensus_require: expected %s but state is %s (plan_dir=%s)\n' \
      "$expected" "${actual:-<unset>}" "$plan_dir" >&2
    return 1
  fi
}

# consensus_valid_transitions — print allowed edges, one per line "FROM->TO"
consensus_valid_transitions() {
  cat <<'EDGES'
DRAFT->UNDER_REVIEW
UNDER_REVIEW->REVISIONS_NEEDED
UNDER_REVIEW->CONSENSUS
REVISIONS_NEEDED->UNDER_REVIEW
DRAFT->ESCALATED
UNDER_REVIEW->ESCALATED
REVISIONS_NEEDED->ESCALATED
CONSENSUS->ESCALATED
ESCALATED->REVISIONS_NEEDED
EDGES
}

# _consensus_transition_allowed <from> <to> → 0 if allowed, 1 otherwise
_consensus_transition_allowed() {
  local from="$1" to="$2"
  local edge
  while IFS= read -r edge; do
    if [ "$edge" = "${from}->${to}" ]; then
      return 0
    fi
  done <<EOF
$(consensus_valid_transitions)
EOF
  return 1
}

# consensus_advance <plan_dir> <new_state>
consensus_advance() {
  local plan_dir="$1" new_state="$2"
  local current
  current="$(consensus_state "$plan_dir")"
  if [ -z "$current" ]; then
    printf 'consensus_advance: no state file in %s (call consensus_init first)\n' "$plan_dir" >&2
    return 1
  fi
  if ! _consensus_transition_allowed "$current" "$new_state"; then
    printf 'consensus_advance: invalid transition %s -> %s\n' "$current" "$new_state" >&2
    return 1
  fi
  consensus_set "$plan_dir" "CONSENSUS_STATE" "$new_state"
}
