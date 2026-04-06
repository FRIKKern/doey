#!/usr/bin/env bash
# Masterplan TUI — launches doey-tui for the masterplan pane.
# Replaces masterplan-viewer.sh (bash file watcher) with the Go TUI.
# Argument from team handler: $1 = PLAN_FILE (ignored — TUI discovers plans from runtime dir)
set -euo pipefail
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
exec doey-tui "${RD:-/tmp/doey}"
