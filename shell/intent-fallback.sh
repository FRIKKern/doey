#!/usr/bin/env bash
# shell/intent-fallback.sh — Claude CLI Intent Fallback helper
#
# Provides a single function:
#   intent_fallback "<typed_cmd>" "<error_msg>" "<schema>" "<recent_ctx>"
#
# Invokes the local `claude` CLI binary (Claude Code) in headless mode and
# returns a structured JSON decision on stdout, or an empty string on ANY
# failure (binary missing, disabled, timeout, non-JSON output, etc.).
# The function never exits non-zero; callers MUST handle an empty payload
# gracefully.
#
# Design constraints:
#   - Silent fallthrough on every failure path. A broken fallback must not
#     make a failing CLI feel slower or more confusing than "no fallback".
#   - Hard 30s ceiling via timeout(1) / gtimeout(1).
#   - Uses the local claude CLI — no REST calls, no direct Anthropic API use.
#     Authentication is whatever claude itself supports (env var, keychain,
#     apiKeyHelper, etc.). We do not gate on $ANTHROPIC_API_KEY.
#   - Bash 3.2 compatible (avoids all bash 4+ features).
#   - set -uo pipefail (NOT -e — we need controlled fallthrough).
#
# Opt-out gates (all cause silent return ""):
#   - DOEY_INTENT_FALLBACK=0      (positive-logic off switch, Phase 2)
#   - DOEY_NO_INTENT_FALLBACK=1   (negative-logic kill switch, legacy)
#   - claude binary not on PATH
#   - jq missing (still required for JSON parsing)
#   - no timeout wrapper (neither `timeout` nor `gtimeout` on PATH)
#   - claude exits non-zero (timeout, auth failure, network down, anything)
#   - claude output not parseable as JSON
#   - extracted payload not parseable as structured JSON
#
# Secrets discipline:
#   - Never echoes $ANTHROPIC_API_KEY.
#   - Never writes the request prompt to disk or log.
#   - Redacts --body/--token/--key/--password/--secret/--auth flag values
#     in log lines (both `--flag=value` and `--flag value` forms).
#
# Log format: one JSON line per successful call, appended to
#   /tmp/doey/${PROJECT_NAME:-doey}/intent-log.jsonl
# with fields {ts, pane, role, project, typed, err, action, command,
# latency_ms, http_status, accepted, reason}. The http_status field is
# preserved for backward compatibility with the REST-era schema and is
# now always JSON null.
#
# Cleanup: this file lives inside the project runtime dir which is wiped
# by `doey stop` (shell/doey-session.sh). No separate cleanup hook.
#
# Log rotation: when the file exceeds 1 MB the appender rotates it to
# intent-log.jsonl.{1,2,3}. The oldest rotation (.3) is discarded.
#
# Concurrency: appends are serialized via an mkdir-based lock so parallel
# invocations from multiple panes cannot interleave partial lines.

set -uo pipefail

# Source guard — prevent double-sourcing.
[ "${__doey_intent_fallback_sourced:-}" = "1" ] && return 0
__doey_intent_fallback_sourced=1

# ── Internal helpers ────────────────────────────────────────────────

# Current time in milliseconds since the epoch. Portable across GNU date
# (supports %N) and BSD date (macOS, does not). Progressive fallback:
# GNU %N → python3 → perl → seconds*1000.
_intent_fb_now_ms() {
  local t
  t=$(date +%s%N 2>/dev/null)
  case "$t" in
    *N|"")
      if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null && return 0
      fi
      if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)' 2>/dev/null && return 0
      fi
      printf '%s000' "$(date +%s 2>/dev/null || echo 0)"
      ;;
    *)
      printf '%s' "$((t / 1000000))"
      ;;
  esac
}

# Redact sensitive flag values from a command string before logging.
# Matches --body|--token|--key|--password|--secret|--auth followed by
# either '=<value>' or '<space><value>'.
_intent_fb_redact() {
  # shellcheck disable=SC2016
  printf '%s' "$1" | sed -E \
    -e 's/(--(body|token|key|password|secret|auth))=[^[:space:]]*/\1=***/g' \
    -e 's/(--(body|token|key|password|secret|auth))[[:space:]]+[^[:space:]]+/\1 ***/g'
}

# Acquire an mkdir-based lock. Returns 0 on success, 1 on timeout.
# Retries up to 100 times, ~10ms apart, for a ~1s ceiling. Never blocks
# forever — a stuck lock must not freeze the fallback path.
_intent_fb_lock_acquire() {
  local lockdir="$1"
  local tries=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then
      return 1
    fi
    sleep 0.01 2>/dev/null || :
  done
  return 0
}

