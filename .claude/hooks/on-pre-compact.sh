#!/usr/bin/env bash
# PreCompact hook: outputs essential state to survive context compaction.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "on-pre-compact"

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

ROLE_LABEL="a Doey worker"
is_boss && ROLE_LABEL="the Doey Boss"
is_manager && ROLE_LABEL="the Doey Window Manager"
is_session_manager && ROLE_LABEL="the Doey Session Manager"

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

_gather_msgs() {
  local prefix="$1" result=""
  for _mf in "$RUNTIME_DIR/messages"/${prefix}_*.msg; do
    [ -f "$_mf" ] || continue
    result="${result}  $(basename "$_mf"): $(head -3 "$_mf" 2>/dev/null | tr '\n' ' ')${NL}"
  done
  printf '%s' "$result"
}

_print_pending_msgs() {
  local safe="$1" msgs="$2"
  [ -z "$msgs" ] && return
  cat <<PMSG

**⚠ UNREAD MESSAGES (process these after compaction!):**
${msgs}
Read with:
\`\`\`bash
SAFE="${safe}"
for f in "\$RUNTIME_DIR/messages"/\${SAFE}_*.msg; do [ -f "\$f" ] && cat "\$f" && echo "---" && rm -f "\$f"; done
\`\`\`
PMSG
}

if is_manager; then
  _TEAM_W="${DOEY_TEAM_WINDOW:-$WINDOW_INDEX}"
  WORKER_ASSIGNMENTS=$(tmux list-panes -t "$SESSION_NAME:$_TEAM_W" -F '#{pane_index} #{pane_title}' 2>/dev/null || true)

  PENDING_RESULTS=""
  for rf in "$RUNTIME_DIR"/results/pane_${_TEAM_W}_*.json; do
    [ -f "$rf" ] || continue
    rf_status=$(jq -r '.status // "unknown"' "$rf" 2>/dev/null) \
      || rf_status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$rf" 2>/dev/null | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"//;s/"$//' || echo "unknown")
    PENDING_RESULTS="${PENDING_RESULTS}  $(basename "$rf") (status: ${rf_status})${NL}"
  done

  COMPLETION_FILES=$(_list_files "$RUNTIME_DIR"/status/completion_pane_${_TEAM_W}_*)
  CRASH_FILES=$(_list_files "$RUNTIME_DIR"/status/crash_pane_${_TEAM_W}_*)
  cat <<MGRSTATE

## WINDOW MANAGER ORCHESTRATION STATE (restore after compaction)
**Worker Assignments (pane_index title):**
${WORKER_ASSIGNMENTS:-No panes found}

**Pending Result Files:**
${PENDING_RESULTS:-None}

**Unprocessed Completion Files:**
${COMPLETION_FILES:-None}

**Crash Alerts:**
${CRASH_FILES:-None}

## ⚠ CORE LOOP — RESUME ACTIVE MONITORING AFTER COMPACTION
You are a Window Manager. You MUST stay active while ANY worker is BUSY.
After compaction, resume your active monitoring loop IMMEDIATELY:
1. Drain message queue — read all .msg files for completion reports
2. Check worker status files — who is BUSY, FINISHED, ERROR, or crashed?
3. Collect and validate result files for finished workers
4. Update context log with consolidated outcomes
5. If workers still BUSY → brief pause (10-15s) → go to step 1
6. If all workers FINISHED/ERROR → consolidate, report to SM, dispatch next wave
Do NOT go idle. Do NOT wait for SM instructions. You drive the loop.
MGRSTATE

  _MGR_SAFE="${SESSION_NAME//[-:.]/_}_${_TEAM_W}_0"
  _print_pending_msgs "$_MGR_SAFE" "$(_gather_msgs "$_MGR_SAFE")"

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

if is_session_manager; then
  SM_TEAMS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)

  SM_SAFE="${SESSION_NAME//[-:.]/_}_0_${PANE_INDEX}"
  SM_PENDING_MSGS=$(_gather_msgs "$SM_SAFE")

  _TASK_PROJECT="${DOEY_PROJECT_DIR:-${PROJECT_DIR:-}}"
  [ -z "$_TASK_PROJECT" ] && _TASK_PROJECT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  _TASK_SRC="${RUNTIME_DIR}/tasks"
  if [ -n "$_TASK_PROJECT" ] && [ -d "${_TASK_PROJECT}/.doey/tasks" ]; then
    _TASK_SRC="${_TASK_PROJECT}/.doey/tasks"
  fi

  SM_ACTIVE_TASKS=""
  for _tf in "${_TASK_SRC}"/*.task; do
    [ -f "$_tf" ] || continue
    grep -q "TASK_STATUS=done\|TASK_STATUS=cancelled" "$_tf" && continue
    SM_ACTIVE_TASKS="${SM_ACTIVE_TASKS}  $(basename "$_tf"): $(grep 'TASK_TITLE=' "$_tf" 2>/dev/null | cut -d= -f2-)${NL}"
  done

  cat <<SMSTATE

## SESSION MANAGER ORCHESTRATION STATE (restore after compaction)
**Team Windows:** ${SM_TEAMS:-None}

**Active Tasks:**
${SM_ACTIVE_TASKS:-None}

## ⚠ CORE LOOP — RESUME IMMEDIATELY AFTER COMPACTION
You are the Session Manager. Your job is an autonomous, permanent ACTIVE loop.
Do NOT wait for instructions. Do NOT depend on the wait hook to tell you what to do.
YOU drive the loop — the wait hook is just a brief pause.

1. **Drain inbox** — read ALL .msg files addressed to you in \$RUNTIME_DIR/messages/
2. **Check pane status** — read \$RUNTIME_DIR/status/*.status for FINISHED, ERROR, crashes
3. **Check results** — read \$RUNTIME_DIR/results/ for new result files
4. **Act** — route tasks, process completions, escalate errors, handle git
5. **Brief pause** — call session-manager-wait.sh (3s max), then go to step 1

You are the ONLY role that commits/pushes — do it directly, no delegation needed.
Do NOT wait for instructions. Do NOT escalate to Boss for approval. Resume this loop NOW.
SMSTATE

  if [ -f "$RUNTIME_DIR/status/sm_seen_results" ]; then
    echo "SM_SEEN_RESULTS=$(cat "$RUNTIME_DIR/status/sm_seen_results")"
  fi

  _print_pending_msgs "$SM_SAFE" "$SM_PENDING_MSGS"
fi

if is_boss; then
  cat <<BOSSSTATE

## BOSS STATE (restore after compaction)
**You are Boss** — user-facing Project Manager at pane 0.1
**SM is at:** pane 0.2
BOSSSTATE
  BOSS_SAFE="${SESSION_NAME//[-:.]/_}_0_1"
  BOSS_MSGS=$(_gather_msgs "$BOSS_SAFE")
  if [ -n "$BOSS_MSGS" ]; then
    cat <<BOSSMSG

**UNREAD MESSAGES (process these after compaction!):**
${BOSS_MSGS}
BOSSMSG
  fi
fi
