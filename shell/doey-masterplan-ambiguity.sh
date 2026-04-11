#!/usr/bin/env bash
# doey-masterplan-ambiguity.sh — Goal ambiguity heuristic for masterplan skill.
# Sourceable helper. Also runnable directly: doey-masterplan-ambiguity.sh "<goal>"
set -euo pipefail

[ "${__doey_masterplan_ambiguity_sourced:-}" = "1" ] && return 0 2>/dev/null || true
__doey_masterplan_ambiguity_sourced=1

# masterplan_ambiguity_score <goal_text>
#
# Classifies a masterplan goal as CLEAR or AMBIGUOUS.
# A goal is CLEAR only when it is both:
#   - ≥ 30 words (detailed enough to skip the interview)
#   - contains at least one file-path-like token (/, .sh, .go, .tmpl, .md, .ts, .tsx, .py)
# Any other input (including empty / whitespace-only / single word) is AMBIGUOUS.
#
# Prints "CLEAR" or "AMBIGUOUS" on stdout. Exit code 0 on success.
masterplan_ambiguity_score() {
  local goal="${1:-}"

  # Trim leading/trailing whitespace (bash 3.2 compatible).
  goal="${goal#"${goal%%[![:space:]]*}"}"
  goal="${goal%"${goal##*[![:space:]]}"}"

  if [ -z "$goal" ]; then
    printf '%s\n' "AMBIGUOUS"
    return 0
  fi

  local word_count has_path=0
  word_count=$(printf '%s' "$goal" | wc -w | tr -d ' ')

  case "$goal" in
    *'/'*|*.sh*|*.go*|*.tmpl*|*.md*|*.ts*|*.tsx*|*.py*) has_path=1 ;;
  esac

  if [ "${word_count:-0}" -ge 30 ] && [ "$has_path" = "1" ]; then
    printf '%s\n' "CLEAR"
  else
    printf '%s\n' "AMBIGUOUS"
  fi
}

# masterplan_ambiguity_debug <goal_text>
# Prints: "<classification> words=<N> has_path=<0|1>"
masterplan_ambiguity_debug() {
  local goal="${1:-}"
  goal="${goal#"${goal%%[![:space:]]*}"}"
  goal="${goal%"${goal##*[![:space:]]}"}"
  local wc_val=0 hp=0 classification
  if [ -n "$goal" ]; then
    wc_val=$(printf '%s' "$goal" | wc -w | tr -d ' ')
    case "$goal" in
      *'/'*|*.sh*|*.go*|*.tmpl*|*.md*|*.ts*|*.tsx*|*.py*) hp=1 ;;
    esac
  fi
  classification=$(masterplan_ambiguity_score "$goal")
  printf '%s words=%s has_path=%s\n' "$classification" "$wc_val" "$hp"
}

# Direct invocation
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  masterplan_ambiguity_score "${1:-}"
fi
