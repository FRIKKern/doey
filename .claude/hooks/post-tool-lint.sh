#!/usr/bin/env bash
# PostToolUse: lint .sh files for bash 3.2 compatibility after Write/Edit
set -euo pipefail

INPUT=$(cat)
_HAS_JQ=false; command -v jq >/dev/null 2>&1 && _HAS_JQ=true
_jq() { echo "$INPUT" | jq -r ".$1 // empty" 2>/dev/null || echo ""; }
_grep() { local k="${1##*.}"; echo "$INPUT" | grep -o "\"${k}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"${k}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//" 2>/dev/null || echo ""; }

# Only lint .sh files touched by Write/Edit
if "$_HAS_JQ"; then TOOL=$(_jq tool_name); else TOOL=$(_grep tool_name); fi
case "$TOOL" in Write|Edit) ;; *) exit 0 ;; esac
if "$_HAS_JQ"; then FILE_PATH=$(_jq tool_input.file_path); else FILE_PATH=$(_grep tool_input.file_path); fi
case "$FILE_PATH" in *.sh) ;; *) exit 0 ;; esac
[ -f "$FILE_PATH" ] || exit 0

# Skip files containing check patterns as literals
case "$(basename "$FILE_PATH")" in post-tool-lint.sh|test-bash-compat.sh) exit 0 ;; esac

# Regex matches bash 4+ features (one alternative per feature)
COMBINED_PATTERN='declare[[:space:]]+-[Anlu][[:space:]]|printf[[:space:]].*%\(.*\)T|mapfile[[:space:]]|readarray[[:space:]]|\|&|&>>|coproc[[:space:]]|BASH_REMATCH|\$\{[a-zA-Z_][a-zA-Z0-9_]*,,\}|\$\{[a-zA-Z_][a-zA-Z0-9_]*\^\^\}|\$\{![a-zA-Z_][a-zA-Z0-9_]*@\}|shopt[[:space:]]+-s[[:space:]]+(globstar|lastpipe)|read[[:space:]]+-t[[:space:]]+[0-9]+\.[0-9]'
ALL_MATCHES=$(grep -nE "$COMBINED_PATTERN" "$FILE_PATH" 2>/dev/null || true)
[ -z "$ALL_MATCHES" ] && exit 0

violations=""
count=0
while IFS= read -r match; do
  line_num="${match%%:*}"
  line_content="${match#*:}"
  desc=""
  case "$line_content" in
    *'declare '*-A*) desc="declare -A (bash 4+)" ;;
    *'declare '*-n*) desc="declare -n (bash 4.3+)" ;;
    *'declare '*-l*) desc="declare -l (bash 4+)" ;;
    *'declare '*-u*) desc="declare -u (bash 4+)" ;;
    *printf*'%('*')T'*) desc="printf %()T (bash 4.2+)" ;;
    *mapfile*) desc="mapfile (bash 4+)" ;;
    *readarray*) desc="readarray (bash 4+)" ;;
    *'|&'*) desc="|& (bash 4+)" ;;
    *'&>>'*) desc="&>> (bash 4+)" ;;
    *coproc*) desc="coproc (bash 4+)" ;;
    *BASH_REMATCH*) desc="BASH_REMATCH (bash 3.2 unreliable)" ;;
    *'${'*',,}'*) desc="\${var,,} (bash 4+)" ;;
    *'${'*'^^}'*) desc="\${var^^} (bash 4+)" ;;
    *'${!'*'@}'*) desc="\${!prefix@} (bash 4+)" ;;
    *shopt*globstar*|*shopt*lastpipe*) desc="shopt globstar/lastpipe (bash 4+)" ;;
    *read*-t*.*[0-9]*) desc="read -t decimal (bash 3.2 rounds to 0)" ;;
  esac
  if [ -n "$desc" ]; then
    violations="${violations}${FILE_PATH}:${line_num} — ${desc}
"
    count=$((count + 1))
  fi
done <<< "$ALL_MATCHES"

[ "$count" -eq 0 ] && exit 0

reason=$(printf "Bash 3.2 compatibility violations in %s (%d found):\n%s" "$FILE_PATH" "$count" "$violations")
reason_escaped=$(echo "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//')
echo "{\"decision\": \"block\", \"reason\": \"${reason_escaped}\"}"
exit 0
