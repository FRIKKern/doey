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
# Performance layers (checked in order):
#   1. Local chatter blocklist — instant (<1ms)
#   2. Local command pattern matcher — instant (<1ms)
#   3. Persistent disk cache — instant (<5ms)
#   4. Claude (Haiku) — slow path (~3-6s, result cached)
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

# ── Cache layer ───────────────────────────────────────────────────────

_intent_fb_cache_file() {
  local base="${XDG_CACHE_HOME:-$HOME/.cache}"
  printf '%s/doey/intent-cache.tsv' "$base"
}

_intent_fb_cache_get() {
  local key="$1"
  local f
  f=$(_intent_fb_cache_file)
  [ -f "$f" ] || return 1
  local tab
  tab="$(printf '\t')"
  local line
  while IFS= read -r line; do
    case "$line" in
      "${key}${tab}"*)
        printf '%s' "${line#*${tab}}"
        return 0
        ;;
    esac
  done < "$f"
  return 1
}

_intent_fb_cache_put() {
  local key="$1"
  local value="$2"
  local f
  f=$(_intent_fb_cache_file)
  local d="${f%/*}"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 1
  # Skip if already cached
  _intent_fb_cache_get "$key" >/dev/null 2>&1 && return 0
  local tab
  tab="$(printf '\t')"
  printf '%s%s%s\n' "$key" "$tab" "$value" >> "$f" 2>/dev/null || return 1
  # Cap at 200 entries
  if [ "$(wc -l < "$f" 2>/dev/null)" -gt 200 ]; then
    tail -100 "$f" > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f" 2>/dev/null || true
  fi
  return 0
}

# ── Normalize input for matching ──────────────────────────────────────

_intent_fb_normalize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//'
}

# ── Local fast-path matcher ───────────────────────────────────────────
# Returns 0 with result on stdout if matched locally, 1 for fall-through.

_INTENT_FB_CHATTER="yo hi hello hey sup wtf wth lol ok"

_intent_fb_local_match() {
  local key="$1"  # already normalized

  # 1) Chatter/greetings — no need to call Claude
  local word
  for word in $_INTENT_FB_CHATTER; do
    if [ "$key" = "$word" ]; then
      printf 'NONE||Not a doey command. Try: doey help'
      return 0
    fi
  done

  # 2) Common natural-language → doey command patterns
  case "$key" in
    "show task"*|"list task"*|"tasks"|"tsk"|"task")
      printf 'HIGH|doey task list|Matches task list' ; return 0 ;;
    "add task "*)
      local title="${key#add task }"
      printf 'HIGH|doey task add %s|Matches task add' "$title" ; return 0 ;;
    "start tunnel"|"open tunnel"|"tunnel start"|"tunnel open"|"tunnel on"|"tunnel up")
      printf 'HIGH|doey tunnel up|Matches tunnel up' ; return 0 ;;
    "stop tunnel"|"close tunnel"|"tunnel stop"|"tunnel close"|"tunnel off"|"end tunnel"|"tunnel down")
      printf 'HIGH|doey tunnel down|Matches tunnel down' ; return 0 ;;
    "show tunnel"*|"tunnel stat"*|"tunnel"|"tunnels")
      printf 'HIGH|doey tunnel status|Matches tunnel status' ; return 0 ;;
    "show team"*|"list team"*|"show window"*|"list window"*)
      printf 'HIGH|doey list-teams|Matches list-teams' ; return 0 ;;
    "show project"*|"list project"*|"projects")
      printf 'HIGH|doey list|Matches list' ; return 0 ;;
    "show status"|"show state"|"state")
      printf 'HIGH|doey status|Matches status' ; return 0 ;;
    "show config"*|"configuration"|"conf")
      printf 'HIGH|doey config|Matches config' ; return 0 ;;
    "check health"|"health check"|"healthcheck"|"diag"|"diagnose")
      printf 'HIGH|doey doctor|Matches doctor' ; return 0 ;;
    "show version"|"ver")
      printf 'HIGH|doey version|Matches version' ; return 0 ;;
    "reinstall"|"upgrade")
      printf 'HIGH|doey update|Matches update' ; return 0 ;;
    "plan "*)
      local goal="${key#plan }"
      printf 'HIGH|doey masterplan %s|Matches masterplan' "$goal" ; return 0 ;;
  esac

  # 3) Single-word prefix match against known top-level commands
  case "$key" in
    *" "*) ;;  # multi-word — skip prefix matching
    *)
      local matched="" match_count=0
      local cmd
      for cmd in help init list doctor version update build stop reload purge \
                 uninstall settings test add remove status msg config health \
                 agent team teams dynamic masterplan open; do
        case "$cmd" in
          "${key}"*)
            matched="$cmd"
            match_count=$((match_count + 1))
            ;;
        esac
      done
      if [ "$match_count" -eq 1 ]; then
        printf 'HIGH|doey %s|Prefix match' "$matched"
        return 0
      elif [ "$match_count" -gt 1 ]; then
        # Ambiguous prefix — check for exact match first
        for cmd in help init list doctor version update build stop reload purge \
                   uninstall settings test add remove status msg config health \
                   agent team teams dynamic masterplan open; do
          if [ "$key" = "$cmd" ]; then
            printf 'HIGH|doey %s|Exact match' "$cmd"
            return 0
          fi
        done
      fi
      ;;
  esac

  return 1  # no local match — fall through
}

# ── System prompt (used only for Claude slow path) ────────────────────

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

# ── Main lookup ───────────────────────────────────────────────────────
# Takes the user's typed args, returns structured result.
# Usage: _doey_intent_lookup "show tasks"
# Stdout: HIGH|doey task list|'show tasks' maps to 'task list'

_doey_intent_lookup() {
  local typed="$1"

  # Normalize for matching and cache keying
  local key
  key=$(_intent_fb_normalize "$typed")

  [ -z "$key" ] && return 1

  # Fast path 1: local heuristic match (chatter, patterns, prefix)
  local local_result
  if local_result=$(_intent_fb_local_match "$key"); then
    printf '%s' "$local_result"
    return 0
  fi

  # Fast path 2: persistent cache
  local cached
  if cached=$(_intent_fb_cache_get "$key" 2>/dev/null) && [ -n "$cached" ]; then
    printf '%s' "$cached"
    return 0
  fi

  # Slow path: Claude (Haiku)
  local sys_prompt
  sys_prompt=$(_intent_fb_system_prompt)

  # Run from /tmp to avoid loading heavy project context (CLAUDE.md scans).
  # --max-turns 1: no tools, single inference pass.
  local resp
  resp=$(cd /tmp && doey_headless "The user typed: doey ${typed}" \
    --model haiku \
    --no-tools \
    --max-turns 1 \
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
    line="NONE||${oneline}"
  fi

  # Cache the result for next time
  _intent_fb_cache_put "$key" "$line" 2>/dev/null || true

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
