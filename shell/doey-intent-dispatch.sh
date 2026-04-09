#!/usr/bin/env bash
# shell/doey-intent-dispatch.sh — Intent dispatch entry point
#
# Provides: _doey_intent_dispatch "<args...>"
# Called from doey.sh's default (*) case branch when the user types
# an unknown command. Sources intent-fallback.sh for the Claude lookup,
# then acts on the result: auto-execute, confirm, or print explanation.
#
# Bash 3.2 compatible. No jq dependency.

set -uo pipefail

# Source guard
[ "${__doey_intent_dispatch_sourced:-}" = "1" ] && return 0 2>/dev/null || true
__doey_intent_dispatch_sourced=1

# shellcheck source=intent-fallback.sh
source "${BASH_SOURCE[0]%/*}/intent-fallback.sh"

# Main entry point called from doey.sh
_doey_intent_dispatch() {
  local typed="$*"

  # Strip politeness prefixes
  typed="$(printf '%s' "$typed" | sed -E 's/^(please|pls|can you|could you|would you|kindly)[[:space:]]+//i')"

  # Opt-out gates
  if [ "${DOEY_NO_INTENT_FALLBACK:-0}" = "1" ] || [ "${DOEY_INTENT_FALLBACK:-1}" = "0" ]; then
    printf '  \033[31m✗\033[0m Unknown command: %s\n' "$typed" >&2
    printf '  Run \033[1mdoey --help\033[0m for usage\n' >&2
    return 1
  fi

  # Project open fast-path — resolve locally, skip API
  local confidence="" command="" explanation=""
  local _fast_verb="${typed%% *}"
  local _fast_rest="${typed#* }"
  case "$_fast_verb" in
    open|switch|attach)
      local _fast_result=""
      _fast_result="$(find_project_by_name "$_fast_rest" 2>/dev/null)" || _fast_result=""
      if [ -n "$_fast_result" ]; then
        local _fast_name="${_fast_result%%:*}"
        confidence="HIGH"
        command="doey open ${_fast_name}"
        explanation="Opening project '${_fast_name}'"
      fi
      ;;
  esac

  if [ -z "$confidence" ]; then
    # Call the lookup
    local result
    result=$(_doey_intent_lookup "$typed") || true

    if [ -z "$result" ]; then
      # Headless call failed silently — fall back to plain error
      printf '  \033[31m✗\033[0m Unknown command: %s\n' "$typed" >&2
      printf '  Run \033[1mdoey --help\033[0m for usage\n' >&2
      return 1
    fi

    # Parse CONFIDENCE|COMMAND|EXPLANATION
    confidence="${result%%|*}"
    local rest="${result#*|}"
    command="${rest%%|*}"
    explanation="${rest#*|}"
  fi

  case "$confidence" in
    HIGH)
      if _intent_fb_is_destructive "$command"; then
        # Destructive commands always require explicit confirmation
        printf '  Did you mean: \033[1m%s\033[0m?\n' "$command"
        printf '  \033[33m⚠\033[0m  This is a destructive command.\n'
        printf '  Run? [y/N] '
        read -r _confirm < /dev/tty 2>/dev/null || _confirm="n"
        case "$_confirm" in
          [Yy]*) eval "$command" ;;
          *) printf '  Cancelled.\n' ;;
        esac
      elif [ -t 0 ] || [ -t 2 ]; then
        # Interactive TTY — auto-execute
        printf '  Running: \033[1m%s\033[0m\n' "$command"
        eval "$command"
      else
        # Non-interactive — just suggest
        printf '  → %s\n' "$command"
        printf '  (%s)\n' "$explanation"
      fi
      ;;
    MEDIUM)
      if [ -t 0 ] || [ -t 2 ]; then
        # Interactive — suggest and confirm
        printf '  Did you mean: \033[1m%s\033[0m? [y/N] ' "$command"
        read -r _confirm < /dev/tty 2>/dev/null || _confirm="n"
        case "$_confirm" in
          [Yy]*) eval "$command" ;;
          *) printf '  Cancelled.\n' ;;
        esac
      else
        # Non-interactive — just print suggestion
        printf '  Did you mean: %s\n' "$command"
        printf '  (%s)\n' "$explanation"
      fi
      ;;
    NONE|*)
      # No match — print explanation (which should suggest closest commands)
      printf '  %s\n' "$explanation"
      ;;
  esac

  return 0
}

# When executed directly (not sourced), run the function
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] 2>/dev/null; then
  _doey_intent_dispatch "$@"
fi
