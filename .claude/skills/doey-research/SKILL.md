---
name: doey-research
description: Dispatch a research task to a worker. Stop hook blocks until report is written. Use when you need to "research a topic before implementing", "investigate an approach", or "spawn a research agent".
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team environment: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`
- Worker status: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status/*.status; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done 2>/dev/null || true`

## Prompt

Dispatch a research task with guaranteed report-back. `PANE_SAFE` = pane ID with `:` `.` replaced by `_`.

## Step 1: Pick idle worker

Find unreserved worker at `❯` prompt. Skip if `.reserved` exists.

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}" && PANE="${SESSION_NAME}:${WINDOW_INDEX}.X" && PANE_SAFE=$(echo "$PANE" | tr ':-.' '_') && [ ! -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && tmux capture-pane -t "$PANE" -p -S -5 | grep -q '❯' && echo "Idle — OK"

If reserved or no `❯` prompt: pick a different worker.

## Step 2: Create task marker + clear old report

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}" && PANE="${SESSION_NAME}:${WINDOW_INDEX}.X" && PANE_SAFE=$(echo "$PANE" | tr ':-.' '_') && mkdir -p "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports" && cat > "${RUNTIME_DIR}/research/${PANE_SAFE}.task" << 'MARKER'
<research question or goal>
MARKER
rm -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"

## Step 3: Ensure worker ready + rename pane

If crashed (bare shell), kill and restart per `/doey-dispatch` pre-flight.

bash: tmux select-pane -t "$PANE" -T "research-topic_$(date +%m%d)"

## Step 4: Dispatch task prompt

Write prompt to tmpfile, paste via load-buffer, submit.

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}" && PANE="${SESSION_NAME}:${WINDOW_INDEX}.X" && PANE_SAFE=$(echo "$PANE" | tr ':-.' '_') && REPORT_PATH="${RUNTIME_DIR}/reports/${PANE_SAFE}.report" && TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt") && cat > "$TASKFILE" << TASK
Research & Planning Agent — project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}  |  Use absolute paths.

## Research Task
<QUESTION_OR_GOAL>

## Instructions
**Phase 1 — Research:** Spawn subagents in parallel (Explore/Plan/general-purpose). One agent per key question. Second wave if gaps remain.
**Phase 2 — Plan:** Option A (recommended) + Option B (alternative). Include dispatch-ready task prompts.
**Phase 3 — Write Report** to ${REPORT_PATH}:
\`\`\`
## Research Report
**Topic:** ...  |  **Pane:** ${PANE}  |  **Time:** ...
### Summary | Findings | Key Files | Proposed Plan (Option A + B) | Risks
\`\`\`
Stop hook blocks until report exists.
TASK
tmux copy-mode -q -t "$PANE" 2>/dev/null; tmux load-buffer "$TASKFILE" && tmux paste-buffer -t "$PANE" && TASK_LINES=$(wc -l < "$TASKFILE" | tr -d ' ') && if [ "$TASK_LINES" -gt 200 ]; then sleep 2; elif [ "$TASK_LINES" -gt 100 ]; then sleep 1.5; else sleep 0.5; fi && tmux send-keys -t "$PANE" Enter && rm "$TASKFILE"

## Step 5: Verify dispatch

bash: sleep 5; if tmux capture-pane -t "$PANE" -p -S -10 | grep -qE 'Read|Edit|Bash|thinking'; then echo "Working"; else echo "Idle — may need retry"; fi

If idle: send Enter again, wait 3s, re-check. Still idle → unstick per `/doey-dispatch`.

## Step 6: Read report when worker finishes

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}" && PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':-.' '_') && [ -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" ] && cat "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" || echo "No report yet"

Present summary, ask which option (A or B), dispatch via `/doey-dispatch`. If no report yet, wait for FINISHED status.

### Rules

1. **Task marker BEFORE dispatch** — stop hook needs it to block until report written
2. **Include report path in prompt** — worker writes there, stop hook checks it
3. Never delegate to own pane; always use tmpfile + `load-buffer` (not `send-keys` for long text)
