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

ROLE_LABEL="a Doey ${DOEY_ROLE_WORKER}"
is_boss && ROLE_LABEL="the Doey ${DOEY_ROLE_BOSS}"
is_manager && ROLE_LABEL="the Doey ${DOEY_ROLE_TEAM_LEAD}"
is_taskmaster && ROLE_LABEL="the Doey ${DOEY_ROLE_COORDINATOR}"

cat <<CONTEXT
## Context Preservation (Pre-Compaction)
**Pane:** ${PANE}
**Current Task:** ${CURRENT_TASK:-No active task}
**Research Topic:** ${RESEARCH_TOPIC:-None}
**Research Report Written:** $([ -f "$REPORT_PATH" ] && echo yes || echo no)
**Recently Modified Files:**
${RECENT_FILES:-None detected}

$(if is_manager; then echo "You ARE the ${DOEY_ROLE_TEAM_LEAD}. You plan, delegate, and synthesize. You never write code or read source files. ${DOEY_ROLE_COORDINATOR} sends you tasks. You dispatch to ${DOEY_ROLE_WORKER}s. Continue from this preserved state."; elif is_taskmaster; then echo "You ARE the ${DOEY_ROLE_COORDINATOR}. You route tasks between teams and orchestrate completion. You never write code or read source files. You report to ${DOEY_ROLE_BOSS}. Continue from this preserved state."; else echo "You are ${ROLE_LABEL}. Continue from this preserved state."; fi)${RESEARCH_TOPIC:+ Research report required: ${REPORT_PATH}}
CONTEXT

# Include context overlay content if available (survives compaction)
if [ -n "${DOEY_CONTEXT_OVERLAY:-}" ] && [ -f "$DOEY_CONTEXT_OVERLAY" ]; then
  echo ""
  echo "## Project Context Overlay (role-specific)"
  head -200 "$DOEY_CONTEXT_OVERLAY"
fi
if [ -n "${DOEY_CONTEXT_OVERLAY_ALL:-}" ] && [ -f "$DOEY_CONTEXT_OVERLAY_ALL" ]; then
  echo ""
  echo "## Project Context Overlay (shared)"
  head -200 "$DOEY_CONTEXT_OVERLAY_ALL"
fi

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

## SUBTASKMASTER ORCHESTRATION STATE (restore after compaction)
**${DOEY_ROLE_WORKER} Assignments (pane_index title):**
${WORKER_ASSIGNMENTS:-No panes found}

**Pending Result Files:**
${PENDING_RESULTS:-None}

**Unprocessed Completion Files:**
${COMPLETION_FILES:-None}

**Crash Alerts:**
${CRASH_FILES:-None}

## ⚠ CORE LOOP — RESUME ACTIVE MONITORING AFTER COMPACTION
You are a ${DOEY_ROLE_TEAM_LEAD}. You MUST stay active while ANY worker is BUSY.
After compaction, resume your active monitoring loop IMMEDIATELY:
1. Drain message queue — read all .msg files for completion reports
2. Check worker status files — who is BUSY, FINISHED, ERROR, or crashed?
3. Collect and validate result files for finished workers
4. Update context log with consolidated outcomes
5. If workers still BUSY → brief pause (10-15s) → go to step 1
6. If all workers FINISHED/ERROR → consolidate, report to ${DOEY_ROLE_COORDINATOR}, dispatch next wave
Do NOT go idle. Do NOT wait for ${DOEY_ROLE_COORDINATOR} instructions. You drive the loop.
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