_intent_fb_lock_release() {
  rmdir "$1" 2>/dev/null || true
}

# Rotate log file if it has grown past 1 MB. Keeps at most
# intent-log.jsonl.{1,2,3}; anything older is discarded.
_intent_fb_rotate_if_large() {
  local f="$1"
  [ -f "$f" ] || return 0
  local sz
  sz=$(wc -c < "$f" 2>/dev/null || echo 0)
  sz=$(printf '%s' "$sz" | tr -d '[:space:]')
  case "$sz" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$sz" -ge 1048576 ] || return 0
  if [ -f "${f}.2" ]; then
    mv "${f}.2" "${f}.3" 2>/dev/null || true
  fi
  if [ -f "${f}.1" ]; then
    mv "${f}.1" "${f}.2" 2>/dev/null || true
  fi
  mv "$f" "${f}.1" 2>/dev/null || true
}

# Locate a timeout binary. `timeout` on Linux; `gtimeout` on macOS when
# coreutils is installed. Returns 0 and sets _INTENT_FB_TIMEOUT_BIN on
# success, returns 1 on failure (caller must silent-fallthrough).
_intent_fb_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    _INTENT_FB_TIMEOUT_BIN="timeout"
    return 0
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    _INTENT_FB_TIMEOUT_BIN="gtimeout"
    return 0
  fi
  return 1
}

# ── Public function ─────────────────────────────────────────────────

