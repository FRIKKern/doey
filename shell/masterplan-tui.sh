#!/usr/bin/env bash
# Masterplan TUI — launches doey-masterplan-tui for the masterplan pane.
# Replaces masterplan-viewer.sh (bash file watcher) with the Go TUI.
set -euo pipefail

# 1. Resolve runtime directory
RD="${DOEY_RUNTIME:-}"
if [ -z "$RD" ]; then
  RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
fi
RD="${RD:-/tmp/doey}"

# 2. Find plan file
PLAN_FILE="${PLAN_FILE:-}"
if [ -z "$PLAN_FILE" ]; then
  shopt -s nullglob
  plans=("$RD"/masterplan-*/plan.md)
  shopt -u nullglob
  if [ ${#plans[@]} -gt 0 ]; then
    # Take the newest by modification time
    PLAN_FILE="${plans[0]}"
    for f in "${plans[@]}"; do
      if [ "$f" -nt "$PLAN_FILE" ]; then
        PLAN_FILE="$f"
      fi
    done
  fi
fi

# 3. Find goal text
GOAL=""
if [ -n "$PLAN_FILE" ]; then
  goal_file="${PLAN_FILE%/*}/goal.md"
  if [ -f "$goal_file" ]; then
    GOAL=$(cat "$goal_file")
  fi
fi

# 4. Get team window index
TEAM_WINDOW="${DOEY_TEAM_WINDOW:-${DOEY_WINDOW_INDEX:-0}}"

# 5. Launch the masterplan TUI
exec doey-masterplan-tui \
  --plan-file "$PLAN_FILE" \
  --runtime-dir "$RD" \
  --goal "$GOAL" \
  --team-window "$TEAM_WINDOW"
