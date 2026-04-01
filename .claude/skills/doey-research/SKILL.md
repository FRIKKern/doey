---
name: doey-research
description: Dispatch a research task to a worker. Stop hook blocks until report is written. Use when you need to "research a topic before implementing", "investigate an approach", or "spawn a research agent".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team env: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`
- Statuses: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status/*.status; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done 2>/dev/null || true`

Research with guaranteed report. `PANE_SAFE` = pane ID via `tr ':-.' '_'`.

### 1. Pick idle unreserved worker (❯ prompt)

### 2. Create marker + rename
```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
mkdir -p "${RD}/research" "${RD}/reports"
echo "<research goal>" > "${RD}/research/${PANE_SAFE}.task"
rm -f "${RD}/reports/${PANE_SAFE}.report"
tmux select-pane -t "$PANE" -T "research-topic_$(date +%m%d)"
```

### 3. Dispatch (tmpfile → load-buffer → paste-buffer → Enter)
```
Research & Planning Agent — project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}  |  Absolute paths.
## Task: <QUESTION_OR_GOAL>
Phase 1: Spawn subagents in parallel. Second wave if gaps.
Phase 2: Option A (recommended) + B. Include dispatch-ready prompts.
Phase 3: Write report to ${REPORT_PATH} — Summary, Findings, Key Files, Plan (A+B), Risks.
Stop hook blocks until report exists.
```
Settle by line count (>200: 2s, >100: 1.5s, else 0.5s).

### 4. Verify (sleep 5, grep `Read|Edit|Bash|thinking`, retry once)

### 5. Read report → present summary → ask A or B → `/doey-dispatch`

Marker BEFORE dispatch (stop hook blocks). Include report path. Never own pane. Always tmpfile + `load-buffer`.
