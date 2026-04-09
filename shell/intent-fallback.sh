#!/usr/bin/env bash
# shell/intent-fallback.sh — CLI command expert fallback
#
# Provides: _doey_intent_lookup "<typed_args>"
#           _doey_chat_respond "<message>" ["<context>"]
# Output on stdout: HIGH|<command>|<explanation>
#                   MEDIUM|<command>|<explanation>
#                   CHAT||<response>
#                   NONE||<explanation>
# Returns 0 on success, 1 on failure (empty stdout).
# Silent fallthrough on all failures — never makes the CLI worse.
#
# Bash 3.2 compatible. No jq dependency.

set -uo pipefail

# Source guard
[ "${__doey_intent_fallback_sourced:-}" = "1" ] && return 0 2>/dev/null || true
__doey_intent_fallback_sourced=1

_intent_fb_is_tty() {
  [ "${_INTENT_FB_TTY_CACHED:-}" ] && { [ "$_INTENT_FB_TTY_CACHED" = "1" ]; return; }
  if [ -t 0 ] && [ -t 2 ]; then
    _INTENT_FB_TTY_CACHED=1; return 0
  else
    _INTENT_FB_TTY_CACHED=0; return 1
  fi
}

_intent_fb_init_color() {
  if [ -n "${NO_COLOR:-}" ] || ! _intent_fb_is_tty; then
    _IFB_RED="" _IFB_GREEN="" _IFB_YLW="" _IFB_CYAN="" _IFB_DIM="" _IFB_BLD="" _IFB_RST=""
  else
    _IFB_RED=$'\033[31m' _IFB_GREEN=$'\033[32m' _IFB_YLW=$'\033[33m'
    _IFB_CYAN=$'\033[36m' _IFB_DIM=$'\033[2m' _IFB_BLD=$'\033[1m' _IFB_RST=$'\033[0m'
  fi
}

