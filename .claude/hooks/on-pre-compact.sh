#!/usr/bin/env bash
# PreCompact hook: outputs essential worker state to survive context compaction.
# stdout from this hook is included in the compacted context.

set -euo pipefail

HOOK_DIR="$(dirname "$0")"
if [ -f "$HOOK_DIR/common.sh" ]; then
  source "$HOOK_DIR/common.sh"
  init_hook
else
  INPUT=$(cat)
  [ -z "${TMUX_PANE:-}" ] && exit 0
  tmux display-message -t "${TMUX_PANE}" -p '' >/dev/null 2>&1 || exit 0
  RUNTIME_DIR=$(tmux show-environment CLAUDE_TEAM_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
  [ -z "$RUNTIME_DIR" ] && exit 0
  PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
  PANE_SAFE=${PANE//[:.]/_}
fi

# Read current task from status file
STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
CURRENT_TASK=""
if [ -f "$STATUS_FILE" ]; then
  CURRENT_TASK=$(grep '^TASK:' "$STATUS_FILE" | cut -d: -f2- | sed 's/^ //')
fi

# Check for research task
TASK_FILE="${RUNTIME_DIR}/research/${PANE_SAFE}.task"
RESEARCH_TOPIC=""
if [ -f "$TASK_FILE" ]; then
  RESEARCH_TOPIC=$(cat "$TASK_FILE" 2>/dev/null)
fi

# Check if research report has been written
REPORT_PATH="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
REPORT_EXISTS="no"
if [ -f "$REPORT_PATH" ]; then
  REPORT_EXISTS="yes"
fi

# Get project directory
PROJECT_DIR=""
if [ -f "${RUNTIME_DIR}/session.env" ]; then
  PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" | cut -d= -f2-)
fi

# Find recently modified project files (last 10 minutes)
RECENT_FILES=""
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  if stat -f '%m' /dev/null 2>/dev/null; then
    # macOS: use stat -f to get modification times, sort by recency
    RECENT_FILES=$(find "$PROJECT_DIR" -maxdepth 4 \
      \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.sh' -o -name '*.md' -o -name '*.json' -o -name '*.py' \) \
      -not -path '*/node_modules/*' -not -path '*/.git/*' \
      2>/dev/null | xargs stat -f '%m %N' 2>/dev/null | \
      awk -v cutoff="$(( $(date +%s) - 600 ))" '$1 >= cutoff {print $2}' | head -10 || true)
  else
    # Linux: use -mmin
    RECENT_FILES=$(find "$PROJECT_DIR" -maxdepth 4 \
      \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.sh' -o -name '*.md' -o -name '*.json' -o -name '*.py' \) \
      -not -path '*/node_modules/*' -not -path '*/.git/*' \
      -mmin -10 2>/dev/null | head -10 || true)
  fi
fi

# Output context preservation message to stdout
cat <<CONTEXT
## Context Preservation (Pre-Compaction)
**Pane:** ${PANE}
**Current Task:** ${CURRENT_TASK:-No active task}
**Research Topic:** ${RESEARCH_TOPIC:-None}
**Research Report Written:** ${REPORT_EXISTS}
**Recently Modified Files:**
${RECENT_FILES:-None detected}

**Important:** You are a Claude Team worker. Your task context above was preserved before context compaction. Continue your work based on this information. If you have a research task, you MUST write your report to ${REPORT_PATH} before stopping.
CONTEXT

exit 0
