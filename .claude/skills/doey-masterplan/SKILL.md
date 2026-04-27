---
name: doey-masterplan
description: Strategic planning with a mandatory interview phase followed by ultrathink research and vertical phase design. Usage: /doey-masterplan [--quick] <goal>
---

- Current tasks: !`doey task list 2>/dev/null || echo "No tasks"`
- Plans dir: !`bash -c 'PD=$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); echo "${PD:-.}/.doey/plans"'`
- Existing plans: !`bash -c 'PD=$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); ls "${PD:-.}/.doey/plans/"*.md 2>/dev/null | head -10 || echo "None"'`
- Team def exists: !`bash -c 'for d in . .doey teams "${HOME}/.config/doey/teams"; do [ -f "${d}/masterplan.team.md" ] && echo "YES: ${d}/masterplan.team.md" && exit 0; done; echo "NOT FOUND"'`

## Worktrees + Branches Are Forbidden By Default

Never suggest `/doey-worktree`, branch creation, or worktree flow in plan output. All phases commit to the session's starting branch (typically main). If — and only if — the user's literal input (the goal text) contains the word "worktree", you may surface /doey-worktree as the explicit opt-in path.

Spawn a Masterplanner team window for strategic planning. Goal from ARGUMENTS (if empty, use AskUserQuestion to ask, then stop).

By default this skill runs a structured **Deep Interview** first so the Planner starts with a clean brief (intent, scope, non-goals, constraints, success criteria). Pass `--quick` to skip the interview for goals that are already concrete.

This is NOT a quick task planner — it spawns a full team window with a Planner, live plan viewer, and 4 research workers. Use `/doey-planned-task` instead if the goal is a single feature or straightforward change.

### Step 1: Parse ARGUMENTS and Validate Goal

Extract `--quick` flag if present; the remaining text is the goal. If the goal is empty after stripping flags, use AskUserQuestion to ask the user, then stop.

```bash
RAW_ARGS="${ARGUMENTS:-}"
QUICK_MODE=0
GOAL_TEXT="$RAW_ARGS"
case " $RAW_ARGS " in
  *' --quick '*)
    QUICK_MODE=1
    GOAL_TEXT="$(printf '%s' "$RAW_ARGS" | sed 's/--quick//g' | sed 's/^ *//;s/ *$//')"
    ;;
esac
if [ -z "$GOAL_TEXT" ]; then
  echo "NO_GOAL — use AskUserQuestion, then stop"
  exit 0
fi
printf 'Goal: %s\n' "$GOAL_TEXT"
printf 'Quick mode: %s\n' "$QUICK_MODE"
```

### Step 2: Ambiguity Detection

Decide whether to run the interview. The interview is **mandatory by default** — it only gets skipped for `--quick` or goals the helper classifies as `CLEAR`.

Heuristic (implemented in `doey-masterplan-ambiguity.sh`):
- `--quick` flag present → skip interview
- Else call `masterplan_ambiguity_score "$GOAL_TEXT"` — returns `CLEAR` or `AMBIGUOUS`
- `CLEAR` → skip interview (goal already specific)
- `AMBIGUOUS` → run interview (default)

```bash
. "$HOME/.local/bin/doey-masterplan-ambiguity.sh"
RUN_INTERVIEW=1
CLASSIFICATION=quick
if [ "$QUICK_MODE" = "1" ]; then
  RUN_INTERVIEW=0
else
  CLASSIFICATION=$(masterplan_ambiguity_score "$GOAL_TEXT")
  if [ "$CLASSIFICATION" = "CLEAR" ]; then
    RUN_INTERVIEW=0
  fi
fi
printf 'Run interview: %s (classification=%s)\n' "$RUN_INTERVIEW" "$CLASSIFICATION"
```

### Step 3: Setup Masterplan Working Directory (common to both modes)

