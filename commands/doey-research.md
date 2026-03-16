# Skill: doey-research

Dispatch a research task to a worker with guaranteed report-back via Stop hook enforcement.

## Usage
`/doey-research`

## Prompt
Dispatch a research task to a worker. Stop hook blocks until report is written.

### Project Context

Load in every Bash call touching tmux:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```

Provides: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WINDOW_INDEX`. Never hardcode session names. **Copy-mode:** run `tmux copy-mode -q -t "$PANE" 2>/dev/null` before every `paste-buffer`/`send-keys`.

### Step 1: Pick idle, unreserved worker

```bash
# Load context vars (see above)
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && echo "Reserved — skip"
tmux copy-mode -q -t "${SESSION_NAME}:${WINDOW_INDEX}.X" 2>/dev/null
tmux capture-pane -t "${SESSION_NAME}:${WINDOW_INDEX}.X" -p -S -3
```

Never dispatch to RESERVED panes. If all reserved, report and wait.

### Step 2: Task marker + clear old report

```bash
# Load context vars
TARGET_PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports"
cat > "${RUNTIME_DIR}/research/${PANE_SAFE}.task" << 'MARKER'
<research question or goal>
MARKER
rm -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

### Step 3: Ensure worker ready

Same readiness/restart sequence as `/doey-dispatch` steps 1-7. Skip if idle. Rename: `tmux send-keys -t "$PANE" "/rename research-topic_$(date +%m%d)" Enter` + `sleep 1`.

### Step 4: Dispatch task prompt

```bash
# Load context vars
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
REPORT_PATH="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"

TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a Research & Planning Agent for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}  |  Use absolute paths.

## Research Task
<QUESTION_OR_GOAL>

## Scope
<OPTIONAL: files/dirs to investigate>

## Instructions

### Phase 1: Research (Agent Swarm)
**Spawn subagents in parallel — never read serially.**
1. Identify 3-5 research questions.
2. Spawn one agent per question in a single message:
   - \`Explore\` — codebase search, set thoroughness
   - \`Plan\` — architecture, trade-offs
   - \`general-purpose\` — multi-step research
3. Combine outputs. Second wave if gaps remain.

### Phase 2: Plan
- **Option A (Recommended):** Best approach + reasoning
- **Option B:** Alternative + tradeoffs
Include **dispatch-ready task prompts** for recommended option.

### Phase 3: Write Report
Write to EXACT path: ${REPORT_PATH}

\`\`\`
## Research Report
**Topic:** <question>  |  **Pane:** ${PANE}  |  **Time:** <timestamp>
### Summary
(2-3 sentences)
### Findings
(code snippets, paths, architecture, dependencies)
### Key Files
(bulleted list)
### Proposed Plan
#### Option A (Recommended): <name>
**Why:** ...  |  **Workers:** N  |  **Waves:** N
##### Wave 1 (parallel)
###### Task 1: [name]
**Rename:** [title]  |  **Files:** [paths]
**Prompt:** [dispatch-ready prompt]
##### Wave 2 ...
##### Verification
(commands/files to check)
#### Option B: <name>
**Tradeoffs:** ...
### Risks
(problems + mitigations)
\`\`\`

Stop hook blocks until report exists. Task prompts must be dispatch-ready.
TASK

tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "$PANE"
tmux copy-mode -q -t "$PANE" 2>/dev/null
TASK_LINES=$(wc -l < "$TASKFILE" 2>/dev/null | tr -d ' ') || TASK_LINES=0
if [ "$TASK_LINES" -gt 200 ] 2>/dev/null; then SETTLE_S=2
elif [ "$TASK_LINES" -gt 100 ] 2>/dev/null; then SETTLE_S=1.5
else SETTLE_S=0.5; fi
sleep $SETTLE_S
tmux send-keys -t "$PANE" Enter
rm "$TASKFILE"
```

### Step 5: Verify dispatch

Same as `/doey-dispatch` step 15. Sleep 5s, capture, grep `thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent`. If idle, retry Enter+3s. Still failed: unstick from `/doey-dispatch`.

### Reading Reports

After worker finishes:

```bash
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" ] && cat "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" || echo "No report"
```

Present summary, ask which option, dispatch via `/doey-dispatch`.

### Rules

1. **Task marker BEFORE dispatch** — Stop hook needs it
2. **Clear old report first** — prevents stale bypass
3. **`PANE_SAFE`:** `$(echo "$PANE" | tr ':.' '_')` (e.g. `doey-proj:1.3` -> `doey-proj_1_3`)
4. **Include report path in prompt** | **Check idle+reserved first**
5. **Verify after dispatch** | **Verify report after worker finishes**
