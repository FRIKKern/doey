#!/usr/bin/env bash
# PostToolUse hook: lint .sh files for bash 3.2 compatibility after Write/Edit
# This script itself is bash 3.2 compatible.
set -euo pipefail

# Read JSON from stdin
INPUT=$(cat)

# Extract tool_name
if command -v jq >/dev/null 2>&1; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
else
  TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null) || TOOL_NAME=""
fi

# Early exit if not Write or Edit
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

# Extract file_path from tool_input
if command -v jq >/dev/null 2>&1; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || FILE_PATH=""
else
  FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null) || FILE_PATH=""
fi

# Early exit if not a .sh file
case "$FILE_PATH" in
  *.sh) ;;
  *) exit 0 ;;
esac

# Early exit if file doesn't exist (deleted or moved)
[ -f "$FILE_PATH" ] || exit 0

# Skip linting this script itself (patterns would false-positive)
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
[ "$FILE_PATH" = "$SELF" ] && exit 0

# Also skip the test script itself
case "$FILE_PATH" in
  */tests/test-bash-compat.sh) exit 0 ;;
esac

# --- Bash 3.2 compatibility checks on the single file ---
# Portable newline for string building (bash 3.2 safe)
NL='
'
violations=""
count=0

check_pattern() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  local matches
  matches=$(grep -nE "$pattern" "$file" 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while IFS= read -r match; do
      local line_num="${match%%:*}"
      violations="${violations}${FILE_PATH}:${line_num} — ${description}${NL}"
      count=$((count + 1))
    done <<< "$matches"
  fi
}

# All patterns in one grep pass to avoid 17 separate forks
COMBINED_PATTERN='declare[[:space:]]+-[Anlu][[:space:]]|printf[[:space:]].*%\(.*\)T|mapfile[[:space:]]|readarray[[:space:]]|\|&|&>>|coproc[[:space:]]|read[[:space:]]+-[^ ]*a[[:space:]]|BASH_REMATCH|\$\{[a-zA-Z_][a-zA-Z0-9_]*,,\}|\$\{[a-zA-Z_][a-zA-Z0-9_]*\^\^\}|\$\{![a-zA-Z_][a-zA-Z0-9_]*@\}|shopt[[:space:]]+-s[[:space:]]+(globstar|lastpipe)'
ALL_MATCHES=$(grep -nE "$COMBINED_PATTERN" "$FILE_PATH" 2>/dev/null || true)

if [ -n "$ALL_MATCHES" ]; then
  # Classify each match line against individual patterns
  while IFS= read -r match; do
    line_num="${match%%:*}"
    line_content="${match#*:}"
    desc=""
    case "$line_content" in
      *'declare '*-A*) desc="declare -A (associative arrays, bash 4+)" ;;
      *'declare '*-n*) desc="declare -n (namerefs, bash 4.3+)" ;;
      *'declare '*-l*) desc="declare -l (lowercase, bash 4+)" ;;
      *'declare '*-u*) desc="declare -u (uppercase, bash 4+)" ;;
      *printf*'%('*')T'*) desc="printf time format (bash 4.2+)" ;;
      *mapfile*) desc="mapfile (bash 4+)" ;;
      *readarray*) desc="readarray (bash 4+)" ;;
      *'|&'*) desc="pipe stderr shorthand |& (bash 4+)" ;;
      *'&>>'*) desc="append both streams &>> (bash 4+)" ;;
      *coproc*) desc="coproc (bash 4+)" ;;
      *'read '*-*a*) desc="read -a (array read, use while-read loop instead)" ;;
      *BASH_REMATCH*) desc="BASH_REMATCH (regex capture groups, bash 3.2 unreliable)" ;;
      *'${'*',,}'*) desc="\${var,,} (lowercase, bash 4+)" ;;
      *'${'*'^^}'*) desc="\${var^^} (uppercase, bash 4+)" ;;
      *'${!'*'@}'*) desc="\${!prefix@} (indirect expansion, bash 4+)" ;;
      *shopt*globstar*|*shopt*lastpipe*) desc="shopt globstar/lastpipe (bash 4+)" ;;
    esac
    if [ -n "$desc" ]; then
      violations="${violations}${FILE_PATH}:${line_num} — ${desc}${NL}"
      count=$((count + 1))
    fi
  done <<< "$ALL_MATCHES"
fi

# If no violations, exit cleanly
if [ "$count" -eq 0 ]; then
  exit 0
fi

# Format violation details for the reason field
reason=$(printf "Bash 3.2 compatibility violations in %s (%d found):\n%s" "$FILE_PATH" "$count" "$violations")

# Escape for JSON: backslashes, quotes, newlines
reason_escaped=$(echo "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//')

# Output block decision as JSON
echo "{\"decision\": \"block\", \"reason\": \"${reason_escaped}\"}"
exit 0
