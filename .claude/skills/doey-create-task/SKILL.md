---
name: doey-create-task
description: Compile a natural-language goal into a structured task package (.task + .json). Usage: /doey-create-task <goal>
---

- Current tasks: !`bash -c 'RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); source "$RUNTIME_DIR/../doey/shell/doey-task-helpers.sh" 2>/dev/null && task_list "$RUNTIME_DIR" 2>/dev/null || echo "No tasks"'`
- Tasks dir: !`bash -c 'RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); PD=$(grep "^PROJECT_DIR=" "$RD/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); if [ -n "$PD" ] && [ -d "$PD/.doey/tasks" ]; then echo "$PD/.doey/tasks"; else echo "$RD/tasks"; fi'`

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
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RD}/../doey/shell/doey-task-helpers.sh" 2>/dev/null || source /home/doey/doey/shell/doey-task-helpers.sh
TASK_ID=$(task_create "$RD" "TITLE" "TYPE" "Boss" "PRIORITY" "SUMMARY" "DESCRIPTION")
echo "Created task #${TASK_ID}"
```

Update .json with compiled fields:
```bash
PD=$(grep '^PROJECT_DIR=' "$RD/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
if [ -n "$PD" ] && [ -d "$PD/.doey/tasks" ]; then TD="$PD/.doey/tasks"; else TD="${RD}/tasks"; fi
python3 -c "
import json
with open('${TD}/${TASK_ID}.json', 'r') as f: data = json.load(f)
data.update({'intent': '...', 'hypotheses': ['H1: ...'], 'constraints': ['...'],
             'success_criteria': ['...'], 'deliverables': ['...'],
             'dispatch_plan': {'mode': 'standard', 'teams': [], 'waves': []}})
with open('${TD}/${TASK_ID}.json', 'w') as f: json.dump(data, f, indent=2)
" 2>/dev/null
```

### 3b. Phased Setup (phased only)

```bash
printf 'TASK_DISPATCH_MODE="phased"\nTASK_CURRENT_PHASE=0\nTASK_TOTAL_PHASES=%d\n' "$TOTAL_PHASES" >> "${TD}/${TASK_ID}.task"
mkdir -p "$RD/phases"
python3 -c "
import json
phases = [{'phase': 1, 'title': 'T', 'brief': 'B', 'team_scope': 'any'}]  # replace with actuals
json.dump({'task_id': '${TASK_ID}', 'total_phases': len(phases), 'current_phase': 0, 'phases': phases},
          open('${RD}/phases/task_${TASK_ID}.json', 'w'), indent=2)
" 2>/dev/null
```

### 4. Output
ID, title, type, intent, hypotheses, dispatch plan, paths. Phased: phase count/titles.

Use `task_create` from helpers — never duplicate. `/doey-task add` for simple tasks. One clarifying question max.