Create the masterplan working directory, write the goal file, allocate a numeric plan ID via `doey plan create`, write a valid frontmatter plan skeleton (so the TUI Plans tab sees it immediately), and write `masterplan.env` — this is what `doey-masterplan-spawn.sh` will consume in Step 3.5 when it spawns the masterplan team window.

The runtime working dir keeps its timestamp-based name (`masterplan-<TS>`), but `PLAN_ID` and the plan file on disk are **numeric** so `tui/internal/store/migrate.go` picks the plan up for the Plans tab.

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RD}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
PROJECT_DIR="${PROJECT_DIR:-.}"
PLANS_DIR="${PROJECT_DIR}/.doey/plans"
MP_TS="$(date +%Y%m%d-%H%M%S)"
MP_NAME="masterplan-${MP_TS}"
MP_DIR="${RD}/${MP_NAME}"
SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null)
mkdir -p "${MP_DIR}/research" "${PLANS_DIR}"
echo "Masterplan working dir: ${MP_DIR}"
```

Write the goal file:

```bash
cat > "${MP_DIR}/goal.md" << 'GOAL_EOF'
<INSERT THE FULL GOAL_TEXT HERE — the text the user provided, minus any --quick flag>
GOAL_EOF
echo "Goal written to ${MP_DIR}/goal.md"
```

Create the tracked task, allocate the numeric plan ID, write the frontmatter stub, and write `masterplan.env`:

```bash
GOAL=$(head -1 "${MP_DIR}/goal.md")
GOAL_TITLE="$(head -n 40 "${MP_DIR}/goal.md" | awk '/^# /{print substr($0,3); exit}')"
[ -z "$GOAL_TITLE" ] && GOAL_TITLE="$(printf '%.80s' "$GOAL")"
GOAL_TITLE="$(printf '%s' "$GOAL_TITLE" | tr -d '"')"

DOEY_TASK_ID=$(doey task create --title "Masterplan: ${GOAL_TITLE}" --type feature --description "Masterplan: ${GOAL}" 2>/dev/null) || true
echo "Task ID: ${DOEY_TASK_ID:-none}"

case "${DOEY_TASK_ID:-}" in
  ''|*[!0-9]*)
    echo "ERROR: doey task create returned non-numeric id: '${DOEY_TASK_ID}'" >&2
    exit 1 ;;
esac

PLAN_CREATE_OUT="$(doey plan create --task-id "$DOEY_TASK_ID" --title "Masterplan: ${GOAL_TITLE}" --status draft 2>&1)" || {
  echo "ERROR: doey plan create failed: ${PLAN_CREATE_OUT}" >&2
  exit 1
}
PLAN_DB_ID="$(printf '%s\n' "$PLAN_CREATE_OUT" | awk '/^created plan /{print $3; exit}')"
case "${PLAN_DB_ID:-}" in
  ''|*[!0-9]*)
    echo "ERROR: could not parse numeric plan id from doey plan create output:" >&2
    printf '%s\n' "$PLAN_CREATE_OUT" >&2
    exit 1 ;;
esac

PLAN_ID="$PLAN_DB_ID"
PLAN_FILE="${PLANS_DIR}/${PLAN_ID}.md"
BRIEF_FILE="${PLANS_DIR}/${PLAN_ID}.brief.md"
echo "Plan ID (numeric): ${PLAN_ID}"

tmux set-environment -t "$SESSION_NAME" DOEY_TASK_ID "${DOEY_TASK_ID}" 2>/dev/null || true
tmux set-environment -t "$SESSION_NAME" PLAN_DB_ID "$PLAN_DB_ID" 2>/dev/null || true
tmux set-environment -t "$SESSION_NAME" PLAN_ID "$PLAN_ID" 2>/dev/null || true

