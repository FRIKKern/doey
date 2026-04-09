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

# Conversational chat mode — warm, cozy interaction
_doey_chat_mode() {
  local initial_input="$1"
  local first_response="$2"

  # Color setup — respect NO_COLOR
  local _chat_reset="" _chat_accent="" _chat_dim=""
  if [ -z "${NO_COLOR:-}" ] && _intent_fb_is_tty; then
    _chat_reset=$'\033[0m'
    _chat_accent=$'\033[38;5;222m'   # warm gold
    _chat_dim=$'\033[38;5;245m'      # soft gray
  fi

  # Ctrl-C exits cleanly
  trap 'printf "\n" >&2; return 0' INT

  # Print first response (from the classification)
  if [ -n "$first_response" ]; then
    printf '\n  %s%s%s\n' "$_chat_accent" "$first_response" "$_chat_reset" >&2
  fi

  # Non-TTY: single response only, no REPL
  if ! _intent_fb_is_tty; then
    return 0
  fi

  # Interactive REPL loop
  local context="User: ${initial_input}
Assistant: ${first_response}"
  local user_input=""

  while true; do
    printf '\n  %s> %s' "$_chat_dim" "$_chat_reset" >&2
    if ! read -r user_input; then
      # EOF / Ctrl-D
      printf '\n' >&2
      break
    fi

    # Empty input exits
    if [ -z "$user_input" ]; then
      printf '  %s~ see you around! ~%s\n\n' "$_chat_dim" "$_chat_reset" >&2
      break
    fi

    # Get response from Haiku via the chat function in intent-fallback.sh
    local resp
    resp=$(_doey_chat_respond "$user_input" "$context") || true

    if [ -n "$resp" ]; then
      printf '\n  %s%s%s\n' "$_chat_accent" "$resp" "$_chat_reset" >&2
      context="${context}
User: ${user_input}
Assistant: ${resp}"
    else
      printf '\n  %s(doey got tongue-tied — try again?)%s\n' "$_chat_dim" "$_chat_reset" >&2
    fi
  done

  return 0
}

# Main entry point called from doey.sh
_doey_intent_dispatch() {
  local typed="$*"

  _intent_fb_init_color
  trap 'printf "\n" >&2; exit 130' INT

  # Strip politeness prefixes
  typed="$(printf '%s' "$typed" | sed -E 's/^(please|pls|can you|could you|would you|kindly)[[:space:]]+//i')"

  # Opt-out gates
  if [ "${DOEY_NO_INTENT_FALLBACK:-0}" = "1" ] || [ "${DOEY_INTENT_FALLBACK:-1}" = "0" ]; then
    printf "  ${_IFB_RED}✗${_IFB_RST} Unknown command: %s\n" "$typed" >&2
    printf "  Run ${_IFB_BLD}doey --help${_IFB_RST} for usage\n" >&2
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
      printf "  ${_IFB_RED}✗${_IFB_RST} Unknown command: %s\n" "$typed" >&2
      printf "  Run ${_IFB_BLD}doey --help${_IFB_RST} for usage\n" >&2
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
        printf "  Did you mean: ${_IFB_BLD}%s${_IFB_RST}?\n" "$command" >&2
        printf "  ${_IFB_YLW}⚠${_IFB_RST}  This is a destructive command.\n" >&2
        printf '  Run? [y/N] ' >&2
        read -r _confirm < /dev/tty 2>/dev/null || _confirm="n"
        case "$_confirm" in
          [Yy]*) eval "$command" ;;
          *) printf '  Cancelled.\n' >&2 ;;
        esac
      elif _intent_fb_is_tty; then
        # Interactive TTY — auto-execute
        printf "  Running: ${_IFB_BLD}%s${_IFB_RST}\n" "$command" >&2
        printf '  (%s)\n' "$explanation" >&2
        eval "$command"
      else
        # Non-interactive — just suggest
        printf '  → %s\n' "$command" >&2
        printf '  (%s)\n' "$explanation" >&2
      fi
      ;;
    MEDIUM)
      if _intent_fb_is_tty; then
        # Try interactive TUI if available
        if command -v doey-tui >/dev/null 2>&1; then
          local _tui_json _tui_result _selected
          _tui_json=$(printf '{"action":"confirm","command":"%s","explanation":"%s","typed":"doey %s"}' \
            "$(printf '%s' "$command" | sed 's/"/\\"/g')" \
            "$(printf '%s' "$explanation" | sed 's/"/\\"/g')" \
            "$(printf '%s' "$typed" | sed 's/"/\\"/g')")
          _tui_result=$(printf '%s' "$_tui_json" | doey-tui intent-select 2>/dev/tty) || true
          if [ -n "$_tui_result" ]; then
            _selected=$(printf '%s' "$_tui_result" | sed -n 's/.*"selected":"\([^"]*\)".*/\1/p')
            if [ -n "$_selected" ]; then
              eval "$_selected"
            else
              printf '  Cancelled.\n' >&2
            fi
          else
            printf '  Cancelled.\n' >&2
          fi
        else
          # Fallback: simple y/N prompt
          printf "  Did you mean: ${_IFB_BLD}%s${_IFB_RST}? [y/N] " "$command" >&2
          read -r _confirm < /dev/tty 2>/dev/null || _confirm="n"
          case "$_confirm" in
            [Yy]*) eval "$command" ;;
            *) printf '  Cancelled.\n' >&2 ;;
          esac
        fi
      else
        # Non-interactive — just print suggestion
        printf '  Did you mean: %s\n' "$command" >&2
        printf '  (%s)\n' "$explanation" >&2
      fi
      ;;
    CHAT)
      # Conversational mode — doey is a friendly companion
      _doey_chat_mode "$typed" "$explanation"
      ;;
    NONE|*)
      if _intent_fb_is_tty && command -v doey-tui >/dev/null 2>&1; then
        printf '{"action":"info","message":"%s","suggestions":[]}' \
          "$(printf '%s' "$explanation" | sed 's/"/\\"/g')" \
          | doey-tui intent-select 2>/dev/tty || true
      else
        printf '  %s\n' "$explanation" >&2
      fi
      ;;
  esac

  trap - INT
  return 0
}

# When executed directly (not sourced), run the function
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] 2>/dev/null; then
  _doey_intent_dispatch "$@"
fi
