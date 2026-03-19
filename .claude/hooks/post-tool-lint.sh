#!/usr/bin/env bash
# PostToolUse: lint .sh files for bash 3.2 compatibility after Write/Edit
set -euo pipefail

INPUT=$(cat)

_HAS_JQ=false; command -v jq >/dev/null 2>&1 && _HAS_JQ=true

_parse() {
  if "$_HAS_JQ"; then
    echo "$INPUT" | jq -r ".$1 // empty" 2>/dev/null || echo ""
  else
    echo "$INPUT" | grep -o "\"${1##*.}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"${1##*.}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//" 2>/dev/null || echo ""
  fi
}

# Only lint .sh files touched by Write/Edit
case "$(_parse tool_name)" in Write|Edit) ;; *) exit 0 ;; esac
FILE_PATH=$(_parse tool_input.file_path)
case "$FILE_PATH" in *.sh) ;; *) exit 0 ;; esac
[ -f "$FILE_PATH" ] || exit 0

# Skip files containing check patterns as literals
case "$(basename "$FILE_PATH")" in post-tool-lint.sh|test-bash-compat.sh) exit 0 ;; esac

NL='
'
# Regex matches bash 4+ features (one alternative per feature):
#   declare -[Anlu]       associative arrays, namerefs, lower/uppercase attrs
#   printf %()T           time format
#   mapfile / readarray   array builtins
#   |& / &>>              pipe/append stderr shorthands
#   coproc                coprocess
#   BASH_REMATCH          regex capture groups (unreliable in 3.2)
#   ${var,,} / ${var^^}   case conversion
#   ${!prefix@}           indirect expansion
#   shopt globstar/lastpipe
#   read -t <decimal>     fractional timeout (rounds to 0 in 3.2)
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
    *BASH_REMATCH*) desc="BASH_REMATCH (regex capture groups, bash 3.2 unreliable)" ;;
    *'${'*',,}'*) desc="\${var,,} (lowercase, bash 4+)" ;;
    *'${'*'^^}'*) desc="\${var^^} (uppercase, bash 4+)" ;;
    *'${!'*'@}'*) desc="\${!prefix@} (indirect expansion, bash 4+)" ;;
    *shopt*globstar*|*shopt*lastpipe*) desc="shopt globstar/lastpipe (bash 4+)" ;;
    *read*-t*.*[0-9]*) desc="read -t with decimal timeout (bash 3.2 rounds to 0)" ;;
  esac
  if [ -n "$desc" ]; then
    violations="${violations}${FILE_PATH}:${line_num} — ${desc}${NL}"
    count=$((count + 1))
  fi
done <<< "$ALL_MATCHES"

[ "$count" -eq 0 ] && exit 0

reason=$(printf "Bash 3.2 compatibility violations in %s (%d found):\n%s" "$FILE_PATH" "$count" "$violations")
reason_escaped=$(echo "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//')
echo "{\"decision\": \"block\", \"reason\": \"${reason_escaped}\"}"
exit 0
