# Skill: doey-research

Dispatch a research & planning task to a worker with guaranteed report-back. The worker investigates thoroughly, then proposes a plan with alternatives. The worker cannot stop until it writes a structured report.

## Usage
`/doey-research`

## Prompt
You are dispatching a research task to a Claude Code worker instance in TMUX. The worker's Stop hook blocks it from finishing until a report file is written.

### Project Context

Read the manifest once per Bash call (see `/doey-dispatch` for details):

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

Provides: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WATCHDOG_PANE`.

### Dispatch Steps

**Step 1: Pick an idle, unreserved worker** — use the pre-flight checks from `/doey-dispatch`.

**Step 2: Create the task marker file.**

```bash
TARGET_PANE="${SESSION_NAME}:0.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')

mkdir -p "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports"
cat > "${RUNTIME_DIR}/research/${PANE_SAFE}.task" << 'MARKER'
<research question or goal here>
MARKER
rm -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

**Step 3: Kill old session, start fresh Claude, rename pane** — follow `/doey-dispatch` steps 1–8. Use `/rename research-<short-topic>`.

**Step 4: Write and dispatch the task prompt.**

```bash
REPORT_PATH="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a Senior Research & Planning Agent on the Doey for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

## Research Task
<QUESTION_OR_GOAL>

## Scope
<OPTIONAL: specific files, directories, or areas to investigate>

## Instructions

### Phase 1: Research (use Agent Swarm)

**You MUST use the Agent tool to spawn subagents for parallel research.** Do not serially read files — launch multiple agents simultaneously.

**Strategy:**
1. Identify 3-5 research questions covering the full scope.
2. Spawn one agent per question — all in a single message for parallelism.
   - \`Explore\` — fast codebase search (files, patterns, keywords). Set thoroughness: "quick"/"medium"/"very thorough".
   - \`Plan\` — architecture analysis, trade-offs, dependencies.
   - \`general-purpose\` — multi-step research needing multiple rounds.
3. Synthesize findings. If gaps remain, spawn a second wave.

Example (single message, 3 agents):
\`\`\`
Agent(subagent_type="Explore", prompt="Find all hook files in ${PROJECT_DIR}. Map connections.", description="explore hooks")
Agent(subagent_type="Explore", prompt="Find all CLI commands and shell scripts. Map entry points.", description="explore CLI")
Agent(subagent_type="general-purpose", prompt="Read install.sh and doey.sh. Document install flow and paths.", description="analyze install")
\`\`\`

### Phase 2: Propose a Plan

Present alternatives:
- **Option A (Recommended):** Best approach with detailed reasoning.
- **Option B:** Alternative with tradeoffs vs A.
- **Option C:** (if applicable)

For the recommended option, include **complete ready-to-dispatch task prompts** with: project name/dir, absolute paths, exact files, what to change, patterns to follow, acceptance criteria.

### Phase 3: Write Report

Write to this EXACT path: ${REPORT_PATH}

Structure:
\`\`\`
## Research & Planning Report
**Topic:** <question>  |  **Pane:** ${TARGET_PANE}  |  **Time:** <timestamp>

### Summary
(2-3 sentence executive summary)

### Findings
(detailed findings — code snippets, file paths, architecture, dependencies)

### Key Files
(bulleted list with brief descriptions)

### Proposed Plan

#### Option A (Recommended): <name>
**Why:** (3-5 sentences)
**Workers:** N  |  **Waves:** N

##### Wave 1 (parallel)
###### Task 1: [short-name]
**Rename:** [title]  |  **Files:** [paths]
**Prompt:** [COMPLETE dispatch-ready prompt]

##### Wave 2 (after Wave 1)
...

##### Verification
(commands to run, files to check)

#### Option B: <name>
**Approach/Tradeoffs:** ...

### Risks
(what could go wrong + mitigations)
\`\`\`

## IMPORTANT
Your Stop hook blocks until the report exists at the path above. Write with the Write tool to the EXACT path. Task prompts must be COMPLETE and dispatch-ready.
TASK

tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "${TARGET_PANE}"
sleep 0.5
tmux send-keys -t "${TARGET_PANE}" Enter
rm "$TASKFILE"
```

**Step 5: Verify dispatch** — follow `/doey-dispatch` step 15.

### Reading Reports

After the worker finishes (shows idle):

```bash
PANE_SAFE=$(echo "${SESSION_NAME}:0.X" | tr ':.' '_')
cat "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

### Acting on the Report

1. Read report, present concise summary to user (findings, recommended option, alternatives)
2. Ask user which option to proceed with
3. On confirmation, dispatch using ready-to-paste task prompts from the report
4. Monitor completion, dispatch subsequent waves, run verification

### Rules

1. **Always create task marker BEFORE dispatching** — the Stop hook needs it to enforce reporting
2. **Always clear old report file before dispatching** — stale reports bypass enforcement
3. **`PANE_SAFE` must match exactly** — full pane ref with `:` and `.` replaced by `_`
4. **Include report path in task prompt** — worker needs to know where to write
