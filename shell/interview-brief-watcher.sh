#!/usr/bin/env bash
set -euo pipefail

# interview-brief-watcher.sh — Live brief viewer for Deep Interview
# Watches DOEY_INTERVIEW_DIR/brief.md and redisplays on change.
# Launched by add_team_from_def() via the "script" field in interview.team.md.

INTERVIEW_DIR="${DOEY_INTERVIEW_DIR:-}"
if [ -z "$INTERVIEW_DIR" ]; then
  # Fallback: find from runtime
  RD="${DOEY_RUNTIME:-/tmp/doey/${DOEY_PROJECT_NAME:-unknown}}"
  INTERVIEW_DIR=$(find "$RD" -maxdepth 2 -name "interview*" -type d 2>/dev/null | head -1)
fi

BRIEF_FILE="${INTERVIEW_DIR}/brief.md"
GOAL_FILE="${INTERVIEW_DIR}/goal.md"

# Display loop
while true; do
  clear
  echo "╔══════════════════════════════════════════════╗"
  echo "║        DEEP INTERVIEW — LIVE BRIEF          ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""

  if [ -f "$GOAL_FILE" ]; then
    echo "── GOAL ──────────────────────────────────────"
    cat "$GOAL_FILE"
    echo ""
    echo "──────────────────────────────────────────────"
    echo ""
  fi

  if [ -f "$BRIEF_FILE" ]; then
    cat "$BRIEF_FILE"
  else
    echo "(Waiting for interview to begin...)"
    echo ""
    echo "The interviewer will update this brief as the"
    echo "interview progresses through each phase."
  fi

  # Watch for changes — use inotifywait if available, fall back to polling
  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -q -e modify,create "$INTERVIEW_DIR" 2>/dev/null || sleep 2
  else
    sleep 2
  fi
done
