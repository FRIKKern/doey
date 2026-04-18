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

# shellcheck source=intent-clarify-state.sh
source "${BASH_SOURCE[0]%/*}/intent-clarify-state.sh"

# Resolve the parent directory where new clones should land.
# Honors DOEY_GITHUB_DIR first, then probes common conventions.
_resolve_github_dir() {
  if [ -n "${DOEY_GITHUB_DIR:-}" ] && [ -d "$DOEY_GITHUB_DIR" ]; then
    printf '%s' "$DOEY_GITHUB_DIR"
    return 0
  fi
  local cand
  for cand in "$HOME/GitHub" "$HOME/Projects" "$HOME/src" "$HOME/projects"; do
    if [ -d "$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  printf '%s' "$HOME/GitHub"
}

# Search the known repo parents for an existing repo matching <name>.
# Prefers exact match; falls back to case-insensitive single-file match.
# Prints absolute path on success and returns 0; returns 1 if not found.
_find_local_repo() {
  local name="$1" parent found
  for parent in "${DOEY_GITHUB_DIR:-}" "$HOME/GitHub" "$HOME/Projects" "$HOME/src" "$HOME/projects"; do
    [ -z "$parent" ] && continue
    [ -d "$parent" ] || continue
    if [ -d "$parent/$name" ]; then
      printf '%s' "$parent/$name"
      return 0
    fi
    found=$(ls -1 "$parent" 2>/dev/null | awk -v n="$name" 'tolower($0)==tolower(n){print; exit}')
    if [ -n "$found" ] && [ -d "$parent/$found" ]; then
      printf '%s' "$parent/$found"
      return 0
    fi
  done
  return 1
}

# Build a short filesystem-evidence block for the escalation agent.
# Lists up to 50 entries from each candidate parent (quietly).
_intent_fb_fs_evidence() {
  local parent entries
  for parent in "${DOEY_GITHUB_DIR:-}" "$HOME/GitHub" "$HOME/Projects" "$HOME/src" "$HOME/projects"; do
    [ -z "$parent" ] && continue
    [ -d "$parent" ] || continue
    entries=$(ls -1 "$parent" 2>/dev/null | head -50)
    if [ -n "$entries" ]; then
      printf '[%s]\n%s\n' "$parent" "$entries"
    fi
  done
}

# Dispatch a single structured action (LOCAL_OPEN | CLONE_OPEN | CLARIFY).
# Used directly for classifier output and indirectly for ESCALATE re-entry.
# Args: $1=action, $2...=fields. Caller must regex-validate before calling.
_dispatch_local_open() {
  local dir="$1" reason="${2:-}"
  case "$dir" in
    /[A-Za-z0-9._/-]*) : ;;
    *) printf '  %s✗%s invalid directory: %s\n' "$_IFB_RED" "$_IFB_RST" "$dir" >&2; return 1 ;;
  esac
  if [ ! -d "$dir" ]; then
    printf '  %s✗%s no such directory: %s\n' "$_IFB_RED" "$_IFB_RST" "$dir" >&2
    return 1
  fi
  if [ ! -d "$dir/.git" ] && ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    printf '  %s⚠%s not a git repo: %s\n' "$_IFB_YLW" "$_IFB_RST" "$dir" >&2
    return 1
  fi
  if _intent_fb_is_tty; then
    printf '  → cd %s && doey' "$dir"
    [ -n "$reason" ] && printf '  (%s)' "$reason"
    printf '\n'
    cd "$dir" && exec doey
  else
    printf '  → cd %s && doey\n' "$dir" >&2
    [ -n "$reason" ] && printf '  (%s)\n' "$reason" >&2
  fi
}

