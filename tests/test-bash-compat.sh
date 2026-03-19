#!/usr/bin/env bash
set -euo pipefail

# Detect bash 4+ features that break on macOS /bin/bash 3.2

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
violations=0
files_scanned=0

check_pattern() {
  local file="$1" pattern="$2" description="$3"
  local matches
  matches=$(grep -nE "$pattern" "$file" 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while IFS= read -r match; do
      echo "VIOLATION: $file:${match%%:*} — $description"
      echo "  ${match#*:}"
      violations=$((violations + 1))
    done <<< "$matches"
  fi
}

while IFS= read -r file; do
  # Skip self and post-tool-lint.sh — both contain check patterns as string literals
  case "$file" in
    "$SELF"|*/post-tool-lint.sh) continue ;;
  esac
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
  check_pattern "$file" 'read[[:space:]]+-[^ ]*a[[:space:]]' 'read -a (array read, bash 4+ — use while-read loop instead)'
  check_pattern "$file" 'BASH_REMATCH' 'BASH_REMATCH capture groups (bash 3.2 unreliable)'

done < <(find "$PROJECT_ROOT" -name '*.sh' \
  -not -path '*/node_modules/*' \
  -not -path '*/.git/*' \
  -type f)

echo ""
echo "=== Bash 3.2 Compat: $files_scanned files, $violations violations ==="
if [ "$violations" -gt 0 ]; then
  echo "FAIL: Fix violations for macOS /bin/bash 3.2 compatibility."
  exit 1
fi
echo "PASS"
