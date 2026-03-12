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

# Only Bash commands need guarding — allow everything else immediately
[ "$TOOL_NAME" != "Bash" ] && exit 0

# Now do the heavier init only for Bash tool calls.
# Source common.sh for helper functions but skip init_hook (we already read stdin).
source "$(dirname "$0")/common.sh"

# Lightweight init: skip stdin read and redundant tmux validation
[ -z "${TMUX_PANE:-}" ] && exit 0
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_SAFE=${PANE//[:.]/_}
SESSION_NAME="${PANE%%:*}"
PANE_INDEX="${PANE##*.}"

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
# so auto-accept "y" is never needed and causes y-spam when Haiku hallucinates prompts.
if is_watchdog; then
  case "$TOOL_COMMAND" in
    *"send-keys"*|*"send-key"*|*"paste-buffer"*)
      # Allow safe commands: inbox delivery, login, copy-mode control
      if echo "$TOOL_COMMAND" | grep -qE '(doey-inbox|/login|/compact|copy-mode)'; then
        exit 0
      fi
      echo "BLOCKED: Watchdog cannot send keystrokes to worker panes." >&2
      echo "Workers use --dangerously-skip-permissions and never need auto-accept." >&2
      echo "Report stuck workers to the Manager instead." >&2
      exit 2
      ;;
  esac
  exit 0
fi

# Check blocked patterns for Workers using case statement (no subshells per pattern)
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

echo "BLOCKED: Workers cannot run ${MSG}. Only the Manager can do this." >&2
echo "If you need this operation, finish your task and let the Manager handle it." >&2
exit 2