_dispatch_clone_open() {
  local spec="$1" target="$2" reason="${3:-}"
  case "$spec" in
    [A-Za-z0-9._-]*/[A-Za-z0-9._-]*) : ;;
    *) printf '  %s✗%s invalid repo spec: %s\n' "$_IFB_RED" "$_IFB_RST" "$spec" >&2; return 1 ;;
  esac
  case "$target" in
    /[A-Za-z0-9._/-]*) : ;;
    *) printf '  %s✗%s invalid target dir: %s\n' "$_IFB_RED" "$_IFB_RST" "$target" >&2; return 1 ;;
  esac

  # Demote to LOCAL_OPEN if the target already exists and looks like a repo.
  if [ -d "$target" ]; then
    if [ -d "$target/.git" ] || git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
      _dispatch_local_open "$target" "already cloned"
      return $?
    fi
  fi

  if ! _intent_fb_is_tty; then
    printf '  → git clone https://github.com/%s %s\n' "$spec" "$target" >&2
    [ -n "$reason" ] && printf '  (%s)\n' "$reason" >&2
    return 0
  fi

  printf '  Clone %s%s%s to %s%s%s? [y/N] ' \
    "$_IFB_BLD" "$spec" "$_IFB_RST" "$_IFB_BLD" "$target" "$_IFB_RST" >&2
  local _confirm
  read -r _confirm < /dev/tty 2>/dev/null || _confirm="n"
  case "$_confirm" in
    [Yy]*) : ;;
    *) printf '  Cancelled.\n' >&2; return 0 ;;
  esac

  mkdir -p "$(dirname "$target")" 2>/dev/null || true

  local _have_gh=0
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    _have_gh=1
  fi

  if [ "$_have_gh" = "1" ]; then
    printf '  %s→%s gh repo clone %s %s\n' "$_IFB_BLD" "$_IFB_RST" "$spec" "$target" >&2
    if ! gh repo clone "$spec" "$target"; then
      printf '  %s✗%s gh clone failed\n' "$_IFB_RED" "$_IFB_RST" >&2
      return 1
    fi
  else
    printf '  %s→%s git clone https://github.com/%s.git %s\n' "$_IFB_BLD" "$_IFB_RST" "$spec" "$target" >&2
    if ! git clone "https://github.com/${spec}.git" "$target"; then
      printf '  %s✗%s git clone failed\n' "$_IFB_RED" "$_IFB_RST" >&2
      return 1
    fi
  fi

  cd "$target" && exec doey
}

_dispatch_clarify() {
  local q="$1" typed="$2"
  [ -z "$q" ] && return 1
  _clarify_write "$typed" "$q"
  printf '  %s?%s %s\n' "$_IFB_BLD" "$_IFB_RST" "$q" >&2
  printf '  %s(reply with: doey <your answer>)%s\n' "${_IFB_YLW:-}" "${_IFB_RST:-}" >&2
  return 0
}

# ESCALATE: hand off to the doey-fallback agent. Bounded at one hop.
# Input: $1=typed line, $2=reason (optional)
_dispatch_escalate() {
  local typed="$1" reason="${2:-}"
  if [ "${DOEY_INTENT_ESCALATE:-1}" = "0" ]; then
    return 1
  fi
  if [ "${__doey_intent_escalation_depth:-0}" -gt 0 ]; then
    # One-hop cap — never re-escalate.
    printf '  %s✗%s escalation cap reached\n' "$_IFB_RED" "$_IFB_RST" >&2
    return 1
  fi
  if ! command -v claude >/dev/null 2>&1; then
    return 1
  fi

  local agent model evidence payload
  agent="${DOEY_FALLBACK_AGENT:-doey-fallback}"
  model="${DOEY_FALLBACK_MODEL:-sonnet}"
  evidence="$(_intent_fb_fs_evidence 2>/dev/null || true)"

  payload="TYPED: doey ${typed}
REASON_FOR_ESCALATION: ${reason}
GITHUB_DIR_DEFAULT: $(_resolve_github_dir)
GH_AVAILABLE: $(command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && echo yes || echo no)

FILESYSTEM EVIDENCE:
${evidence}

Respond with exactly one line in the agent grammar (RUN|CLARIFY|GIVE_UP)."

  local resp line
  resp=$(printf '%s' "$payload" | (cd /tmp && claude -p --agent "$agent" --model "$model" \
    --no-session-persistence --max-turns 4 --output-format text 2>/dev/null)) || resp=""
  line=$(printf '%s\n' "$resp" | grep -E '^(RUN|CLARIFY|GIVE_UP)\|' | head -1)
  if [ -z "$line" ]; then
    printf '  %s→%s gave up: agent returned no usable response\n' "$_IFB_RED" "$_IFB_RST" >&2
    return 1
  fi

  __doey_intent_escalation_depth=1

  local kind="${line%%|*}"
  local rest="${line#*|}"
  case "$kind" in
    RUN)
      local cmd="${rest%%|*}"
      local why="${rest#*|}"
      # Strict whitelist match against the four allowed shapes.
      case "$cmd" in
        "doey open "[A-Za-z0-9._-]*)
          local name="${cmd#doey open }"
          printf '  %s→%s doey open %s  (%s)\n' "$_IFB_BLD" "$_IFB_RST" "$name" "$why" >&2
          _intent_fb_is_tty && exec doey open "$name"
          return 0
          ;;
        "cd "/[A-Za-z0-9._/-]*" && exec doey")
          local d="${cmd#cd }"; d="${d%% && exec doey}"
          _dispatch_local_open "$d" "$why"
          return 0
          ;;
        "gh repo clone "[A-Za-z0-9._-]*/[A-Za-z0-9._-]*" "/[A-Za-z0-9._/-]*" && cd "/[A-Za-z0-9._/-]*" && exec doey")
          local t="${cmd#gh repo clone }"
          local spec="${t%% *}"
          t="${t#* }"
          local target="${t%% && cd *}"
          _dispatch_clone_open "$spec" "$target" "$why"
          return 0
          ;;
        "git clone https://github.com/"[A-Za-z0-9._-]*/[A-Za-z0-9._-]*" "/[A-Za-z0-9._/-]*" && cd "/[A-Za-z0-9._/-]*" && exec doey")
          local t="${cmd#git clone https://github.com/}"
          local spec="${t%% *}"
          t="${t#* }"
          local target="${t%% && cd *}"
          _dispatch_clone_open "$spec" "$target" "$why"
          return 0
          ;;
        *)
          printf '  %s✗%s agent RUN command rejected: %s\n' "$_IFB_RED" "$_IFB_RST" "$cmd" >&2
          return 1
          ;;
      esac
      ;;
    CLARIFY)
      _dispatch_clarify "$rest" "$typed"
      return 0
      ;;
    GIVE_UP|*)
      printf '  %s→%s gave up: %s\n' "$_IFB_RED" "$_IFB_RST" "$rest" >&2
      return 1
      ;;
  esac
}

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

    # Stream response from Opus — tee captures for context while streaming to terminal
    local resp _tmp_resp
    _tmp_resp="$(mktemp)"
    printf '\n' >&2
    _doey_chat_respond "$user_input" "$context" | tee "$_tmp_resp" >&2
    resp="$(cat "$_tmp_resp")"
    rm -f "$_tmp_resp"

    if [ -n "$resp" ]; then
      printf '\n' >&2
      context="${context}
