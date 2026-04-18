#!/usr/bin/env bash
# intent-clarify-state.sh — read/write pending clarify state for doey intent fallback.
# Part of the doey intent-fallback pipeline. See docs/intent-fallback.md.
#
# State file: ${DOEY_RUNTIME}/${DOEY_PROJECT_ACRONYM:-_global}/intent-clarify.json
# Shape:     {"typed":"...","question":"...","ts":<epoch>}
#
# Bash 3.2 compatible. All functions are best-effort: never fatal, never abort
# the caller. Silent on I/O failures.
#
# NOTE: intentionally `set -uo pipefail` without `-e` — this file is sourced
# from `doey-intent-dispatch.sh`, and `-e` would propagate to the caller and
# crash the shell on any non-zero helper return. Helpers return 1 routinely
# (stale state, missing file) without meaning failure.
set -uo pipefail

# Source guard — allow repeated sourcing without re-execution
[ "${__doey_intent_clarify_sourced:-}" = "1" ] && return 0 2>/dev/null || true
__doey_intent_clarify_sourced=1

# Path to the clarify state file. Creates parent dir silently if needed.
_clarify_state_path() {
  local runtime="${DOEY_RUNTIME:-/tmp/doey}"
  local scope="${DOEY_PROJECT_ACRONYM:-_global}"
  local dir="${runtime}/${scope}"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "${dir}/intent-clarify.json"
}

# Escape a string for embedding inside a JSON double-quoted value.
# Handles backslash, quote, newline, tab, carriage return.
_clarify_json_escape() {
  # awk handles backslash and quote first, then control chars. Input comes
  # via stdin so embedded newlines are preserved as \n sequences in output.
  printf '%s' "$1" | awk '
    BEGIN { ORS=""; first=1 }
    {
      s = $0
      gsub(/\\/, "\\\\", s)
      gsub(/"/,  "\\\"", s)
      gsub(/\t/, "\\t",  s)
      gsub(/\r/, "\\r",  s)
      if (!first) printf "\\n"
      printf "%s", s
      first = 0
    }
  '
}

# Write a clarify state entry atomically. Tolerates missing runtime.
# Usage: _clarify_write "<typed>" "<question>"
_clarify_write() {
  local typed="$1" question="$2"
  local path tmp ts
  path="$(_clarify_state_path)"
  tmp="${path}.tmp.$$"
  ts=$(date +%s 2>/dev/null || echo 0)
  local e_typed e_q
  e_typed="$(_clarify_json_escape "$typed")"
  e_q="$(_clarify_json_escape "$question")"
  {
    printf '{"typed":"%s","question":"%s","ts":%s}\n' \
      "$e_typed" "$e_q" "$ts"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  return 0
}

# Read the clarify state if it exists AND is younger than
# ${DOEY_INTENT_CLARIFY_TTL:-300} seconds. Emits the raw JSON on stdout, or
# returns 1 if stale/missing. Deletes garbage content on the way.
_clarify_read() {
  local path ttl now mtime age content
  path="$(_clarify_state_path)"
  [ -f "$path" ] || return 1
  ttl="${DOEY_INTENT_CLARIFY_TTL:-300}"
  now=$(date +%s 2>/dev/null || echo 0)
  # GNU stat (Linux) vs BSD stat (macOS) have incompatible flags. Try -c %Y
  # (GNU) first; fall back to -f %m (BSD). Default to 0 on any failure so the
  # arithmetic below can't trigger `set -u` on a garbage value.
  mtime=$(stat -c %Y "$path" 2>/dev/null || true)
  if [ -z "$mtime" ] || [ -n "${mtime//[0-9]/}" ]; then
    mtime=$(stat -f %m "$path" 2>/dev/null || true)
  fi
  case "$mtime" in
    ''|*[!0-9]*) mtime=0 ;;
  esac
  age=$((now - mtime))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$ttl" ]; then
    rm -f "$path" 2>/dev/null || true
    return 1
  fi
  content=$(cat "$path" 2>/dev/null || true)
  case "$content" in
    *'"typed"'*'"question"'*) : ;;
    *) rm -f "$path" 2>/dev/null || true; return 1 ;;
  esac
  printf '%s' "$content"
  return 0
}

# Delete the clarify state file (best-effort).
_clarify_clear() {
  local path
  path="$(_clarify_state_path)"
  rm -f "$path" 2>/dev/null || true
  return 0
}

# Extract one top-level string field from JSON. Uses jq if available, else a
# minimal bash fallback that handles simple escapes (quotes, backslashes).
# Usage: _clarify_parse_field "$json" "typed"
_clarify_parse_field() {
  local json="$1" field="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r ".${field} // empty" 2>/dev/null
    return 0
  fi
  # Fallback: sed-based extraction. Not perfect but safe for our shape.
  printf '%s' "$json" \
    | sed -n "s/.*\"${field}\":\"\\(\\([^\"\\\\]\\|\\\\.\\)*\\)\".*/\\1/p" \
    | head -1 \
    | sed 's/\\"/"/g; s/\\\\/\\/g; s/\\n/\n/g; s/\\t/\t/g'
}
