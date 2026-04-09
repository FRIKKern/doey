#!/usr/bin/env bash
# shell/intent-fallback.sh — CLI command expert fallback
#
# Provides: _doey_intent_lookup "<typed_args>"
# Output on stdout: HIGH|<command>|<explanation>
#                   MEDIUM|<command>|<explanation>
#                   NONE||<explanation>
# Returns 0 on success, 1 on failure (empty stdout).
# Silent fallthrough on all failures — never makes the CLI worse.
#
# Bash 3.2 compatible. No jq dependency.

set -uo pipefail

# Source guard
[ "${__doey_intent_fallback_sourced:-}" = "1" ] && return 0 2>/dev/null || true
__doey_intent_fallback_sourced=1

# shellcheck source=doey-headless.sh
source "${BASH_SOURCE[0]%/*}/doey-headless.sh"

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
  NONE||<brief explanation suggesting closest commands>

Rules:
- HIGH: confident single match. Command MUST exist in the reference.
- MEDIUM: probable but ambiguous. Still a real command.
- NONE: no match. Suggest the closest commands from the reference.
- Never invent commands not in the reference.
- Explanation under 80 characters.
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

  local resp
  resp=$(doey_headless "The user typed: doey ${typed}" \
    --model haiku \
    --no-tools \
    --timeout 15 \
    --append-system "$sys_prompt" \
    2>/dev/null) || true

  if [ -z "$resp" ]; then
    return 1
  fi

  # Extract the first line matching our format
  local line
  line=$(printf '%s\n' "$resp" | grep -E '^(HIGH|MEDIUM|NONE)\|' | head -1)

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