User: ${user_input}
Assistant: ${resp}"
    else
      printf '  %s(doey got tongue-tied — try again?)%s\n' "$_chat_dim" "$_chat_reset" >&2
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

  # Clarify continuation — if there's a fresh pending clarify, stitch the
  # previous typed line together with the current reply before classifying.
  local _clarify_json _prev_typed
  _clarify_json="$(_clarify_read 2>/dev/null || true)"
  if [ -n "$_clarify_json" ]; then
    _prev_typed="$(_clarify_parse_field "$_clarify_json" typed 2>/dev/null || true)"
    _clarify_clear
    if [ -n "$_prev_typed" ] && [ -n "$typed" ]; then
      typed="${_prev_typed} — answer: ${typed}"
    fi
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

  # Stats: record intent-fallback classification (category=skill)
  (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill intent_fallback "cmd=${typed}" "mapped_cmd=${command}" &) 2>/dev/null || true

  case "$confidence" in
    NEW_PROJECT)
      # User wants to create a new project — route to doey new <slug>
      local slug="$command"
      local description="$explanation"

      # Sanitize slug: lowercase, replace spaces/special chars with hyphens, trim
      slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

      # Fallback if slug is empty or too generic
      if [ -z "$slug" ] || [ "$slug" = "new-project" ] || [ ${#slug} -lt 2 ]; then
        if _intent_fb_is_tty; then
          printf "  What should we call this project? " >&2
          read -r slug < /dev/tty 2>/dev/null || slug=""
          slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
        fi
        [ -z "$slug" ] && slug="new-project"
      fi

      if _intent_fb_is_tty; then
        printf "  Creating project: ${_IFB_BLD}%s${_IFB_RST}\n" "$slug" >&2
        if [ -n "$description" ]; then
          printf "  (%s)\n" "$description" >&2
        fi
        eval "doey new ${slug}"
      else
        printf '  → doey new %s\n' "$slug" >&2
      fi
      ;;
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
        printf "  (%s)\n" "$explanation" >&2
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
    LOCAL_OPEN)
      # command = absolute dir, explanation = reason
      _dispatch_local_open "$command" "$explanation" || true
      ;;
    CLONE_OPEN)
      # command = owner/repo, explanation = "<target_dir>|<reason>"
      local _co_target="${explanation%%|*}"
      local _co_reason="${explanation#*|}"
      [ "$_co_reason" = "$_co_target" ] && _co_reason=""
      # Accept blank target_dir: fall back to <github_dir>/<repo>
      if [ -z "$_co_target" ]; then
        local _co_repo="${command#*/}"
        _co_target="$(_resolve_github_dir)/${_co_repo}"
      fi
      _dispatch_clone_open "$command" "$_co_target" "$_co_reason" || true
      ;;
    CLARIFY)
      # Parser gives command=explanation=question; use command.
      _dispatch_clarify "$command" "$typed" || true
      ;;
    ESCALATE)
      # explanation = reason the classifier could not decide
      if ! _dispatch_escalate "$typed" "$explanation"; then
        if _intent_fb_is_tty; then
          printf '  %sUnknown command:%s %s\n' "$_IFB_RED" "$_IFB_RST" "$typed" >&2
          printf "  Run ${_IFB_BLD}doey --help${_IFB_RST} for usage\n" >&2
        fi
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
