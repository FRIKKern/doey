#!/usr/bin/env bash
set -euo pipefail

# Lint script: detect bash 4+ features that break on macOS /bin/bash 3.2
# This script itself is bash 3.2 compatible.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
violations=0
files_scanned=0

check_pattern() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  local matches
  matches=$(grep -nE "$pattern" "$file" 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while IFS= read -r match; do
      line_num="${match%%:*}"
      line_content="${match#*:}"
      echo "VIOLATION: $file:$line_num — $description"
      echo "  $line_content"
      violations=$((violations + 1))
    done <<< "$matches"
  fi
}

while IFS= read -r file; do
  # Skip self — patterns in this file would false-positive
  if [ "$file" = "$SELF" ]; then
    continue
  fi
  files_scanned=$((files_scanned + 1))

  check_pattern "$file" 'declare[[:space:]]+-A[[:space:]]' 'declare -A (associative arrays, bash 4+)'
  check_pattern "$file" 'declare[[:space:]]+-n[[:space:]]' 'declare -n (namerefs, bash 4.3+)'
  check_pattern "$file" 'declare[[:space:]]+-l[[:space:]]' 'declare -l (lowercase, bash 4+)'
  check_pattern "$file" 'declare[[:space:]]+-u[[:space:]]' 'declare -u (uppercase, bash 4+)'
  check_pattern "$file" "printf[[:space:]].*'%\(.*\)T'" 'printf time format (bash 4.2+)'
  check_pattern "$file" 'printf[[:space:]]+-v[[:space:]].*%\(.*\)T' 'printf -v time format (bash 4.2+)'
  check_pattern "$file" 'mapfile[[:space:]]' 'mapfile (bash 4+)'
  check_pattern "$file" 'readarray[[:space:]]' 'readarray (bash 4+)'
  check_pattern "$file" '\|&' 'pipe stderr shorthand |& (bash 4+)'
  check_pattern "$file" '&>>' 'append both streams &>> (bash 4+)'
  check_pattern "$file" 'coproc[[:space:]]' 'coproc (bash 4+)'

done < <(find "$PROJECT_ROOT" -name '*.sh' \
  -not -path '*/node_modules/*' \
  -not -path '*/.git/*' \
  -type f)

echo ""
echo "=== Bash 3.2 Compatibility Check ==="
echo "Files scanned: $files_scanned"
echo "Violations found: $violations"

if [ "$violations" -gt 0 ]; then
  echo "FAIL: Fix the above violations for macOS /bin/bash 3.2 compatibility."
  exit 1
else
  echo "PASS: All shell scripts are bash 3.2 compatible."
  exit 0
fi
