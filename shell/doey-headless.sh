#!/usr/bin/env bash
set -euo pipefail

# Source guard — allow sourcing without re-execution
[ "${__doey_headless_sourced:-}" = "1" ] && return 0 2>/dev/null || true
__doey_headless_sourced=1

# Usage: doey_headless <message> [--model haiku|sonnet|opus|<full-name>]
#        [--no-tools] [--json] [--timeout N] [--system FILE] [--append-system PROMPT_STRING]
#        [--schema FILE]

doey_headless() {
  local message=""
  local model="${DOEY_HEADLESS_MODEL:-opus}"
  local no_tools=0
  local json_mode=0
  local timeout_secs="${DOEY_HEADLESS_TIMEOUT:-30}"
  local system_file=""
  local append_system=""
  local schema_file=""

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)
        shift
        model="$1"
        ;;
      --no-tools)
        no_tools=1
        ;;
      --json)
        json_mode=1
        ;;
      --timeout)
        shift
        timeout_secs="$1"
        ;;
      --system)
        shift
        system_file="$1"
        ;;
      --append-system)
        shift
        append_system="$1"
        ;;
      --schema)
        shift
        schema_file="$1"
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "doey-headless: unknown flag: $1" >&2
        return 1
        ;;
      *)
        if [ -z "$message" ]; then
          message="$1"
        fi
        ;;
    esac
    shift
  done

  # Read from stdin if message is "-"
  if [ "$message" = "-" ]; then
    message="$(cat)"
  fi

  if [ -z "$message" ]; then
    echo "Usage: doey-headless <message> [--model haiku|sonnet|opus] [--no-tools] [--json] [--timeout N] [--system FILE] [--append-system PROMPT] [--schema FILE]" >&2
    return 1
  fi

  # Check disable flag
  if [ "${DOEY_HEADLESS_DISABLE:-}" = "1" ]; then
    echo ""
    return 0
  fi

  # Require claude CLI
  if ! command -v claude >/dev/null 2>&1; then
    echo "doey-headless: claude CLI not found (install: npm i -g @anthropic-ai/claude-code)" >&2
    return 2
  fi

  # Resolve model shorthand
  case "${model}" in
    haiku)  model="claude-haiku-4-5-20251001" ;;
    sonnet) model="claude-sonnet-4-6" ;;
    opus)   model="claude-opus-4-6" ;;
  esac

  # Find timeout binary
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  fi

  # Build claude command as an array (no eval)
  claude_cmd=(claude -p --bare --model "$model" --no-session-persistence)

  # Output format: --schema forces json output
  if [ -n "$schema_file" ]; then
    if [ ! -f "$schema_file" ]; then
      echo "doey-headless: schema file not found: $schema_file" >&2
      return 1
    fi
    local schema_content
    schema_content="$(cat "$schema_file")"
    claude_cmd=("${claude_cmd[@]}" --output-format json --json-schema "$schema_content")
  elif [ "$json_mode" -eq 1 ]; then
    claude_cmd=("${claude_cmd[@]}" --output-format json)
  else
    claude_cmd=("${claude_cmd[@]}" --output-format text)
  fi

  # Tool restriction
  if [ "$no_tools" -eq 1 ]; then
    claude_cmd=("${claude_cmd[@]}" --allowed-tools "")
  fi

  # System prompt options
  if [ -n "$system_file" ]; then
    if [ ! -f "$system_file" ]; then
      echo "doey-headless: system file not found: $system_file" >&2
      return 1
    fi
    local system_content
    system_content="$(cat "$system_file")"
    claude_cmd=("${claude_cmd[@]}" --system-prompt "$system_content")
  fi
  if [ -n "$append_system" ]; then
    claude_cmd=("${claude_cmd[@]}" --append-system-prompt "$append_system")
  fi

  # Record start time
  local start_ts
  start_ts="$(date +%s)"

  # Run claude via stdin pipe
  local raw_output=""
  local exit_code=0

  if [ -n "$timeout_bin" ]; then
    raw_output="$(printf '%s' "$message" | "$timeout_bin" "$timeout_secs" "${claude_cmd[@]}" 2>&1)" || exit_code=$?
  else
    raw_output="$(printf '%s' "$message" | "${claude_cmd[@]}" 2>&1)" || exit_code=$?
  fi

  # Map timeout exit code
  if [ "$exit_code" -eq 124 ]; then
    exit_code=4
  fi

  # Calculate latency
  local end_ts
  end_ts="$(date +%s)"
  local latency_ms=$(( (end_ts - start_ts) * 1000 ))

  # Parse output
  local response_text=""
  local parsed_model="$model"
  local parsed_success="true"
  local parsed_turns="0"
  local parsed_cost="0"

  if [ "$json_mode" -eq 1 ] || [ -n "$schema_file" ]; then
    # claude -p --output-format json returns a JSON object
    # Extract fields with jq if available, otherwise basic sed parsing
    if command -v jq >/dev/null 2>&1; then
      response_text="$(printf '%s' "$raw_output" | jq -r '.result // empty' 2>/dev/null)" || response_text=""
      local is_error
      is_error="$(printf '%s' "$raw_output" | jq -r '.is_error // false' 2>/dev/null)" || is_error="false"
      if [ "$is_error" = "true" ]; then
        parsed_success="false"
      else
        parsed_success="true"
      fi
      parsed_turns="$(printf '%s' "$raw_output" | jq -r '.num_turns // 0' 2>/dev/null)" || parsed_turns="0"
      parsed_cost="$(printf '%s' "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)" || parsed_cost="0"
      parsed_model="$(printf '%s' "$raw_output" | jq -r '.modelUsage | keys[0] // empty' 2>/dev/null)" || parsed_model="$model"
    else
      # Basic sed fallback for JSON parsing
      response_text="$(printf '%s' "$raw_output" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)" || response_text=""
      parsed_turns="$(printf '%s' "$raw_output" | sed -n 's/.*"num_turns"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)" || parsed_turns="0"
      parsed_cost="$(printf '%s' "$raw_output" | sed -n 's/.*"total_cost_usd"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1)" || parsed_cost="0"
    fi
    if [ -z "$parsed_turns" ]; then parsed_turns="0"; fi
    if [ -z "$parsed_cost" ]; then parsed_cost="0"; fi
    if [ -z "$parsed_model" ]; then parsed_model="$model"; fi

    # Emit reshaped JSON
    local escaped_text
    escaped_text="$(printf '%s' "$response_text" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk '{if(NR>1) printf "\\n"; printf "%s", $0}')"
    printf '{"text":"%s","success":%s,"turns":%s,"cost":"%s","model":"%s"}\n' \
      "$escaped_text" "$parsed_success" "$parsed_turns" "$parsed_cost" "$parsed_model"
  else
    # Text mode — claude -p --output-format text returns clean text
    response_text="$raw_output"
    if [ -n "$response_text" ]; then
      printf '%s\n' "$response_text"
    fi
  fi

  # Determine final exit code
  if [ -z "$response_text" ] && [ "$parsed_success" = "false" ]; then
    if [ "$exit_code" -eq 0 ]; then
      exit_code=1
    fi
  fi

  # Detect caller
  local caller="direct"
  if [ "${#FUNCNAME[@]}" -gt 1 ] 2>/dev/null; then
    caller="${FUNCNAME[1]:-direct}"
  elif [ -n "${0:-}" ]; then
    caller="$(basename "$0")"
  fi

  # Logging
  local log_dir="${DOEY_RUNTIME:-/tmp/doey/${PROJECT_NAME:-unknown}}"
  if [ ! -d "$log_dir" ]; then
    mkdir -p "$log_dir" 2>/dev/null || true
  fi
  local log_file="$log_dir/headless.log"
  local iso_ts
  iso_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"
  local msg_preview="${message:0:80}"
  msg_preview="$(echo "$msg_preview" | tr '\n' ' ')"
  echo "$iso_ts $parsed_model \$$parsed_cost ${latency_ms}ms $exit_code $caller $msg_preview" >> "$log_file" 2>/dev/null || true

  return "$exit_code"
}

# When executed directly (not sourced), run the function
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] 2>/dev/null; then
  doey_headless "$@"
fi
