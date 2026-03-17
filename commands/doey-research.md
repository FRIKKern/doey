# Skill: doey-research

Dispatch a research task to a worker with guaranteed report-back via Stop hook enforcement.

## Usage
`/doey-research`

## Prompt
Dispatch a research task to a worker. Stop hook blocks until report is written.

### Step 1: Find idle worker

```bash
doey status
```

Pick an idle, unreserved worker. If all busy/reserved, report and wait. **Never dispatch to RESERVED panes.**

### Step 2: Task marker + clear old report

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TARGET_PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports"
cat > "${RUNTIME_DIR}/research/${PANE_SAFE}.task" << 'MARKER'
<research question or goal>
MARKER
rm -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

Replace X with chosen pane index. Replace `<research question or goal>` with the actual topic.

### Step 3: Rename worker

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux send-keys -t "$PANE" "/rename research-topic_$(date +%m%d)" Enter
sleep 1
```

### Step 4: Dispatch research prompt

Build the full research prompt, then use `doey dispatch`:

The task prompt template (customize QUESTION_OR_GOAL, SCOPE, and REPORT_PATH):

```
You are a Research & Planning Agent for project: PROJECT_NAME
Project directory: PROJECT_DIR  |  Use absolute paths.

## Research Task
<QUESTION_OR_GOAL>

## Scope
<OPTIONAL: files/dirs to investigate>

## Instructions

### Phase 1: Research (Agent Swarm)
**Spawn subagents in parallel — never read serially.**
1. Identify 3-5 research questions.
2. Spawn one agent per question in a single message:
   - `Explore` — codebase search, set thoroughness
   - `Plan` — architecture, trade-offs
   - `general-purpose` — multi-step research
3. Combine outputs. Second wave if gaps remain.

### Phase 2: Plan
- **Option A (Recommended):** Best approach + reasoning
- **Option B:** Alternative + tradeoffs
Include **dispatch-ready task prompts** for recommended option.

### Phase 3: Write Report
Write to EXACT path: REPORT_PATH

## Research Report
**Topic:** <question>  |  **Pane:** PANE  |  **Time:** <timestamp>
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

Stop hook blocks until report exists. Task prompts must be dispatch-ready.
```

Dispatch using: `doey dispatch "full prompt text" W.X`

### Step 5: Reading Reports

After worker finishes:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" ] && cat "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" || echo "No report yet"
```

Present summary, ask which option to proceed with, dispatch via `/doey-dispatch`.

### Rules

1. **Task marker BEFORE dispatch** — Stop hook needs it
2. **Clear old report first** — prevents stale bypass
3. **`PANE_SAFE`:** `$(echo "$PANE" | tr ':.' '_')` (e.g. `doey-proj:1.3` → `doey-proj_1_3`)
4. **Include report path in prompt** | **Check idle+reserved first**
5. **Verify `doey dispatch` output** | **Verify report after worker finishes**
