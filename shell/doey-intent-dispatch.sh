#!/usr/bin/env bash
# shell/doey-intent-dispatch.sh — Intent Fallback dispatcher (Phase 2)
#
# Provides one entry point:
#   doey_intent_dispatch "<full_typed_cmd>" "<error_msg>"
#
# Glue between doey.sh's unknown-command case and the standalone
# `intent_fallback` helper shipped in shell/intent-fallback.sh.
#
# Phase 2 safety model — ALWAYS CONFIRM BEFORE EXECUTING.
# There is no silent auto-execute path regardless of role, tty, or action.
#
#   Situation                              | Action
#   ---------------------------------------|----------------------------------
#   DOEY_NO_INTENT_FALLBACK=1              | Skip — caller prints error and exits
#   DOEY_INTENT_FALLBACK=0                 | Skip — caller prints error and exits
#   No tty on stdout                       | Skip — we cannot prompt, caller errors
#   auto_correct, non-destructive cmd      | Print "↳ did you mean: …? [y/N]" and exec on y
#   auto_correct, destructive cmd          | Refuse entirely; print refusal, return 1
#   suggest, tty                           | Numbered menu, read -t 15, exec chosen (non-destructive)
#   clarify                                | Print "? <question>" and return 1 (NOT exit)
#   unknown / unhandled                    | return 1
#
# On confirmed execution the function `exec`s the corrected command,
# replacing this process. On any other path it returns non-zero so doey.sh
# can fall through to its existing error+help message.
#
# Bash 3.2 compatible. Sourceable, not standalone.

# Source guard
[ "${__doey_intent_dispatch_sourced:-}" = "1" ] && return 0
__doey_intent_dispatch_sourced=1

# Destructive verb regex. Stored in a variable so [[ =~ ]] treats it as
# an extended regex (bash quirk: quoting on the RHS turns it literal).
# Matches "doey <verb>" stop-words and a few raw shell footguns.
_doey_intent_destructive_re='(^| )doey +(uninstall|kill-window|kill-team|kill-session|purge|remote-destroy|stop( |$))|(^| )(rm +-rf|git +push +--force|git +reset +--hard|tmux +kill-server|tmux +kill-session)'

# Returns 0 if $1 matches the destructive blocklist, else 1.
_doey_intent_is_destructive() {
  local cmd="$1"
  if [[ "$cmd" =~ $_doey_intent_destructive_re ]]; then
    return 0
  fi
  return 1
}