cat > "${MP_DIR}/masterplan.env" << ENV_EOF
PLAN_ID=${PLAN_ID}
PLAN_FILE=${PLAN_FILE}
GOAL_FILE=${MP_DIR}/goal.md
MP_DIR=${MP_DIR}
MP_NAME=${MP_NAME}
PLANS_DIR=${PLANS_DIR}
BRIEF_FILE=${BRIEF_FILE}
DOEY_TASK_ID=${DOEY_TASK_ID:-}
PLAN_DB_ID=${PLAN_DB_ID:-}
ENV_EOF
echo "Masterplan env written to ${MP_DIR}/masterplan.env"

# Write a valid frontmatter skeleton so the Plans tab TUI loader
# (tui/internal/store/migrate.go) accepts this plan on first scan —
# non-numeric plan_id / missing frontmatter causes the row to be dropped.
# The Planner MUST preserve this frontmatter block when it rewrites the file;
# see agents/doey-planner.md.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "${PLAN_FILE}" <<PLAN_EOF
---
plan_id: ${PLAN_ID}
task_id: ${DOEY_TASK_ID}
title: "${GOAL_TITLE}"
status: draft
created: ${NOW}
updated: ${NOW}
skill: doey-masterplan
---

# ${GOAL_TITLE}

## Goal
${GOAL}

## Context
_(Planner will fill this in.)_

## Phases
_(Planner will populate.)_

## Deliverables
_(Planner will populate.)_

## Risks
_(Planner will populate.)_

## Success Criteria
_(Planner will populate.)_
PLAN_EOF
echo "Plan file skeleton written at ${PLAN_FILE}"
```

### Step 3.5 — Spawn masterplan team window immediately (always, before interview)

The masterplan team window hosts the Go TUI plan viewer (top-right pane). Spawn it
now so the pane is visible from the moment the user invokes /doey-masterplan. The
Planner will display "Waiting for brief…" until the interview completes.

```bash
# doey-masterplan-spawn.sh takes the MP_DIR basename as its argument (not the
# numeric PLAN_ID): it resolves MP_DIR=${RD}/${MP_NAME}, then sources
# masterplan.env, which overrides PLAN_ID with the numeric value.
bash "$HOME/.local/bin/doey-masterplan-spawn.sh" "${MP_NAME}"

# Capture the newly created window index for later reference
MP_WIN="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index} #{window_name}' 2>/dev/null \
  | awk '$2=="masterplan"{w=$1} END{print w}')"
echo "Masterplan window: ${MP_WIN:-none}"
```

### Step 4A: Interview-First Path (default, when RUN_INTERVIEW=1)

Spawn the Deep Interview team window and brief the Interviewer to:
1. Write the brief to the masterplan-specific location (`${BRIEF_FILE}`), not the default interview location.
2. After Phase 5 (brief approved by user), send a `brief_ready` message to the already-live masterplan Planner (spawned in Step 3.5) pointing at the brief file. Do NOT call `doey-masterplan-spawn.sh` — the window is already up.

Skip this entire section if `RUN_INTERVIEW=0` — jump to Step 4B.

```bash
if [ "$RUN_INTERVIEW" = "1" ]; then
  INTERVIEW_DIR="${MP_DIR}/interview"
  mkdir -p "${INTERVIEW_DIR}/research"
  cp "${MP_DIR}/goal.md" "${INTERVIEW_DIR}/goal.md"

  tmux set-environment -t "$SESSION_NAME" DOEY_INTERVIEW_DIR "$INTERVIEW_DIR" 2>/dev/null || true
  tmux set-environment -t "$SESSION_NAME" DOEY_INTERVIEW_ID  "${PLAN_ID}-interview" 2>/dev/null || true
  tmux set-environment -t "$SESSION_NAME" DOEY_MASTERPLAN_PENDING "$PLAN_ID" 2>/dev/null || true

  echo "Spawning interview window..."
  doey add-team interview || { echo "ERROR: doey add-team interview failed"; exit 1; }

  IV_WIN=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index} #{window_name}' 2>/dev/null | grep -i interview | tail -1 | awk '{print $1}')
  if [ -z "$IV_WIN" ]; then
    echo "ERROR: interview window not found after add-team"
    exit 1
  fi
  echo "Interview window: ${IV_WIN}"

  sleep "${DOEY_MANAGER_BRIEF_DELAY:-8}"
  INTERVIEWER_PANE="${SESSION_NAME}:${IV_WIN}.0"
  source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true

  IV_BRIEFING="You have a new interview — this is a **masterplan pre-interview**. Your brief will become the Planner's primary input.

