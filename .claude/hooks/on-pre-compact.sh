#!/usr/bin/env bash
# PreCompact hook: outputs essential state to survive context compaction.
set -euo pipefail

source "$(dirname "$0")/common.sh"
init_hook
_DOEY_HOOK_NAME="on-pre-compact"
type _debug_hook_entry >/dev/null 2>&1 && _debug_hook_entry

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
CURRENT_TASK=$(grep '^TASK:' "$STATUS_FILE" 2>/dev/null | cut -d: -f2- | sed 's/^ //' || true)
RESEARCH_TOPIC=$(cat "${RUNTIME_DIR}/research/${PANE_SAFE}.task" 2>/dev/null || true)
REPORT_PATH="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)

SEARCH_DIR="${DOEY_TEAM_DIR:-$PROJECT_DIR}"

RECENT_FILES=""
if [ -n "$SEARCH_DIR" ] && [ -d "$SEARCH_DIR" ]; then
  CUTOFF_AWK='$1 >= cutoff {$1=""; print substr($0,2)}'
  STAT_FLAG="-c"; STAT_FMT='%Y %n'
  if stat -f '%m' /dev/null 2>/dev/null; then
    STAT_FLAG="-f"; STAT_FMT='%m %N'
  fi
  RECENT_FILES=$(find "$SEARCH_DIR" -maxdepth 4 \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.sh' -o -name '*.md' -o -name '*.json' -o -name '*.py' \) \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -print0 2>/dev/null | xargs -0 stat $STAT_FLAG "$STAT_FMT" 2>/dev/null | \
    awk -v cutoff="$(( $(date +%s) - 600 ))" "$CUTOFF_AWK" | head -10 || true)
fi

if is_boss; then               ROLE_LABEL="the Doey Boss"
elif is_manager; then          ROLE_LABEL="the Doey Team Lead"
elif is_taskmaster; then  ROLE_LABEL="the Doey Taskmaster"
else                           ROLE_LABEL="a Doey worker"
fi

cat <<CONTEXT
## Context Preservation (Pre-Compaction)
**Pane:** ${PANE}
**Current Task:** ${CURRENT_TASK:-No active task}
**Research Topic:** ${RESEARCH_TOPIC:-None}
**Research Report Written:** $([ -f "$REPORT_PATH" ] && echo yes || echo no)
**Recently Modified Files:**
${RECENT_FILES:-None detected}

You are ${ROLE_LABEL}. Continue from this preserved state.${RESEARCH_TOPIC:+ Research report required: ${REPORT_PATH}}
CONTEXT

_list_files() {
  local result=""
  for f in "$@"; do
    [ -f "$f" ] || continue
    result="${result}  $(basename "$f")${NL}"
  done
  printf '%s' "$result"
}

if is_manager; then
  _TEAM_W="${DOEY_TEAM_WINDOW:-$WINDOW_INDEX}"
  WORKER_ASSIGNMENTS=$(tmux list-panes -t "$SESSION_NAME:$_TEAM_W" -F '#{pane_index} #{pane_title}' 2>/dev/null || true)

  PENDING_RESULTS=""
  _HAS_JQ=false; command -v jq >/dev/null 2>&1 && _HAS_JQ=true
  for rf in "$RUNTIME_DIR"/results/pane_${_TEAM_W}_*.json; do
    [ -f "$rf" ] || continue
    if $_HAS_JQ; then
      rf_status=$(jq -r '.status // "unknown"' "$rf" 2>/dev/null || echo "unknown")
    else
      rf_status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$rf" 2>/dev/null | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"//;s/"$//' || echo "unknown")
    fi
    PENDING_RESULTS="${PENDING_RESULTS}  $(basename "$rf") (status: ${rf_status})${NL}"
  done

  COMPLETION_FILES=$(_list_files "$RUNTIME_DIR"/status/completion_pane_${_TEAM_W}_*)
  CRASH_FILES=$(_list_files "$RUNTIME_DIR"/status/crash_pane_${_TEAM_W}_*)
  cat <<TLSTATE

## TEAM LEAD ORCHESTRATION STATE (restore after compaction)
**Worker Assignments (pane_index title):**
${WORKER_ASSIGNMENTS:-No panes found}

**Pending Result Files:**
${PENDING_RESULTS:-None}

**Unprocessed Completion Files:**
${COMPLETION_FILES:-None}

**Crash Alerts:**
${CRASH_FILES:-None}

## ⚠ CORE LOOP — RESUME ACTIVE MONITORING AFTER COMPACTION
You are a Team Lead. You MUST stay active while ANY worker is BUSY.
After compaction, resume your active monitoring loop IMMEDIATELY:
1. Drain message queue — read all .msg files for completion reports
2. Check worker status files — who is BUSY, FINISHED, ERROR, or crashed?
3. Collect and validate result files for finished workers
4. Update context log with consolidated outcomes
5. If workers still BUSY → brief pause (10-15s) → go to step 1
6. If all workers FINISHED/ERROR → consolidate, report to TM, dispatch next wave
Do NOT go idle. Do NOT wait for TM instructions. You drive the loop.
TLSTATE

  # Pending messages — must be processed after compaction
  _MGR_SAFE="${SESSION_NAME//[-:.]/_}_${_TEAM_W}_0"
  PENDING_MSGS=""
  for _mf in "$RUNTIME_DIR/messages"/${_MGR_SAFE}_*.msg; do
    [ -f "$_mf" ] || continue
    PENDING_MSGS="${PENDING_MSGS}  $(basename "$_mf"): $(head -3 "$_mf" 2>/dev/null | tr '\n' ' ')${NL}"
  done
  if [ -n "$PENDING_MSGS" ]; then
    cat <<MSGSTATE

**⚠ UNREAD MESSAGES (process these after compaction!):**
${PENDING_MSGS}
Read with:
\`\`\`bash
MGR_SAFE="${_MGR_SAFE}"
for f in "\$RUNTIME_DIR/messages"/\${MGR_SAFE}_*.msg; do [ -f "\$f" ] && cat "\$f" && echo "---" && rm -f "\$f"; done
\`\`\`
MSGSTATE
  fi

  # Golden Context Log — accumulated knowledge that must survive compaction
  CONTEXT_LOG="${RUNTIME_DIR}/context_log_W${_TEAM_W}.md"
  if [ -f "$CONTEXT_LOG" ] && [ -s "$CONTEXT_LOG" ]; then
    LINES=$(wc -l < "$CONTEXT_LOG" 2>/dev/null | tr -d ' ') || LINES=0
    cat <<CTXLOG

## GOLDEN CONTEXT LOG — run \`cat ${CONTEXT_LOG}\` after compaction for full log
$(head -100 "$CONTEXT_LOG")
CTXLOG
    [ "$LINES" -gt 100 ] && echo "*[Truncated at 100/${LINES} lines]*"
  fi
fi

if is_taskmaster; then
  TM_TEAMS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)

  SM_SAFE="${SESSION_NAME//[-:.]/_}_0_${PANE_INDEX}"
  TM_PENDING_MSGS=""
  for _mf in "$RUNTIME_DIR/messages"/${SM_SAFE}_*.msg; do
    [ -f "$_mf" ] || continue
    TM_PENDING_MSGS="${TM_PENDING_MSGS}  $(basename "$_mf"): $(head -3 "$_mf" 2>/dev/null | tr '\n' ' ')${NL}"
  done

  TM_ACTIVE_TASKS=""
  for _tf in "${RUNTIME_DIR}/tasks"/*.task; do
    [ -f "$_tf" ] || continue
    grep -q "TASK_STATUS=done\|TASK_STATUS=cancelled" "$_tf" && continue
    TM_ACTIVE_TASKS="${TM_ACTIVE_TASKS}  $(basename "$_tf"): $(grep 'TASK_TITLE=' "$_tf" 2>/dev/null | cut -d= -f2-)${NL}"
  done

  cat <<TMSTATE

## TASKMASTER ORCHESTRATION STATE (restore after compaction)
**Team Windows:** ${TM_TEAMS:-None}

**Active Tasks:**
${TM_ACTIVE_TASKS:-None}

## ⚠ CORE LOOP — RESUME IMMEDIATELY AFTER COMPACTION
You are the Taskmaster. Your job is an autonomous, permanent ACTIVE loop.
Do NOT wait for instructions. Do NOT depend on the wait hook to tell you what to do.
YOU drive the loop — the wait hook is just a brief pause.

1. **Drain inbox** — read ALL .msg files addressed to you in \$RUNTIME_DIR/messages/
2. **Check pane status** — read \$RUNTIME_DIR/status/*.status for FINISHED, ERROR, crashes
3. **Check results** — read \$RUNTIME_DIR/results/ for new result files
4. **Act** — route tasks, process completions, escalate errors, handle git
5. **Brief pause** — call taskmaster-wait.sh (3s max), then go to step 1

You are the ONLY role that commits/pushes — do it directly, no delegation needed.
Do NOT wait for instructions. Do NOT escalate to Boss for approval. Resume this loop NOW.
TMSTATE

  if [ -n "$TM_PENDING_MSGS" ]; then
    cat <<TMMSG

**⚠ UNREAD MESSAGES (process these after compaction!):**
${TM_PENDING_MSGS}
Read with:
\`\`\`bash
SM_SAFE="${SM_SAFE}"
for f in "\$RUNTIME_DIR/messages"/\${SM_SAFE}_*.msg; do [ -f "\$f" ] && cat "\$f" && echo "---" && rm -f "\$f"; done
\`\`\`
TMMSG
  fi
fi

if is_boss; then
  BOSS_SAFE="${SESSION_NAME//[-:.]/_}_0_1"
  BOSS_PENDING_MSGS=""
  for _mf in "$RUNTIME_DIR/messages"/${BOSS_SAFE}_*.msg; do
    [ -f "$_mf" ] || continue
    BOSS_PENDING_MSGS="${BOSS_PENDING_MSGS}  $(basename "$_mf"): $(head -3 "$_mf" 2>/dev/null | tr '\n' ' ')${NL}"
  done
  cat <<BOSSSTATE

## BOSS STATE (restore after compaction)
**You are Boss** — user-facing commander at pane 0.1
**TM is at:** pane 0.2
BOSSSTATE
  if [ -n "$BOSS_PENDING_MSGS" ]; then
    cat <<BOSSMSG

**UNREAD MESSAGES (process these after compaction!):**
${BOSS_PENDING_MSGS}
BOSSMSG
  fi
fi

exit 0
