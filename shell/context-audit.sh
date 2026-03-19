#!/usr/bin/env bash
# context-audit.sh — Detect contradictory/dangerous patterns in Doey context files.
# Exit: 0=clean, 1=issues found, 2=usage error
set -euo pipefail

MODE=""
USE_COLOR=true

for arg in "$@"; do
  case "$arg" in
    --installed) MODE="installed" ;;
    --repo)      MODE="repo" ;;
    --no-color)  USE_COLOR=false ;;
    -h|--help)   echo "Usage: context-audit.sh [--installed|--repo] [--no-color]"; exit 0 ;;
    *)           echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[[ -z "$MODE" ]] && { echo "Error: must specify --installed or --repo" >&2; exit 2; }

WARN=""; ERROR=""; DIM=""; BOLD=""; SUCCESS=""; RESET=""
if $USE_COLOR && [[ -t 1 ]]; then
  WARN='\033[0;33m'; ERROR='\033[0;31m'; DIM='\033[0;90m'
  BOLD='\033[1m'; SUCCESS='\033[0;32m'; RESET='\033[0m'
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

shopt -s nullglob
SCAN_FILES=()
if [[ "$MODE" == "installed" ]]; then
  SCAN_FILES+=(~/.claude/agents/doey-*.md ~/.claude/commands/doey-*.md)
  [[ -f "$HOME/.claude/CLAUDE.md" ]] && SCAN_FILES+=("$HOME/.claude/CLAUDE.md")
else
  SCAN_FILES+=("$REPO_DIR"/agents/*.md "$REPO_DIR"/commands/*.md)
  [[ -f "$REPO_DIR/CLAUDE.md" ]] && SCAN_FILES+=("$REPO_DIR/CLAUDE.md")
fi
shopt -u nullglob

if [[ ${#SCAN_FILES[@]} -eq 0 ]]; then
  printf "${WARN}  No files found to audit in %s mode${RESET}\n" "$MODE"
  exit 0
fi

YSPAM_RE='auto.accept|auto.unblock|handle.*y/n|handle.*prompt.*confirmation|accept.*permission.*prompt|send.*"y"|send-keys.*"y"|send.*yes.*Enter'
IDENTITY_RE='send-keys.*"[yY]"|send-keys.*"yes"|type.*yes.*into.*pane|press.*[yY].*pane'
STALE_RE='auto-accepts prompts|auto-accepting prompts|automatically accepts|auto.reserve|status-hook\.sh|on-stop\.sh'
ALLOWLIST_RE='NEVER.*send.*[yY]|never.*need.*auto.accept|no.*prompts.*to.*accept|causes.*y.spam|DO NOT.*auto.accept|do not.*send.*yes|block.*send-keys|prohibited.*send-keys|safety.*net|y-spam|y.spam.*risk|context-audit'

ISSUES=()
DELIM=$'\x1f'

add_issue() { ISSUES+=("${1}${DELIM}${2}${DELIM}${3}${DELIM}${4}${DELIM}${5}"); }

display_path() {
  if [[ "$MODE" == "installed" ]]; then
    printf '%s' "${1/#$HOME/~}"
  else
    printf '%s' "${1/#$REPO_DIR\//}"
  fi
}

scan_matches() {
  local category="$1" regex="$2" risk="$3" file="$4" display="$5"
  while IFS= read -r match_line; do
    local lnum="${match_line%%:*}"
    local content="${match_line#*:}"
    [[ "$content" =~ $ALLOWLIST_RE ]] && continue
    content="${content#"${content%%[![:space:]]*}"}"
    content="${content:0:80}"
    add_issue "$category" "$display" "$lnum" "\"${content}\"" "$risk"
  done < <(grep -niE "$regex" "$file" 2>/dev/null || true)
}

for file in "${SCAN_FILES[@]}"; do
  [[ -f "$file" ]] || continue
  display="$(display_path "$file")"
  is_watchdog=false
  [[ "$(basename "$file" .md)" == *doey-watchdog* ]] && is_watchdog=true

  if $is_watchdog; then
    yspam_risk="CRITICAL: In watchdog context — Haiku will likely act on this literally"
    scan_matches "identity-confusion" "$IDENTITY_RE" \
      "Watchdog should never send keystrokes to confirm prompts" "$file" "$display"
  else
    yspam_risk="May cause Haiku to interpret as instruction to send y/Y to panes"
  fi
  scan_matches "y-spam-risk" "$YSPAM_RE" "$yspam_risk" "$file" "$display"
  scan_matches "stale-ref" "$STALE_RE" \
    "References removed or contradictory behavior pattern" "$file" "$display"
done

if [[ ${#ISSUES[@]} -eq 0 ]]; then
  printf "${SUCCESS}  CONTEXT AUDIT: clean — no issues found${RESET}\n"
  exit 0
fi

printf "\n${ERROR}${BOLD}  CONTEXT AUDIT: %d issue(s) found${RESET}\n\n" "${#ISSUES[@]}"

for issue in "${ISSUES[@]}"; do
  IFS="$DELIM" read -r category file lnum pattern_desc risk_desc <<< "$issue"
  printf "  ${WARN}⚠  %s${RESET}: ${BOLD}%s:%s${RESET}\n" "$category" "$file" "$lnum"
  printf "     ${DIM}Pattern: %s${RESET}\n" "$pattern_desc"
  printf "     ${DIM}Risk: %s${RESET}\n" "$risk_desc"
  printf "\n"
done

exit 1
