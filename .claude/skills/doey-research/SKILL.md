---
name: doey-research
description: Dispatch a research task to a worker. Stop hook blocks until report is written. Use when you need to "research a topic before implementing", "investigate an approach", or "spawn a research agent".
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team environment: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`
- Worker status: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status/*.status; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done 2>/dev/null || true`

## Prompt

**Expected:** 4 tmux commands (capture-pane, copy-mode, load-buffer/paste-buffer, send-keys), 3 file writes (task marker, tmpfile, report check), ~15s dispatch + variable research time.

Dispatch a research task with guaranteed report-back. Session/team config is injected above.

`PANE_SAFE` = pane ID with `:` and `.` replaced by `_`. Always exit copy-mode before `paste-buffer`/`send-keys`.

## Step 1: Pick idle worker

Find an idle, unreserved worker: skip if `.reserved` exists, capture-pane to check for `>` prompt.

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}" && PANE="${SESSION_NAME}:${WINDOW_INDEX}.X" && PANE_SAFE=$(echo "$PANE" | tr ':.' '_') && [ ! -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && tmux capture-pane -t "$PANE" -p -S -5 | grep -q '❯' && echo "Idle — OK"
Expected: "Idle — OK" printed, confirming an unreserved worker at the `>` prompt.

**If this fails with "reserved":** Pick a different worker pane index and retry.
**If this fails with no `>` prompt:** Worker may be busy or crashed — check capture-pane output and pick another.

## Step 2: Create task marker + clear old report

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}" && PANE="${SESSION_NAME}:${WINDOW_INDEX}.X" && PANE_SAFE=$(echo "$PANE" | tr ':.' '_') && mkdir -p "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports" && cat > "${RUNTIME_DIR}/research/${PANE_SAFE}.task" << 'MARKER'
<research question or goal>
MARKER
rm -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
Expected: Task marker file created at `${RUNTIME_DIR}/research/${PANE_SAFE}.task`, old report removed.

**If this fails with "No such file or directory":** Verify `RUNTIME_DIR` is set correctly from `tmux show-environment`.

## Step 3: Ensure worker ready

Check idle via capture-pane. If crashed (bare shell, no claude), kill and restart per `/doey-dispatch` pre-flight. Rename pane:

bash: tmux select-pane -t "$PANE" -T "research-topic_$(date +%m%d)"
Expected: Pane title updated to reflect research topic.

**If this fails with "can't find pane":** Verify PANE address is correct (session:window.pane format).

## Step 4: Dispatch task prompt

Write the research prompt to a tmpfile, paste it into the worker pane, then submit.

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}" && PANE="${SESSION_NAME}:${WINDOW_INDEX}.X" && PANE_SAFE=$(echo "$PANE" | tr ':.' '_') && REPORT_PATH="${RUNTIME_DIR}/reports/${PANE_SAFE}.report" && TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt") && cat > "$TASKFILE" << TASK
Research & Planning Agent — project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}  |  Use absolute paths.

## Research Task
<QUESTION_OR_GOAL>

## Instructions
**Phase 1 — Research:** Spawn subagents in parallel (Explore/Plan/general-purpose). Identify key questions, one agent each. Second wave if gaps remain.
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
Expected: Task prompt pasted and submitted to worker pane. Tmpfile cleaned up.

**If this fails with "no buffer":** Ensure `load-buffer` succeeded — check that TASKFILE was written correctly.
**If this fails with "can't find pane":** Verify PANE address; the worker may have been killed.

## Step 5: Verify dispatch took

bash: sleep 5 && tmux capture-pane -t "$PANE" -p -S -10 | grep -qE 'Read|Edit|Bash|thinking' && echo "Working" || echo "Idle — may need retry"
Expected: "Working" — worker is actively processing the research task.

**If this fails with "Idle — may need retry":** Send Enter again: `tmux send-keys -t "$PANE" Enter`, wait 3s, re-check. Still idle → unstick per `/doey-dispatch` Unstick section.

## Step 6: Read report when worker finishes

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}" && PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_') && [ -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" ] && cat "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" || echo "No report yet"
Expected: Report contents printed. Present summary to user, ask which option (A or B), then dispatch via `/doey-dispatch`.

**If this fails with "No report yet":** Worker may still be running. Check pane status and wait for FINISHED status.

## Gotchas

- Do NOT dispatch before creating the task marker — the stop hook needs it to block until the report is written.
- Do NOT forget to include the report path in the prompt — the worker writes there, the stop hook checks it.
- Do NOT delegate to your own pane.
- Do NOT use `send-keys` for long task text — always use tmpfile + `load-buffer` + `paste-buffer`.

### Rules

1. **Task marker BEFORE dispatch** — stop hook needs it. Clear old report first.
2. **Include report path in prompt** — worker writes there, stop hook checks it.

Total: 6 commands, 0 errors expected.