if is_taskmaster; then
  TASKMASTER_TEAMS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)

  TASKMASTER_SAFE="${SESSION_NAME//[-:.]/_}_0_${PANE_INDEX}"
  TASKMASTER_PENDING_MSGS=$(_gather_msgs "$TASKMASTER_SAFE")

  _TASK_PROJECT="${DOEY_PROJECT_DIR:-${PROJECT_DIR:-}}"
  [ -z "$_TASK_PROJECT" ] && _TASK_PROJECT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  _TASK_SRC="${RUNTIME_DIR}/tasks"
  if [ -n "$_TASK_PROJECT" ] && [ -d "${_TASK_PROJECT}/.doey/tasks" ]; then
    _TASK_SRC="${_TASK_PROJECT}/.doey/tasks"
  fi

  TASKMASTER_ACTIVE_TASKS=""
  _compact_task_scan_done=false
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${_TASK_PROJECT:-}" ]; then
    while IFS= read -r _ct_line; do
      _ct_id=$(echo "$_ct_line" | awk '{print $1}')
      [ -z "$_ct_id" ] && continue
      case "$_ct_line" in *" done "*|*" cancelled "*) continue ;; esac
      _ct_info=$(doey-ctl task get --id "$_ct_id" --project-dir "$_TASK_PROJECT" 2>/dev/null) || continue
      _ct_title=$(echo "$_ct_info" | sed -n 's/^Title:[[:space:]]*//p')
      _ct_status=$(echo "$_ct_info" | sed -n 's/^Status:[[:space:]]*//p')
      TASKMASTER_ACTIVE_TASKS="${TASKMASTER_ACTIVE_TASKS}  ${_ct_id}: ${_ct_title} [${_ct_status}]${NL}"
    done <<EOF
$(doey-ctl task list --project-dir "$_TASK_PROJECT" 2>/dev/null | tail -n +2)
EOF
    _compact_task_scan_done=true
  fi
  if [ "$_compact_task_scan_done" = false ]; then
    for _tf in "${_TASK_SRC}"/*.task; do
      [ -f "$_tf" ] || continue
      grep -q "TASK_STATUS=done\|TASK_STATUS=cancelled" "$_tf" && continue
      TASKMASTER_ACTIVE_TASKS="${TASKMASTER_ACTIVE_TASKS}  $(basename "$_tf"): $(grep 'TASK_TITLE=' "$_tf" 2>/dev/null | cut -d= -f2-)${NL}"
    done
  fi

  cat <<SMSTATE

## TASKMASTER ORCHESTRATION STATE (restore after compaction)
**Team Windows:** ${TASKMASTER_TEAMS:-None}

**Active Tasks:**
${TASKMASTER_ACTIVE_TASKS:-None}

## ⚠ CORE LOOP — RESUME IMMEDIATELY AFTER COMPACTION
You are the ${DOEY_ROLE_COORDINATOR}. Your job is an autonomous, permanent ACTIVE loop.
Do NOT wait for instructions. Do NOT depend on the wait hook to tell you what to do.
YOU drive the loop — the wait hook is just a brief pause.

1. **Drain inbox** — read ALL .msg files addressed to you in \$RUNTIME_DIR/messages/
2. **Check pane status** — read \$RUNTIME_DIR/status/*.status for FINISHED, ERROR, crashes
3. **Check results** — read \$RUNTIME_DIR/results/ for new result files
4. **Act** — route tasks, process completions, escalate errors, handle git
5. **Brief pause** — call taskmaster-wait.sh (3s max), then go to step 1

You are the ONLY role that commits/pushes — do it directly, no delegation needed.
Do NOT wait for instructions. Do NOT escalate to ${DOEY_ROLE_BOSS} for approval. Resume this loop NOW.
SMSTATE

  if [ -f "$RUNTIME_DIR/status/taskmaster_seen_results" ]; then
    echo "SM_SEEN_RESULTS=$(cat "$RUNTIME_DIR/status/taskmaster_seen_results")"
  fi

  _print_pending_msgs "$TASKMASTER_SAFE" "$TASKMASTER_PENDING_MSGS"
fi

if is_boss; then
  cat <<BOSSSTATE

## BOSS STATE (restore after compaction)
**You are ${DOEY_ROLE_BOSS}** — user-facing Project Manager at pane 0.1
**${DOEY_ROLE_COORDINATOR} is at:** pane $(get_taskmaster_pane)
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

# Stats emit (task #521 Phase 2) — context compaction event
if command -v doey-stats-emit.sh >/dev/null 2>&1; then
  (doey-stats-emit.sh worker context_compacted "role=${DOEY_ROLE:-unknown}" &) 2>/dev/null || true
fi
