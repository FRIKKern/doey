# Skill: doey-research

Dispatch a research task to a worker. Stop hook blocks until report is written.

## Usage
`/doey-research`

## Prompt
Dispatch a research task with guaranteed report-back.

### Preamble

Every bash block starts with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```

Always exit copy-mode before `paste-buffer`/`send-keys`: `tmux copy-mode -q -t "$PANE" 2>/dev/null`

### Step 1: Pick idle, unreserved worker

```bash
# (preamble)
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && echo "Reserved — skip"
tmux copy-mode -q -t "${SESSION_NAME}:${WINDOW_INDEX}.X" 2>/dev/null
tmux capture-pane -t "${SESSION_NAME}:${WINDOW_INDEX}.X" -p -S -3
```

### Step 2: Create task marker + clear old report

```bash
# (preamble)
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports"
cat > "${RUNTIME_DIR}/research/${PANE_SAFE}.task" << 'MARKER'
<research question or goal>
MARKER
rm -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

### Step 3: Ensure worker ready

Same as `/doey-dispatch` readiness sequence. Rename: `/rename research-topic_$(date +%m%d)`.

### Step 4: Dispatch task prompt

```bash
# (preamble)
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
REPORT_PATH="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
Research & Planning Agent — project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}  |  Use absolute paths.

## Research Task
<QUESTION_OR_GOAL>

## Instructions
**Phase 1 — Research:** Spawn subagents in parallel (Explore/Plan/general-purpose). 3-5 questions, one agent each. Second wave if gaps remain.
**Phase 2 — Plan:** Option A (recommended) + Option B (alternative). Include dispatch-ready task prompts.
**Phase 3 — Write Report** to ${REPORT_PATH}:
\`\`\`
## Research Report
**Topic:** ...  |  **Pane:** ${PANE}  |  **Time:** ...
### Summary (2-3 sentences)
### Findings (snippets, paths, dependencies)
### Key Files
### Proposed Plan
#### Option A: <name> — Why, Workers, Waves, per-worker prompts, verification
#### Option B: <name> — tradeoffs
### Risks + mitigations
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

### Step 5: Verify + read reports

Verify: same as `/doey-dispatch` step 15. Sleep 5s, grep for tool activity. Idle → retry Enter+3s → unstick per `/doey-dispatch`.

After worker finishes:
```bash
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" ] && cat "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" || echo "No report"
```

Present summary, ask which option, dispatch via `/doey-dispatch`.

### Rules

1. **Task marker BEFORE dispatch** — stop hook needs it. **Clear old report first** — prevents false bypass.
2. **PANE_SAFE:** replace `:` and `.` with `_`. **Include report path in prompt.**
3. **Verify after dispatch and after worker finishes.**