## Goal file
${INTERVIEW_DIR}/goal.md

## Interview directory
${INTERVIEW_DIR}

## Task ID
${DOEY_TASK_ID:-none}

## SPECIAL INSTRUCTIONS FOR MASTERPLAN PRE-INTERVIEW

1. Run the full 5-phase interview protocol from your agent definition.
2. Keep the live brief at \${DOEY_INTERVIEW_DIR}/brief.md updated as usual so the pane-2 viewer stays fresh.
3. **In Phase 5, after the user approves the final brief, copy it to the masterplan brief path:**

   cp \"\${DOEY_INTERVIEW_DIR}/brief.md\" \"${BRIEF_FILE}\"

4. **Then notify the already-live masterplan Planner that the brief is ready:**

   doey msg send --to ${SESSION_NAME}:${MP_WIN}.0 \\
                 --from ${INTERVIEWER_PANE} \\
                 --subject brief_ready \\
                 --body \"BRIEF_FILE: ${BRIEF_FILE}\"
   doey msg trigger --pane ${SESSION_NAME}:${MP_WIN}.0

   Do NOT call doey-masterplan-spawn.sh — the masterplan window was spawned at
   skill invocation and is already live at ${SESSION_NAME}:${MP_WIN}.

5. After notifying the Planner, notify the Taskmaster with subject \`interview_complete\` (your normal post-interview notification) and include:
   - MASTERPLAN_ID: ${PLAN_ID}
   - BRIEF: ${BRIEF_FILE}
   - MASTERPLAN_WINDOW: ${MP_WIN}
   - NEXT_STEP: Planner notified via brief_ready message

6. Begin with Phase 1: Intent Extraction. Use AskUserQuestion for all questions."

  doey_send_verified "$INTERVIEWER_PANE" "$IV_BRIEFING" && echo "Interviewer briefed" || echo "WARNING: Interviewer briefing delivery failed — will fall back to ${INTERVIEW_DIR}/goal.md"

  # Inform Taskmaster that a masterplan-pre-interview is in progress
  TASKMASTER_PANE=$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)
  TASKMASTER_PANE="${TASKMASTER_PANE:-1.0}"
  doey msg send --to "${SESSION_NAME}:${TASKMASTER_PANE}" --from "${DOEY_PANE_ID:-${SESSION_NAME}:0.1}" \
    --subject "masterplan_interview_spawned" \
    --body "MASTERPLAN_ID: ${PLAN_ID}
INTERVIEW_WIN: ${IV_WIN}
INTERVIEW_DIR: ${INTERVIEW_DIR}
GOAL: $(head -3 "${MP_DIR}/goal.md")

A masterplan-pre-interview is running in window ${IV_WIN}; the masterplan planning team is already live in window ${MP_WIN} with the Planner waiting for the brief. After the brief is approved, the Interviewer will notify the Planner via a brief_ready message." 2>/dev/null || true
  doey msg trigger --pane "${SESSION_NAME}:${TASKMASTER_PANE}" 2>/dev/null || true

  cat << REPORT_EOF
## Masterplan Interview Spawned

**Plan ID:** ${PLAN_ID}
**Task ID:** ${DOEY_TASK_ID:-none}
**Interview window:** ${IV_WIN}
**Masterplan window:** ${MP_WIN} (Planner waiting for brief)
**Goal file:** ${MP_DIR}/goal.md
**Brief target:** ${BRIEF_FILE} (will be written by Interviewer)
**Masterplan env:** ${MP_DIR}/masterplan.env

The Deep Interviewer is running in window ${IV_WIN} and the masterplan Planner is already live in window ${MP_WIN} (waiting for the brief). Once the brief is approved, the Interviewer will notify the Planner via a \`brief_ready\` message and the plan will begin.

No further action from you — the flow is autonomous.
REPORT_EOF
  exit 0
fi
```

