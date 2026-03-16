#!/usr/bin/env bash
# PreCompact hook: outputs essential worker state to survive context compaction.
# stdout from this hook is included in the compacted context.

set -euo pipefail

source "$(dirname "$0")/common.sh"
init_hook

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
  PROJECT_DIR="${PROJECT_DIR%\"}"
  PROJECT_DIR="${PROJECT_DIR#\"}"
fi

# Find recently modified project files (last 10 minutes) — skip for Watchdog (irrelevant)
RECENT_FILES=""
if ! is_watchdog; then
  if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
    if stat -f '%m' /dev/null 2>/dev/null; then
      # macOS: use stat -f to get modification times, sort by recency
      RECENT_FILES=$(find "$PROJECT_DIR" -maxdepth 4 \
        \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.sh' -o -name '*.md' -o -name '*.json' -o -name '*.py' \) \
        -not -path '*/node_modules/*' -not -path '*/.git/*' \
        -print0 2>/dev/null | xargs -0 stat -f '%m %N' 2>/dev/null | \
        awk -v cutoff="$(( $(date +%s) - 600 ))" '$1 >= cutoff {$1=""; print substr($0,2)}' | head -10 || true)
    else
      # Linux: use stat -c to get modification times, sort by recency
      RECENT_FILES=$(find "$PROJECT_DIR" -maxdepth 4 \
        \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.sh' -o -name '*.md' -o -name '*.json' -o -name '*.py' \) \
        -not -path '*/node_modules/*' -not -path '*/.git/*' \
        -print0 2>/dev/null | xargs -0 stat -c '%Y %n' 2>/dev/null | \
        awk -v cutoff="$(( $(date +%s) - 600 ))" '$1 >= cutoff {$1=""; print substr($0,2)}' | head -10 || true)
    fi
  fi
fi

# Determine role label for context message
if is_manager; then
  ROLE_LABEL="the Doey Manager"
elif is_watchdog; then
  ROLE_LABEL="the Doey Watchdog"
else
  ROLE_LABEL="a Doey worker"
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

**Important:** You are ${ROLE_LABEL}. Your task context above was preserved before context compaction. Continue your work based on this information. If you have a research task, you MUST write your report to ${REPORT_PATH} before stopping.
CONTEXT

# Append Manager orchestration state if this is the Manager
if is_manager; then
  WORKER_ASSIGNMENTS=$(tmux list-panes -s -t "$SESSION_NAME" -F '#{pane_index} #{pane_title}' 2>/dev/null || true)
  PENDING_RESULTS=""
  HAS_JQ=false
  command -v jq >/dev/null 2>&1 && HAS_JQ=true
  for rf in "$RUNTIME_DIR"/results/pane_*.json; do
    [ -f "$rf" ] || continue
    rf_name=$(basename "$rf")
    rf_status=""
    if $HAS_JQ; then
      rf_status=$(jq -r '.status // "unknown"' "$rf" 2>/dev/null || echo "unknown")
    else
      rf_status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$rf" 2>/dev/null | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"//;s/"$//' || echo "unknown")
    fi
    PENDING_RESULTS="${PENDING_RESULTS}  ${rf_name} (status: ${rf_status})
"
  done
  COMPLETION_FILES=""
  for cf in "$RUNTIME_DIR"/status/completion_pane_*; do
    [ -f "$cf" ] || continue
    COMPLETION_FILES="${COMPLETION_FILES}  $(basename "$cf")
"
  done
  CRASH_FILES=""
  for crf in "$RUNTIME_DIR"/status/crash_pane_*; do
    [ -f "$crf" ] || continue
    CRASH_FILES="${CRASH_FILES}  $(basename "$crf")
"
  done
  cat <<MGRSTATE

## MANAGER ORCHESTRATION STATE (restore after compaction)
You are the Manager. The following orchestration state was captured before compaction.

**Worker Assignments (pane_index title):**
${WORKER_ASSIGNMENTS:-No panes found}

**Pending Result Files:**
${PENDING_RESULTS:-None}

**Unprocessed Completion Files:**
${COMPLETION_FILES:-None}

**Crash Alerts:**
${CRASH_FILES:-None}
MGRSTATE
fi

# Append watchdog pane states if this is the watchdog
if is_watchdog; then
  WATCHDOG_STATE=$(cat "${RUNTIME_DIR}/status/watchdog_pane_states.json" 2>/dev/null || echo "{}")
  if [ "$WATCHDOG_STATE" != "{}" ]; then
    cat <<WDSTATE

## WATCHDOG STATE (restore after compaction)
You are the Watchdog. The following pane states were being tracked before compaction. Restore this into your monitoring state:
\`\`\`json
${WATCHDOG_STATE}
\`\`\`
WDSTATE
  fi
fi

exit 0
