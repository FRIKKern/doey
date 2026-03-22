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

### Step 1: Pick idle worker + create task marker

Find an idle, unreserved worker: skip if `.reserved` exists, capture-pane to check for `>` prompt.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"; PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports"
cat > "${RUNTIME_DIR}/research/${PANE_SAFE}.task" << 'MARKER'
<research question or goal>
MARKER
rm -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

### Step 2: Ensure worker ready

Check idle via capture-pane. If crashed (bare shell, no claude), kill and restart per `/doey-dispatch` pre-flight. Rename: `/rename research-topic_$(date +%m%d)`.

### Step 3: Dispatch task prompt

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"; PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
REPORT_PATH="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
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
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux load-buffer "$TASKFILE" && tmux paste-buffer -t "$PANE"
TASK_LINES=$(wc -l < "$TASKFILE" | tr -d ' ')
if [ "$TASK_LINES" -gt 200 ]; then sleep 2
elif [ "$TASK_LINES" -gt 100 ]; then sleep 1.5
else sleep 0.5; fi
tmux send-keys -t "$PANE" Enter
rm "$TASKFILE"
```

### Step 4: Verify + read reports

Verify dispatch took: sleep 5s, capture-pane, grep for tool activity (`Read|Edit|Bash|thinking`). If idle, retry Enter+3s. Still idle → unstick per `/doey-dispatch` Unstick section.

After worker finishes:
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" ] && cat "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" || echo "No report"
```

Present summary, ask which option, dispatch via `/doey-dispatch`.

### Rules

1. **Task marker BEFORE dispatch** — stop hook needs it. Clear old report first.
2. **Include report path in prompt** — worker writes there, stop hook checks it.