### Step 4B: Quick Path (when `--quick` or goal is already specific)

Skip the interview entirely — call the spawn helper directly. It loads `masterplan.env`, spawns the planning team, and briefs the Planner with just the goal (no brief file will exist, which the helper handles gracefully).

```bash
# Pass the MP_DIR basename (timestamp-named) — the helper resolves MP_DIR and
# then sources masterplan.env which sets PLAN_ID to the numeric DB id.
bash "$HOME/.local/bin/doey-masterplan-spawn.sh" "${MP_NAME}"
```

### Step 5: Report (quick mode only — interview mode reports in Step 4A)

```
## Masterplan Spawned (quick mode — no interview)

**Plan ID:** ${PLAN_ID}
**Task ID:** ${DOEY_TASK_ID:-none}
**Plan DB ID:** ${PLAN_DB_ID:-none}
**Goal file:** ${MP_DIR}/goal.md
**Plan file:** ${PLAN_FILE}

The Masterplanner team is running in its own window. The Planner will clarify scope inline (no upfront interview was performed).
```

### HARD GATE — Consensus Required Before Execution

**This skill, the spawn helper, and any downstream caller MUST NOT transition a
masterplan to execution/ready-for-dispatch until the consensus state machine
reports `CONSENSUS`.** The state machine is implemented in:

- `/home/doey/doey/shell/masterplan-consensus.sh` (helper library — sourceable)
- `/home/doey/doey/shell/masterplan-review-loop.sh` (review round orchestrator)

The state file lives at `${MP_DIR}/consensus.state` and is initialized by
`doey-masterplan-spawn.sh` via `consensus_init`. Valid states:
`DRAFT → UNDER_REVIEW → {CONSENSUS | REVISIONS_NEEDED} → UNDER_REVIEW …`,
with `ESCALATED` as an escape hatch from any state.

Before the plan can be handed to the Taskmaster for execution:

```bash
. /home/doey/doey/shell/masterplan-consensus.sh
STATE="$(consensus_state "${MP_DIR}")"
if [ "$STATE" != "CONSENSUS" ]; then
  echo "HARD GATE: plan ${PLAN_ID} is in state '${STATE}' — execution refused." >&2
  echo "Reviewer outputs (may or may not exist yet):" >&2
  echo "  ${MP_DIR}/${PLAN_ID}.architect.md" >&2
  echo "  ${MP_DIR}/${PLAN_ID}.critic.md" >&2
  echo "Run the Planner/Architect/Critic review loop until both reviewers APPROVE." >&2
  exit 1
fi
```

Do NOT bypass this check. Do NOT manually set `CONSENSUS_STATE=CONSENSUS`. The
only supported way to reach `CONSENSUS` is through `consensus_advance` after
both the Architect and Critic reviewers have returned `**Verdict:** APPROVE`.

### Rules
- Always use AskUserQuestion for user interaction — never inline questions
- The interview is mandatory by default. Only skip it when `--quick` is passed or the goal is already long and file-path-specific.
- The skill is a launcher — all planning logic lives in the Planner agent (masterplan team) and the Interviewer agent (interview team). Never run research or synthesis inline here.
- Use absolute paths only
- If any `doey add-team` call fails, report the error and stop — do NOT fall back to running planning inline.
- The handoff mechanism is `${MP_DIR}/masterplan.env` + `${BRIEF_FILE}` — written here, consumed by `doey-masterplan-spawn.sh` (which is called either by the Interviewer after Phase 5 or directly by this skill in quick mode).
- Works from any caller context (Boss, Taskmaster, or any agent)
