---
name: doey-research
description: Dispatch a research task to a worker. Stop hook blocks until report is written. Use when you need to "research a topic before implementing", "investigate an approach", or "spawn a research agent".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team env: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`
- Statuses: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status/*.status; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done 2>/dev/null || true`

Dispatch a research task with guaranteed report-back. `PANE_SAFE` = pane ID with `tr ':-.' '_'`.

### 1. Pick idle worker
Find unreserved worker at `❯` prompt. Skip `.reserved`. If none idle, pick a different worker.

### 2. Create task marker + clear old report
```bash
mkdir -p "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports"
cat > "${RUNTIME_DIR}/research/${PANE_SAFE}.task" << 'MARKER'
<research question or goal>
MARKER
rm -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

### 3. Rename pane
If crashed (bare shell), restart per `/doey-dispatch` pre-flight.
```bash
tmux select-pane -t "$PANE" -T "research-topic_$(date +%m%d)"
```

### 4. Dispatch task prompt
Write to tmpfile, paste via load-buffer, submit:
```
Research & Planning Agent — project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}  |  Use absolute paths.
## Research Task
<QUESTION_OR_GOAL>
## Instructions
**Phase 1 — Research:** Spawn subagents in parallel (Explore/Plan/general-purpose). Second wave if gaps.
**Phase 2 — Plan:** Option A (recommended) + Option B (alternative). Include dispatch-ready task prompts.
**Phase 3 — Write Report** to ${REPORT_PATH}:
## Research Report
**Topic:** ...  |  **Pane:** ${PANE}  |  **Time:** ...
### Summary | Findings | Key Files | Proposed Plan (Option A + B) | Risks
Stop hook blocks until report exists.
```
Dispatch: `tmux load-buffer $TASKFILE && tmux paste-buffer -t $PANE`, sleep by line count (>200: 2s, >100: 1.5s, else 0.5s), Enter, rm tmpfile.

### 5. Verify
`sleep 5`, grep for `Read|Edit|Bash|thinking`. If idle: Enter again, 3s, re-check → unstick per `/doey-dispatch`.

### 6. Read report
Check `${RUNTIME_DIR}/reports/${PANE_SAFE}.report`. Present summary, ask Option A or B, dispatch via `/doey-dispatch`.

### Rules
1. Task marker BEFORE dispatch — stop hook blocks until report written
2. Include report path in prompt — worker writes there, stop hook checks it
3. Never delegate to own pane; always tmpfile + `load-buffer`
