#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# context-audit.sh — Detect contradictory or dangerous patterns in
# Doey's installed context files (agents, commands, CLAUDE.md).
#
# WHY THIS EXISTS:
# The watchdog agent description once said "auto-accepting prompts"
# while the agent body said "NEVER send y/Y/yes". Haiku followed
# the description and spammed "y" into worker panes. This script
# catches contradictory context patterns before they cause damage.
#
# Usage:
#   context-audit.sh --installed   # Check ~/.claude/ (installed files)
#   context-audit.sh --repo        # Check repo dir (source files)
#   context-audit.sh --no-color    # Disable colorized output
#
# Exit codes:
#   0 — No issues found
#   1 — Issues found (structured report printed)
#   2 — Usage error
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Color palette ─────────────────────────────────────────────────────
WARN='\033[0;33m'         # Yellow
ERROR='\033[0;31m'        # Red
DIM='\033[0;90m'          # Gray
BOLD='\033[1m'            # Bold
SUCCESS='\033[0;32m'      # Green
RESET='\033[0m'           # Reset

# ── Argument parsing ─────────────────────────────────────────────────
MODE=""
NO_COLOR=false

for arg in "$@"; do
  case "$arg" in
    --installed) MODE="installed" ;;
    --repo)      MODE="repo" ;;
    --no-color)  NO_COLOR=true ;;
    -h|--help)
      echo "Usage: context-audit.sh [--installed|--repo] [--no-color]"
      echo "  --installed  Check installed files in ~/.claude/"
      echo "  --repo       Check source files in the repo directory"
      echo "  --no-color   Disable colorized output"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: context-audit.sh [--installed|--repo] [--no-color]" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Error: must specify --installed or --repo" >&2
  exit 2
fi

# Disable colors if requested or if not a terminal
if $NO_COLOR || [[ ! -t 1 ]]; then
  WARN=""
  ERROR=""
  DIM=""
  BOLD=""
  SUCCESS=""
  RESET=""
fi

# ── Resolve file paths ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

declare -a SCAN_FILES=()

if [[ "$MODE" == "installed" ]]; then
  # Installed files
  shopt -s nullglob
  SCAN_FILES+=(~/.claude/agents/doey-*.md)
  SCAN_FILES+=(~/.claude/commands/doey-*.md)
  shopt -u nullglob
  # Check for CLAUDE.md in common locations
  if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
    SCAN_FILES+=("$HOME/.claude/CLAUDE.md")
  fi
