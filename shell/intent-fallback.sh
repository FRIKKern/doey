#!/usr/bin/env bash
# shell/intent-fallback.sh — CLI command expert fallback
#
# Provides: _doey_intent_lookup "<typed_args>"
# Output on stdout: JSON object with action, command, confidence, explanation, destructive
# Returns 0 on success, 1 on failure (empty stdout).
# Silent fallthrough on all failures — never makes the CLI worse.
#
# Bash 3.2 compatible. Requires jq.

set -uo pipefail

# Source guard
[ "${__doey_intent_fallback_sourced:-}" = "1" ] && return 0 2>/dev/null || true
__doey_intent_fallback_sourced=1

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"

# shellcheck source=doey-headless.sh
source "${SCRIPT_DIR}/doey-headless.sh"

# Main lookup: takes the user's typed args, returns structured JSON result.
# Usage: _doey_intent_lookup "show tasks"
# Stdout: {"action":"run_command","command":"doey task list","confidence":"high","explanation":"...","destructive":false}
_doey_intent_lookup() {
  local typed="$1"

  local schema_file="${SCRIPT_DIR}/intent-schema.json"
  local system_prompt_file="${SCRIPT_DIR}/command-expert-system-prompt.txt"

  if [ ! -f "$schema_file" ]; then
    echo "intent-fallback: schema file not found: $schema_file" >&2
    return 1
  fi
  if [ ! -f "$system_prompt_file" ]; then
    echo "intent-fallback: system prompt file not found: $system_prompt_file" >&2
    return 1
  fi

  local system_prompt
  system_prompt="$(cat "$system_prompt_file")"

  local resp
  resp=$(doey_headless "The user typed: doey ${typed}" \
    --model haiku \
    --no-tools \
    --timeout 15 \
    --schema "$schema_file" \
    --append-system "$system_prompt" \
    2>/dev/null) || true

  if [ -z "$resp" ]; then
    return 1
  fi

  # The headless wrapper returns {"text":"...","success":...,...}
  # Extract the text field which contains the structured JSON from the schema
  if ! command -v jq >/dev/null 2>&1; then
    echo "intent-fallback: jq required for JSON parsing" >&2
    return 1
  fi

  local result_text
  result_text="$(printf '%s' "$resp" | jq -r '.text // empty' 2>/dev/null)" || true

  if [ -z "$result_text" ]; then
    return 1
  fi

  # Validate the parsed JSON has the required fields
  local action
  action="$(printf '%s' "$result_text" | jq -r '.action // empty' 2>/dev/null)" || true

  if [ -z "$action" ]; then
    return 1
  fi

  # Output the structured JSON
  printf '%s' "$result_text"
  return 0
}

# When executed directly (not sourced), run the function
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] 2>/dev/null; then
  _doey_intent_lookup "$@"
fi
