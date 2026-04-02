---
name: doey-create-task
description: Compile a natural-language goal into a structured task package (.task + .json). Usage: /doey-create-task <goal>
---

- Current tasks: !`doey-ctl task list 2>/dev/null || echo "No tasks"`

**Prefer `/doey-planned-task` for multi-step work and `/doey-instant-task` for simple tasks.** This skill creates raw task files without planning — use it as a fallback only.

Compile a natural-language goal into a task package. Goal from ARGUMENTS (if empty, ask and stop).

### 1. Triviality Check
- **TRIVIAL** — Direct question/lookup → answer directly, stop
- **SIMPLE** — Single action → `/doey-task add "title"`, stop
- **STRUCTURED** — Multi-step → continue

### 2. Compile Task Package

```
TYPE: [feature|bugfix|refactor|research|audit|docs|infrastructure]
INTENT: [what + why]  |  BRIDGE: [current → desired state]
HYPOTHESES: H1 [approach, confidence] | H2 [alternative, confidence]
CONSTRAINTS | SUCCESS CRITERIA | DELIVERABLES
DISPATCH: [standard|phased] + team assignment
```

Use `phased` if goal mentions phases, sequential deps, or "staged".

### 3. Create Artifacts

```bash
TASK_ID=$(doey-ctl task create --title "TITLE" --type "TYPE" --description "DESCRIPTION")
echo "Created task #${TASK_ID}"
```

Update task with compiled fields:
```bash
doey-ctl task update --id "$TASK_ID" --field "intent" --value "..."
doey-ctl task update --id "$TASK_ID" --field "hypotheses" --value "H1: ..."
doey-ctl task update --id "$TASK_ID" --field "constraints" --value "..."
doey-ctl task update --id "$TASK_ID" --field "success_criteria" --value "..."
doey-ctl task update --id "$TASK_ID" --field "deliverables" --value "..."
doey-ctl task update --id "$TASK_ID" --field "dispatch_plan" --value "standard"
```

### 3b. Phased Setup (phased only)

```bash
doey-ctl task update --id "$TASK_ID" --field "TASK_DISPATCH_MODE" --value "phased"
doey-ctl task update --id "$TASK_ID" --field "TASK_CURRENT_PHASE" --value "0"
doey-ctl task update --id "$TASK_ID" --field "TASK_TOTAL_PHASES" --value "$TOTAL_PHASES"
```

### 4. Output
ID, title, type, intent, hypotheses, dispatch plan, paths. Phased: phase count/titles.

Use `doey-ctl task create` — never duplicate. `/doey-task add` for simple tasks. One clarifying question max.