else
  # Repo files
  shopt -s nullglob
  SCAN_FILES+=("$REPO_DIR"/agents/*.md)
  SCAN_FILES+=("$REPO_DIR"/commands/*.md)
  shopt -u nullglob
  if [[ -f "$REPO_DIR/CLAUDE.md" ]]; then
    SCAN_FILES+=("$REPO_DIR/CLAUDE.md")
  fi
fi

if [[ ${#SCAN_FILES[@]} -eq 0 ]]; then
  printf "${WARN}  No files found to audit in %s mode${RESET}\n" "$MODE"
  exit 0
fi

# ── Pattern definitions (combined into single regexes for speed) ───

# y-spam patterns (CRITICAL — these directly cause y-spam)
YSPAM_RE='auto.accept|auto.unblock|handle.*y/n|handle.*prompt.*confirmation|accept.*permission.*prompt|send.*"y"|send-keys.*"y"|send.*yes.*Enter'

# Identity confusion patterns (send-keys misuse in watchdog context)
IDENTITY_RE='send-keys.*"[yY]"|send-keys.*"yes"|type.*yes.*into.*pane|press.*[yY].*pane'

# Stale reference patterns (references to removed features/old behavior)
STALE_RE='auto-accepts prompts|auto-accepting prompts|automatically accepts|auto.reserve|status-hook\.sh'

# Allowlist — single combined regex for fast checking
ALLOWLIST_RE='NEVER.*send.*[yY]|never.*need.*auto.accept|no.*prompts.*to.*accept|causes.*y.spam|DO NOT.*auto.accept|do not.*send.*yes|block.*send-keys|prohibited.*send-keys|safety.*net|y-spam|y.spam.*risk|context-audit'

# Files where y-spam patterns are ESPECIALLY dangerous
YSPAM_CRITICAL_GLOB="doey-watchdog"

# ── Issue tracking ──────────────────────────────────────────────────
declare -a ISSUES=()
ISSUE_COUNT=0

DELIM=$'\x1f'  # Unit separator — safe delimiter for structured fields
add_issue() {
  ISSUE_COUNT=$((ISSUE_COUNT + 1))
  ISSUES+=("${1}${DELIM}${2}${DELIM}${3}${DELIM}${4}${DELIM}${5}")
}

# Get display-friendly file path
display_path() {
  if [[ "$MODE" == "installed" ]]; then
    printf '%s' "${1/#$HOME/~}"
  else
    printf '%s' "${1/#$REPO_DIR\//}"
  fi
}

# Scan a file with one combined grep call per category
# Usage: scan_category <category> <regex> <risk_msg> <file> <display> [filter_fn]
scan_matches() {
  local category="$1" regex="$2" risk="$3" file="$4" display="$5"

  while IFS= read -r match_line; do
    local lnum="${match_line%%:*}"
    local content="${match_line#*:}"

    # Skip if allowlisted (single regex, no subshell)
    if [[ "$content" =~ $ALLOWLIST_RE ]]; then
      continue
    fi

    # Trim leading whitespace and truncate
    content="${content#"${content%%[![:space:]]*}"}"
    content="${content:0:80}"

    add_issue "$category" "$display" "$lnum" "\"${content}\"" "$risk"
  done < <(grep -niE "$regex" "$file" 2>/dev/null || true)
}

# ── Run scans ───────────────────────────────────────────────────────
for file in "${SCAN_FILES[@]}"; do
  [[ -f "$file" ]] || continue

  display="$(display_path "$file")"
  bname="$(basename "$file" .md)"

  # y-spam scan — escalate risk for watchdog files
  if [[ "$bname" == *"$YSPAM_CRITICAL_GLOB"* ]]; then
    scan_matches "y-spam-risk" "$YSPAM_RE" \
      "CRITICAL: In watchdog context — Haiku will likely act on this literally" \
      "$file" "$display"
  else
    scan_matches "y-spam-risk" "$YSPAM_RE" \
      "May cause Haiku to interpret as instruction to send y/Y to panes" \
      "$file" "$display"
  fi

  # Identity confusion — only watchdog files
  if [[ "$bname" == *"$YSPAM_CRITICAL_GLOB"* ]]; then
    scan_matches "identity-confusion" "$IDENTITY_RE" \
      "Watchdog should never send keystrokes to confirm prompts" \
      "$file" "$display"
  fi

  # Stale references — all files
  scan_matches "stale-ref" "$STALE_RE" \
    "References removed or contradictory behavior pattern" \
    "$file" "$display"
done

# ── Output results ──────────────────────────────────────────────────
if [[ $ISSUE_COUNT -eq 0 ]]; then
  printf "${SUCCESS}  CONTEXT AUDIT: clean — no issues found${RESET}\n"
  exit 0
fi

printf "\n${ERROR}${BOLD}  CONTEXT AUDIT: %d issue(s) found${RESET}\n\n" "$ISSUE_COUNT"

for issue in "${ISSUES[@]}"; do
  IFS="$DELIM" read -r category file lnum pattern_desc risk_desc <<< "$issue"
  printf "  ${WARN}⚠  %s${RESET}: ${BOLD}%s:%s${RESET}\n" "$category" "$file" "$lnum"
  printf "     ${DIM}Pattern: %s${RESET}\n" "$pattern_desc"
  printf "     ${DIM}Risk: %s${RESET}\n" "$risk_desc"
  printf "\n"
done

exit 1
