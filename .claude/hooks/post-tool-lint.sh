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
      violations="${violations}${FILE_PATH}:${line_num} — ${description}\n"
      count=$((count + 1))
    done <<< "$matches"
  fi
}

check_pattern "$FILE_PATH" 'declare[[:space:]]+-A[[:space:]]' 'declare -A (associative arrays, bash 4+)'
check_pattern "$FILE_PATH" 'declare[[:space:]]+-n[[:space:]]' 'declare -n (namerefs, bash 4.3+)'
check_pattern "$FILE_PATH" 'declare[[:space:]]+-l[[:space:]]' 'declare -l (lowercase, bash 4+)'
check_pattern "$FILE_PATH" 'declare[[:space:]]+-u[[:space:]]' 'declare -u (uppercase, bash 4+)'
check_pattern "$FILE_PATH" "printf[[:space:]].*'%\(.*\)T'" 'printf time format (bash 4.2+)'
check_pattern "$FILE_PATH" 'printf[[:space:]]+-v[[:space:]].*%\(.*\)T' 'printf -v time format (bash 4.2+)'
check_pattern "$FILE_PATH" 'mapfile[[:space:]]' 'mapfile (bash 4+)'
check_pattern "$FILE_PATH" 'readarray[[:space:]]' 'readarray (bash 4+)'
check_pattern "$FILE_PATH" '\|&' 'pipe stderr shorthand |& (bash 4+)'
check_pattern "$FILE_PATH" '&>>' 'append both streams &>> (bash 4+)'
check_pattern "$FILE_PATH" 'coproc[[:space:]]' 'coproc (bash 4+)'

# If no violations, exit cleanly
if [ "$count" -eq 0 ]; then
  exit 0
fi

# Format violation details for the reason field
# Use printf to handle \n sequences
reason=$(printf "Bash 3.2 compatibility violations in %s (%d found):\n%b" "$FILE_PATH" "$count" "$violations")

# Escape for JSON: backslashes, quotes, newlines
reason_escaped=$(echo "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')

# Output block decision as JSON
echo "{\"decision\": \"block\", \"reason\": \"${reason_escaped}\"}"
exit 0
