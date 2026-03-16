#!/usr/bin/env bash
# Claude Code hook: PreToolUse — blocks dangerous commands on worker panes.
# Hot path: runs before EVERY tool call. Must be fast.
set -euo pipefail

# Early exit: read stdin and check tool_name BEFORE any tmux IPC.
INPUT=$(cat)

# Extract tool_name cheaply
TOOL_NAME=""
if command -v jq >/dev/null 2>&1; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
fi
if [ -z "$TOOL_NAME" ]; then
  TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi

# Non-Bash tools: block Edit/Write/Agent/NotebookEdit for Watchdog, allow all else
if [ "$TOOL_NAME" != "Bash" ]; then
  case "$TOOL_NAME" in
    Edit|Write|Agent|NotebookEdit)
      # Cheap check: only do expensive init_hook if this MIGHT be the Watchdog.
      # Workers/Manager are the common case — skip them fast.
      RUNTIME_DIR=$(tmux show-environment -t "$TMUX_PANE" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
      WD_PANE=$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2-) || exit 0
      WD_PANE="${WD_PANE//\"/}"
      CURRENT_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{pane_index}' 2>/dev/null) || exit 0
      if [ "$CURRENT_PANE" = "$WD_PANE" ]; then
        echo "BLOCKED: Watchdog cannot use $TOOL_NAME — monitoring role only." >&2
        exit 2
      fi
      ;;
  esac
  exit 0
fi

# Now do the heavier init only for Bash tool calls.
source "$(dirname "$0")/common.sh"
init_hook <<< "$INPUT"

# Manager — allow everything
if is_manager; then
  exit 0
fi

# Extract command (needed for both Watchdog filtering and Worker blocking)
if command -v jq >/dev/null 2>&1; then
  TOOL_COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || TOOL_COMMAND=""
else
  TOOL_COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"command"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi

[ -z "$TOOL_COMMAND" ] && exit 0

# Watchdog — allow everything EXCEPT sending keystrokes to worker panes.
# Workers run --dangerously-skip-permissions and never show interactive prompts,
# so there are no prompts to accept, and sending "y" causes y-spam when Haiku hallucinates prompts.
if is_watchdog; then
  case "$TOOL_COMMAND" in
    *"send-keys"*|*"send-key"*|*"paste-buffer"*)
      # Allow specific watchdog operations by matching complete tmux patterns.
      # Only permit: sending /doey-inbox, /login, /compact, bare Enter, and copy-mode.
      # Match command structure to prevent allowlist bypass via string containment
      # (e.g. "echo doey-inbox; malicious" would pass a simple substring check).
      if echo "$TOOL_COMMAND" | grep -qE '^[[:space:]]*tmux (send-keys .+ (/doey-inbox|/login|/compact|Enter)( Enter)?( |$)|copy-mode )'; then
        exit 0
      fi
      echo "BLOCKED: Watchdog cannot send keystrokes to worker panes." >&2
      echo "Workers use --dangerously-skip-permissions and have no interactive prompts." >&2
      echo "Report stuck workers to the Manager instead." >&2
      exit 2
      ;;
  esac
  # Fall through to destructive-command checks below
fi

# Check blocked patterns for Workers and Watchdog using case statement (no subshells per pattern)
ROLE="Workers"
is_watchdog && ROLE="Watchdog"

case "$TOOL_COMMAND" in
  *"git push"*|*"git commit"*|*"gh pr create"*|*"gh pr merge"*)
    MSG="git/gh commands" ;;
  *"rm -rf /"*|*"rm -rf ~"*|*'rm -rf $HOME'*)
    MSG="destructive rm" ;;
  *"shutdown"*|*"reboot"*)
    MSG="system commands" ;;
  *"tmux kill-session"*|*"tmux kill-server"*|*"tmux send-keys"*)
    MSG="tmux commands" ;;
  *)
    exit 0 ;;
esac

echo "BLOCKED: ${ROLE} cannot run ${MSG}. Only the Manager can do this." >&2
echo "If you need this operation, finish your task and let the Manager handle it." >&2
exit 2