# Ask "did you mean: <cmd>? [y/N]" on stderr. Returns 0 on y/Y/yes, 1 otherwise.
# Supports an optional timeout (seconds) as $2 — defaults to no timeout.
_doey_intent_ask() {
  local cmd="$1"
  local timeout="${2:-0}"
  printf '↳ did you mean: %s? [y/N] ' "$cmd" >&2
  local reply=""
  if [ "$timeout" -gt 0 ] 2>/dev/null; then
    read -r -t "$timeout" reply || return 1
  else
    read -r reply || return 1
  fi
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Exec helper. Word-splits $cmd into argv (intentional — the model returns
# a plain command line, and the destructive check has already filtered the
# obvious footguns). Prints the corrected line to stderr first.
_doey_intent_exec() {
  local cmd="$1"
  printf '↳ running: %s\n' "$cmd" >&2
  # shellcheck disable=SC2086
  exec $cmd
}

# Main entry point. See header for the behaviour matrix.
doey_intent_dispatch() {
  local typed="${1:-}"
  local err="${2:-Unknown command}"

  # Opt-out short-circuits. Honour both the positive-logic off switch and
  # the legacy negative-logic kill switch.
  if [ "${DOEY_INTENT_FALLBACK:-1}" = "0" ]; then
    return 1
  fi
  if [ "${DOEY_NO_INTENT_FALLBACK:-0}" = "1" ]; then
    return 1
  fi

  # We always confirm before executing, so a tty on stdin+stdout is
  # required. No tty → no prompt → no help. Caller falls through to the
  # plain error message.
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    return 1
  fi

  # Dependencies. If the helper isn't loaded, give up cleanly.
  if ! command -v intent_fallback >/dev/null 2>&1; then
    return 1
  fi

  # Load CLI schema. Try cached file first, then live dump, then empty.
  # All three are best-effort — set -e is intentionally bypassed via ||.
  local schema=""
  schema=$(cat "$HOME/.config/doey/cli-schema.json" 2>/dev/null \
            || doey-ctl schema dump 2>/dev/null \
            || echo "{}")
  [ -z "$schema" ] && schema="{}"

  # Recent context: env identifiers + last 5 shell history lines.
  local recent=""
  local hist=""
  hist=$(tail -5 "$HOME/.bash_history" 2>/dev/null || true)
  recent="role=${DOEY_ROLE:-}
project=${PROJECT_NAME:-}
history:
$hist"

  # Call the fallback helper. Always returns 0; an empty stdout means
  # "no help available" and we fall through.
  local result=""
  result=$(intent_fallback "$typed" "$err" "$schema" "$recent" 2>/dev/null || true)

  if [ -z "$result" ]; then
    return 1
  fi

  local action=""
  action=$(printf '%s' "$result" | jq -r '.action // "unknown"' 2>/dev/null || echo "unknown")

  case "$action" in
    auto_correct)
      local cmd=""
      cmd=$(printf '%s' "$result" | jq -r '.command // ""' 2>/dev/null || echo "")
      if [ -z "$cmd" ]; then
        return 1
      fi
      if _doey_intent_is_destructive "$cmd"; then
        # Phase 2: destructive commands are refused outright. No confirmation,
        # no prompt — the risk/benefit of auto-running shell footguns based on
        # a model guess is never worth it.
        printf '↳ refused destructive suggestion: %s\n' "$cmd" >&2
        return 1
      fi
      # Non-destructive: ask before running. No timeout — user may be reading.
      if _doey_intent_ask "$cmd"; then
        _doey_intent_exec "$cmd"
      fi
      return 1
      ;;

    suggest)
      local options=""
      options=$(printf '%s' "$result" | jq -r '.options[]?' 2>/dev/null || echo "")
      if [ -z "$options" ]; then
        return 1
      fi

      # Build a positional list of up to 3 options and print the menu.
      local opts_array=()
      local opt
      local i=1
      while IFS= read -r opt; do
        [ -z "$opt" ] && continue
        opts_array+=("$opt")
        printf '  %d) %s\n' "$i" "$opt" >&2
        i=$((i + 1))
        [ "$i" -gt 3 ] && break
      done <<EOF
$options
EOF

      if [ "${#opts_array[@]}" -eq 0 ]; then
        return 1
      fi

      printf 'Choose [1-%d] or anything else to skip (15s): ' "${#opts_array[@]}" >&2
      local choice=""
      # 15-second timeout so a suggestion menu never hangs the shell.
      read -r -t 15 choice || { printf '\n' >&2; return 1; }
      case "$choice" in
        [1-9])
          local idx=$((choice - 1))
          if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#opts_array[@]}" ]; then
            local chosen="${opts_array[$idx]}"
            if _doey_intent_is_destructive "$chosen"; then
              printf '↳ refused destructive suggestion: %s\n' "$chosen" >&2
              return 1
            fi
            _doey_intent_exec "$chosen"
          fi
          return 1
          ;;
        *)
          return 1
          ;;
      esac
      ;;

    clarify)
      local question=""
      question=$(printf '%s' "$result" | jq -r '.question // ""' 2>/dev/null || echo "")
      if [ -n "$question" ]; then
        printf '? %s\n' "$question" >&2
      fi
      # IMPORTANT: return 1, NOT exit 1. This file is sourced into the
      # parent shell; `exit 1` would kill the user's interactive session.
      return 1
      ;;

    unknown|*)
      # Fall through to original error.
      return 1
      ;;
  esac
}
