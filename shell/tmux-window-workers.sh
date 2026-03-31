#!/usr/bin/env bash
set -uo pipefail
# Per-window worker dot indicator for tmux window tabs.
# Called from window-status-format via #(script #I).
# Outputs: #[fg=color]●●○  (colored dots per worker status)
# Must be FAST (<10ms) — single awk pass, no loops.

WIN="${1:-}"
[ -z "$WIN" ] && exit 0
[ "$WIN" = "0" ] && exit 0  # window 0 is dashboard, no workers

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
[ -z "$RUNTIME_DIR" ] && exit 0

SESSION_NAME=$(tmux display-message -p '#{session_name}' 2>/dev/null) || true
[ -z "$SESSION_NAME" ] && exit 0

# Status files: ${session_safe}_${W}_${P}.status — skip pane 0 (manager)
SESSION_SAFE="${SESSION_NAME//-/_}"
STATUS_DIR="$RUNTIME_DIR/status"
[ -d "$STATUS_DIR" ] || exit 0

# Single awk pass: read all status files for this window (panes 1+),
# count BUSY vs total, then output colored dots.
# shellcheck disable=SC2012
awk -v win="$WIN" -v prefix="$SESSION_SAFE" '
BEGIN { busy = 0; total = 0 }
/^STATUS:/ {
  total++
  if ($2 == "BUSY" || $2 == "WORKING") busy++
}
END {
  if (total == 0) exit
  dots = ""
  for (i = 1; i <= total; i++) {
    if (i <= busy) dots = dots "●"
    else           dots = dots "○"
  }
  if (busy == total)    color = "green"
  else if (busy > 0)    color = "yellow"
  else                  color = "colour240"
  printf "#[fg=%s]%s", color, dots
}
' "$STATUS_DIR/${SESSION_SAFE}_${WIN}_"[123456789]*.status 2>/dev/null
