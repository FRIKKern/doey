# Skill: doey-research

Dispatch a research task to a worker. Stop hook blocks until report is written.

## Usage
`/doey-research`

## Prompt

### Project Context
Same as `/doey-dispatch` — source `session.env` and team env. Exit copy-mode before every `paste-buffer`/`send-keys`.

### Step 1: Pick idle, unreserved worker

Same idle/reserved check as `/doey-dispatch` pre-flight. If all reserved, report and wait.

### Step 2: Task marker + clear old report

```bash
TARGET_PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports"
cat > "${RUNTIME_DIR}/research/${PANE_SAFE}.task" << 'MARKER'
<research question or goal>
MARKER
rm -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

### Step 3: Ensure worker ready

Same readiness check as `/doey-dispatch`. Skip if idle. Rename: `/rename research-topic_$(date +%m%d)`.

### Step 4: Dispatch task prompt

Use `/doey-dispatch` paste-buffer sequence with this task template:

```
You are a Research & Planning Agent for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}  |  Use absolute paths.

## Research Task
<QUESTION_OR_GOAL>

## Scope
<OPTIONAL: files/dirs to investigate>

## Instructions
1. **Research:** Spawn subagents in parallel (Explore/Plan/general-purpose). Combine outputs.
2. **Plan:** Option A (recommended) + Option B. Include dispatch-ready task prompts.
3. **Write report** to EXACT path: ${REPORT_PATH}

Report format: Summary, Findings, Key Files, Proposed Plan (Option A with wave/task breakdown including dispatch-ready prompts, Option B with tradeoffs), Risks.

Stop hook blocks until report exists. Task prompts must be dispatch-ready.
```

### Step 5: Verify dispatch

Same as `/doey-dispatch` verification. Sleep 5s, check for tool activity.

### Reading Reports

```bash
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" ] && cat "${RUNTIME_DIR}/reports/${PANE_SAFE}.report" || echo "No report"
```

Present summary, ask which option, dispatch via `/doey-dispatch`.

### Rules
1. Task marker BEFORE dispatch — Stop hook needs it
2. Clear old report first — prevents stale bypass
3. Include report path in prompt; check idle+reserved first
4. Verify after dispatch; verify report after worker finishes