intent_fallback() {
  local typed="${1:-}"
  local err_msg="${2:-}"
  local schema="${3:-}"
  local recent="${4:-}"

  # Opt-out gates — both positive-logic (DOEY_INTENT_FALLBACK=0) and
  # negative-logic (DOEY_NO_INTENT_FALLBACK=1) are honoured.
  if [ "${DOEY_INTENT_FALLBACK:-1}" = "0" ]; then
    echo ""
    return 0
  fi
  if [ "${DOEY_NO_INTENT_FALLBACK:-0}" = "1" ]; then
    echo ""
    return 0
  fi

  # Dependencies. All missing-binary paths degrade silently — the CLI
  # must not get slower or more confusing because the fallback is broken.
  command -v claude >/dev/null 2>&1 || { echo ""; return 0; }
  command -v jq     >/dev/null 2>&1 || { echo ""; return 0; }

  local _INTENT_FB_TIMEOUT_BIN=""
  _intent_fb_timeout_bin || { echo ""; return 0; }

  # System prompt pins the response shape. We ask for ONE JSON object
  # matching our action schema, with hard instructions to never invent
  # commands. The full CLI schema is passed in the user prompt body.
  local sys_prompt
  sys_prompt='You correct Doey CLI mistakes. Given a typed command, the error message, the valid CLI schema, and recent context, respond with ONLY a single JSON object matching this schema:

{"action": "auto_correct"|"suggest"|"clarify"|"unknown", "command": "string (for auto_correct)", "options": ["string"] (1-3 items, for suggest), "question": "string (for clarify)", "reason": "brief explanation"}

Rules:
- auto_correct: confident single fix. Set .command to the corrected full command line.
- suggest: 1-3 plausible alternatives when you are not sure. Set .options.
- clarify: ask ONE short question when you need more info. Set .question.
- unknown: give up — return this when nothing in the schema is a good match.
- ALWAYS set .reason (brief, <80 chars).
- Never invent commands not in the schema.
- Output ONLY the JSON object. No preamble, no code fences, no trailing prose.'

  # User prompt body — typed line, error, CLI schema, recent context.
  local user_prompt
  user_prompt="typed: ${typed}
error: ${err_msg}

schema:
${schema}

recent:
${recent}"

  local t_start t_end latency_ms
  t_start=$(_intent_fb_now_ms)

  # Spawn claude with hard 30s timeout. Flags:
  #   --bare                       minimal mode (no hooks, no plugins, no CLAUDE.md)
  #   -p "$user_prompt"            headless print mode
  #   --output-format json         single-result JSON object
  #   --no-session-persistence     do not write session files to disk
  #   --append-system-prompt "..." pin response shape
  #   --model claude-haiku-4-5-20251001  Haiku pin from docs/intent-fallback.md
  #   --permission-mode plan       read-only, never writes
  #   --tools ""                   disable all tools (just want a reply)
  #
  # stderr is routed to /dev/null — any chatter from auth failures or
  # plugin warnings would pollute downstream error output.
  local resp
  resp=$("$_INTENT_FB_TIMEOUT_BIN" 30 claude \
    --bare \
    -p "$user_prompt" \
    --output-format json \
    --no-session-persistence \
    --append-system-prompt "$sys_prompt" \
    --model "claude-haiku-4-5-20251001" \
    --permission-mode plan \
    --tools "" \
    2>/dev/null)
  local claude_rc=$?

  t_end=$(_intent_fb_now_ms)
  latency_ms=$(( t_end - t_start ))

  if [ "$claude_rc" -ne 0 ] || [ -z "$resp" ]; then
    echo ""
    return 0
  fi

  # Validate the outer CLI response is parseable JSON.
  if ! printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
    echo ""
    return 0
  fi

  # Extract the assistant's text result. `claude --output-format json`
  # returns a single object with a top-level `.result` field containing
  # the assistant's final response. We instructed the model to output
  # ONLY a JSON object in that response.
  local payload
  payload=$(printf '%s' "$resp" | jq -r '.result // empty' 2>/dev/null)
  if [ -z "$payload" ]; then
    echo ""
    return 0
  fi

  # The model may have wrapped the JSON in a ```json ... ``` fence or
  # added incidental whitespace despite the instruction. Strip common
  # wrappers before the final JSON parse.
  payload=$(printf '%s' "$payload" | sed -E \
    -e 's/^[[:space:]]*```[[:alnum:]]*[[:space:]]*//' \
    -e 's/[[:space:]]*```[[:space:]]*$//')

  # Validate the extracted payload is parseable JSON with a .action field.
  if ! printf '%s' "$payload" | jq -e '.action' >/dev/null 2>&1; then
    echo ""
    return 0
  fi

  # ── Log successful call (redacted, no secrets) ──
  local action cmd_field reason_field
  action=$(printf '%s'       "$payload" | jq -r '.action  // ""' 2>/dev/null)
  cmd_field=$(printf '%s'    "$payload" | jq -r '.command // ""' 2>/dev/null)
  reason_field=$(printf '%s' "$payload" | jq -r '.reason  // ""' 2>/dev/null)

  local ts pane role project typed_red err_red
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
  pane="${DOEY_PANE_ID:-${TMUX_PANE:-}}"
  role="${DOEY_ROLE:-}"
  project="${PROJECT_NAME:-doey}"
  typed_red=$(_intent_fb_redact "$typed")
  err_red=$(_intent_fb_redact "$err_msg")

  local log_dir="/tmp/doey/${project}"
  local log_file="${log_dir}/intent-log.jsonl"
  mkdir -p "$log_dir" 2>/dev/null || true

  # http_status is a REST-era field. Always null in the CLI path — but
  # kept in the schema so existing log consumers (test-intent-fallback-log.sh,
  # dashboards) do not break.
  local log_line
  log_line=$(jq -cn \
    --arg ts             "$ts" \
    --arg pane           "$pane" \
    --arg role           "$role" \
    --arg project        "$project" \
    --arg typed          "$typed_red" \
    --arg err            "$err_red" \
    --arg action         "$action" \
    --arg command        "$cmd_field" \
    --arg reason         "$reason_field" \
    --argjson latency    "$latency_ms" \
    '{
       ts: $ts,
       pane: $pane,
       role: $role,
       project: $project,
       typed: $typed,
       err: $err,
       action: $action,
       command: $command,
       latency_ms: $latency,
       http_status: null,
       accepted: true,
       reason: $reason
     }' 2>/dev/null)

  if [ -n "$log_line" ]; then
    # Belt-and-braces: if the rendered line contains the literal
    # $ANTHROPIC_API_KEY, drop it and write an error marker instead.
    # Only activates when ANTHROPIC_API_KEY is actually set; under the
    # new CLI path the key is not required, so skip the check otherwise.
    if [ -n "${ANTHROPIC_API_KEY:-}" ] && \
       printf '%s' "$log_line" | grep -qF -- "$ANTHROPIC_API_KEY"; then
      log_line='{"error":"api_key_leak_prevented"}'
    fi

    # Rotate BEFORE the append so the pre-append size is what gates it.
    _intent_fb_rotate_if_large "$log_file"

    # Serialize concurrent appenders via mkdir lock. If we cannot acquire
    # it within the retry budget, append anyway — lines under PIPE_BUF
    # (4 KB on Linux) are atomic, so unlocked appends still work.
    local lockdir="${log_file}.lock"
    _intent_fb_lock_acquire "$lockdir"
    printf '%s\n' "$log_line" >> "$log_file" 2>/dev/null || true
    _intent_fb_lock_release "$lockdir"
  fi

  # Return the structured JSON to the caller.
  printf '%s' "$payload"
  return 0
}
