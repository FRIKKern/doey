---
name: doey-monitor
description: On-demand snapshot of worker pane state — status files (FINISHED, BUSY, ERROR, READY, RESERVED), reservations, results, crashes. Use ONLY when you explicitly need a one-shot picture of the team. Never use as a background watch loop.
---

# EXPLICIT INVOCATION ONLY — NOT A POLLING LOOP

This skill produces a **one-shot snapshot** of worker state. It is invoked on demand, not run in a loop.

The reactive Subtaskmaster model assumes you are **blocking on `taskmaster-wait.sh`** (see "Wake mechanism" below) and only read team state when something specific triggers you: a worker_finished message, a FINISHED status write, a router dispatch, or a user request. Repeatedly running this skill to "check in" burns context and defeats the reactive design.

## When to use
- A user/Taskmaster explicitly asks "what's the team doing right now?"
- You just woke from `taskmaster-wait.sh` with `WAKE_REASON=MSG|TRIGGERED|FINISHED` and need the full picture to decide next step
- You are debugging a reported anomaly (crash, stuck worker, unexpected status)

## When NOT to use
- As a periodic poll in a loop — **the hooks push wake events to you; don't pull**
- "Just to see if anything changed" — if nothing woke you, nothing changed
- Inside a `while true` / `for i in seq` / scheduled re-check — that is polling, not reactive

## Wake mechanism (read this first)
Subtaskmasters block on `~/.claude/hooks/taskmaster-wait.sh` (passive role fast path). Triggers that wake you:
- A `.msg` file written to `${DOEY_RUNTIME}/messages/${your_pane_safe}_*.msg` (e.g. `worker_finished` from `stop-notify.sh`)
- A trigger file touched at `${DOEY_RUNTIME}/triggers/${your_pane_safe}.trigger`
- `inotifywait` create/modify on `messages/` or `triggers/` directories

When the wait hook exits, it prints `WAKE_REASON=MSG|TRIGGERED|TIMEOUT`. Only then should you consider invoking this skill to gather context for the specific event.

## Snapshot
- Statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.status; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f"; done 2>/dev/null || true`
- Reservations: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename $f .reserved)"; done 2>/dev/null || true`
- Results: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; for f in "$RD"/results/pane_${W}_*.json; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f"; done 2>/dev/null || true`
- Crashes: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/crash_pane_*; do [ -f "$f" ] && echo "CRASH:" && cat "$f"; done 2>/dev/null || true`
- Titles: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); W="${DOEY_WINDOW_INDEX:-0}"; for p in $(tmux list-panes -t "$SESSION:$W" -F '#{pane_index}' 2>/dev/null); do echo "$W.$p: $(tmux display-message -t "$SESSION:$W.$p" -p '#{pane_title}' 2>/dev/null)"; done || true`

Table: `PANE | STATUS | RESERVED | TASK | UPDATED`. Enrich FINISHED from `.json`. Task from pane title.

## Deep inspect (single pane, on demand)
```bash
PANE="${SESSION_NAME}:${DOEY_WINDOW_INDEX:-0}.X"; PANE_SAFE=$(echo "$PANE" | tr ':.-' '_')
cat "${DOEY_RUNTIME}/status/${PANE_SAFE}.status" 2>/dev/null || echo "(no status)"
tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || echo "(not found)"
```

## Error recovery (only when a wake event reported a problem)
- **Unstick (READY/FINISHED only):** copy-mode -q → C-c (0.5s) → C-u (0.5s) → Enter (3s) → check ❯. 2 fails → `/doey-dispatch` Unstick
- **Nudge idle:** copy-mode -q → Enter (5s) → grep activity → unstick/re-dispatch

**Kill protection:** NEVER kill or unstick a BUSY worker. A worker can appear idle while thinking or processing tool results. Before any kill/restart, follow the Worker Kill Protection protocol: 2-3 checks 30+ seconds apart with identical pane content, no worker_finished message, status not FINISHED/RESERVED. Status from files only. Min 15s poll between checks — and only after a wake event flagged the worker suspicious, never as part of a default watch loop.