_intent_fb_spinner_start() {
  _intent_fb_is_tty || return 0
  [ -n "${NO_COLOR:-}" ] && return 0
  _IFB_SPINNER_PID=""
  { tput civis 2>/dev/null || true; } >&2
  (
    _chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    _words="Doeying Snootling Waggening Snorfeling Cozymaxxing Ruffling Floofing Scampering Sniffvestigating Recombobulating"
    set -- $_words
    _wcount=$#
    _wi=0
    _ci=0
    _di=1
    _tick=0
    while true; do
      _wi=$(( (_tick / 12) % _wcount + 1 ))
      eval "_w=\${$_wi}"
      _di=$(( (_tick / 4) % 3 + 1 ))
      case $_di in
        1) _dots="." ;;
        2) _dots=".." ;;
        3) _dots="..." ;;
      esac
      printf '\r\033[K  %s %s%s' "${_chars:$_ci:1}" "$_w" "$_dots" >&2
      _ci=$(( (_ci + 1) % ${#_chars} ))
      _tick=$(( _tick + 1 ))
      sleep 0.08
    done
  ) &
  _IFB_SPINNER_PID=$!
}

_intent_fb_spinner_stop() {
  [ -n "${_IFB_SPINNER_PID:-}" ] && kill "$_IFB_SPINNER_PID" 2>/dev/null && wait "$_IFB_SPINNER_PID" 2>/dev/null
  _IFB_SPINNER_PID=""
  if _intent_fb_is_tty; then
    printf '\r\033[K' >&2
    { tput cnorm 2>/dev/null || true; } >&2
  fi
}

# shellcheck source=doey-headless.sh
source "${BASH_SOURCE[0]%/*}/doey-headless.sh"

# --- TTY detection (cached) ---
_intent_fb_is_tty() {
  [ "${_INTENT_FB_TTY_CACHED:-}" ] && { [ "$_INTENT_FB_TTY_CACHED" = "1" ]; return; }
  if [ -t 0 ] && [ -t 2 ]; then
    _INTENT_FB_TTY_CACHED=1; return 0
  else
    _INTENT_FB_TTY_CACHED=0; return 1
  fi
}

# --- NO_COLOR-aware color init ---
_intent_fb_init_color() {
  if [ -n "${NO_COLOR:-}" ] || ! _intent_fb_is_tty; then
    _IFB_RED="" _IFB_YLW="" _IFB_BLD="" _IFB_RST=""
  else
    _IFB_RED=$'\033[31m' _IFB_YLW=$'\033[33m' _IFB_BLD=$'\033[1m' _IFB_RST=$'\033[0m'
  fi
}

# --- Spinner (stderr only, Bash 3.2 safe) ---
_intent_fb_spinner_start() {
  _intent_fb_is_tty || return 0
  [ -n "${NO_COLOR:-}" ] && return 0
  _IFB_SPINNER_PID=""
  { tput civis 2>/dev/null || true; } >&2
  (
    _chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    _words=(Doeying Snootling Waggening Snorfeling Cozymaxxing Ruffling Floofing Scampering Sniffvestigating Recombobulating)
    _wcount=${#_words[@]}
    _wi=0
    _di=1
    _ci=0
    while true; do
      _dots=""
      _d=0
      while [ "$_d" -lt "$_di" ]; do _dots="${_dots}."; _d=$((_d + 1)); done
      printf '\r\033[K  %s %s%s' "${_chars:$_ci:1}" "${_words[$_wi]}" "$_dots" >&2
      _ci=$(( (_ci + 1) % ${#_chars} ))
      _di=$((_di + 1))
      if [ "$_di" -gt 3 ]; then
        _di=1
        _wi=$(( (_wi + 1) % _wcount ))
      fi
      sleep 0.08
    done
  ) &
  _IFB_SPINNER_PID=$!
}

_intent_fb_spinner_stop() {
  [ -n "${_IFB_SPINNER_PID:-}" ] && kill "$_IFB_SPINNER_PID" 2>/dev/null && wait "$_IFB_SPINNER_PID" 2>/dev/null
  _IFB_SPINNER_PID=""
  if _intent_fb_is_tty; then
    printf '\r\033[K' >&2
    { tput cnorm 2>/dev/null || true; } >&2
  fi
}

# Commands that must ALWAYS prompt for confirmation, even at HIGH confidence.
_INTENT_FB_DESTRUCTIVE="uninstall stop kill purge reset"

_intent_fb_system_prompt() {
  cat <<'SYSPROMPT'
You are a doey CLI command expert. Your ONLY job is to identify which doey command the user intended.

COMPLETE COMMAND REFERENCE:
  doey                          Start/attach session (smart launch)
  doey help                     Show help
  doey init                     Register current directory as project
  doey list                     List registered projects
  doey doctor                   Check system health
  doey version                  Show version info
  doey update                   Pull latest and reinstall (alias: reinstall)
  doey build                    Build Go binaries
  doey stop                     Stop current project session
  doey reload                   Hot-reload session
  doey reload --workers         Also restart workers
  doey purge                    Scan/clean stale runtime files
  doey uninstall                Remove all Doey files
  doey settings                 Open interactive settings
  doey remote list              List remote servers
  doey remote provision         Provision a remote server
  doey remote stop <name>       Stop a remote server
  doey remote status <name>     Show remote server status
  doey remote setup             Setup remote server
  doey deploy start             Start deploy validation
  doey deploy status            Show deploy status
  doey deploy gate              Deploy gate check
  doey test                     Run E2E tests
  doey test dispatch            Test dispatch chain
  doey add                      Add worker column to dynamic session
  doey add-team <name>          Add team from definition
  doey add-window               Add team window interactively
  doey remove <n|name>          Remove worker column or unregister project
  doey kill-team <n>            Kill team window by index
  doey list-teams               Show all team windows (alias: list-windows)
  doey teams                    List available team definitions
  doey masterplan <goal>        Start masterplan team (alias: plan)
  doey tunnel up                Start localhost tunnel
  doey tunnel down              Stop localhost tunnel
  doey tunnel status            Show tunnel status
  doey open <name>              Open/attach to a registered project by name
  doey dynamic                  Launch with dynamic grid (alias: d)
  doey <NxM>                    Launch with grid (e.g. 4x3, 6x2)
  doey task list                List tasks
  doey task add <title>         Add a task
  doey task show <id>           Show task details
  doey task transition <id> <s> Change task state
  doey status                   Show pane/worker status
  doey msg <pane> <text>        Send message to pane
  doey config                   Show configuration
  doey health                   System health check
  doey agent                    Agent management
  doey team                     Team management

RESPONSE FORMAT — respond with EXACTLY one line:
  HIGH|<full command>|<brief explanation>
  MEDIUM|<full command>|<brief explanation>
  CHAT||<warm friendly response to the user>
  NONE||<brief explanation suggesting closest commands>

Rules:
- HIGH: confident single match. Command MUST exist in the reference.
- MEDIUM: probable but ambiguous. Still a real command.
- CHAT: the input is clearly conversational — a greeting, question about doey, casual chat, or anything that is NOT a mistyped command. Respond warmly as doey's friendly companion personality. Keep responses concise (under 200 chars).
- NONE: no match. Suggest the closest commands from the reference.
- Never invent commands not in the reference.
- Explanation under 80 characters (except CHAT, which can be up to 200).
- Output EXACTLY one line. No preamble, no markdown, no extra text.
SYSPROMPT
}

# Main lookup: takes the user's typed args, returns structured result.
# Usage: _doey_intent_lookup "show tasks"
# Stdout: HIGH|doey task list|'show tasks' maps to 'task list'
_doey_intent_lookup() {
  local typed="$1"

  local sys_prompt
  sys_prompt=$(_intent_fb_system_prompt)

  _intent_fb_init_color
  trap '_intent_fb_spinner_stop; exit 130' INT
  _intent_fb_spinner_start

  # Run from /tmp to avoid loading heavy project context (CLAUDE.md scans),
  # and bump --max-turns so claude doesn't bail with "Reached max turns (1)".
  local resp
  resp=$(cd /tmp && doey_headless "The user typed: doey ${typed}" \
    --model opus \
    --no-tools \
    --max-turns 20 \
    --timeout 20 \
    --append-system "$sys_prompt" \
    2>/dev/null) || true
  _intent_fb_spinner_stop
  trap - INT

  _intent_fb_spinner_stop
  trap - INT

  if [ -z "$resp" ]; then
    return 1
  fi

  # Extract the first line matching our format
  local line
  line=$(printf '%s\n' "$resp" | grep -E '^(HIGH|MEDIUM|NONE|CHAT)\|' | head -1)

  if [ -z "$line" ]; then
    # Claude didn't follow format — treat as no match with its text as explanation
    local oneline
    oneline=$(printf '%s' "$resp" | tr '\n' ' ' | head -c 200)
    printf 'NONE||%s' "$oneline"
    return 0
  fi

  printf '%s' "$line"
  return 0
}

# Chat response via Opus — used by the conversational REPL
# Args: $1 = user message, $2 = conversation context (optional, for follow-ups)
# Streams response directly to stdout via --stream flag
_doey_chat_respond() {
  local msg="$1"
  local context="${2:-}"
  local chat_prompt
  chat_prompt='You are doey, a friendly and capable CLI companion. You help users with the doey multi-agent CLI tool and their projects.

IMPORTANT — Use your tools proactively:
- Use Bash to explore the filesystem, run commands, search for files, check project status
- Use Read to examine file contents when relevant
- When the user asks you to find something, actually search for it
- When the user asks about their project or system, investigate with real commands
- Do not just describe what you would do — do it and report the results

You are warm, helpful, a bit playful — cozy campfire vibes. Keep your final answer concise but do not hesitate to do real investigative work to give a good answer.

Context: doey creates tmux-based multi-agent Claude Code teams for any project. The user is running doey from the command line.'

  local full_msg="$msg"
  if [ -n "$context" ]; then
    full_msg="${context}
User: ${msg}"
  fi

  # Stream response directly — no spinner needed, output flows in real time
  doey_headless "$full_msg" \
    --model opus \
    --stream \
    --max-turns 10 \
    --timeout 120 \
    --append-system "$chat_prompt" \
    2>/dev/null || true
}

# Check if a command contains a destructive keyword.
_intent_fb_is_destructive() {
  local cmd="$1"
  local word
  for word in $_INTENT_FB_DESTRUCTIVE; do
    case "$cmd" in
      *"$word"*) return 0 ;;
    esac
  done
  return 1
}
