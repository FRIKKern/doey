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
      # Workers/Window Manager are the common case — skip them fast.
      RUNTIME_DIR=$(tmux show-environment -t "$TMUX_PANE" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
      read WINDOW_INDEX CURRENT_PANE <<< "$(tmux display-message -t "$TMUX_PANE" -p '#{window_index} #{pane_index}' 2>/dev/null)" || exit 0
      # Watchdogs live in Dashboard (window 0), panes 0.1-0.3 only.
      # Skip scan entirely for non-Dashboard windows and non-Watchdog slots.
      if [ "$WINDOW_INDEX" = "0" ]; then
        case "$CURRENT_PANE" in
          1|2|3)
            # Could be a Watchdog — scan team envs to confirm
            for _pt_tf in "${RUNTIME_DIR}"/team_*.env; do
              [ -f "$_pt_tf" ] || continue
              _pt_wd=$(grep '^WATCHDOG_PANE=' "$_pt_tf" | cut -d= -f2)
              _pt_wd="${_pt_wd//\"/}"
              if [ "$_pt_wd" = "0.${CURRENT_PANE}" ]; then
                echo "BLOCKED: Watchdog cannot use $TOOL_NAME — monitoring role only." >&2
                exit 2
              fi
            done
            ;;
        esac
      fi
      ;;
  esac
  exit 0
fi

# Now do the heavier init only for Bash tool calls.
source "$(dirname "$0")/common.sh"
init_hook <<< "$INPUT"

# Window Manager — allow everything
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
      if echo "$TOOL_COMMAND" | grep -qE '^[[:space:]]*tmux (send-keys .+ (/doey-inbox|/login|/compact|Enter)( Enter)?[[:space:]]*$|copy-mode .+$)'; then
        exit 0
      fi
      echo "BLOCKED: Watchdog cannot send keystrokes to worker panes." >&2
      echo "Workers use --dangerously-skip-permissions and have no interactive prompts." >&2
      echo "Report stuck workers to the Window Manager instead." >&2
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

echo "BLOCKED: ${ROLE} cannot run ${MSG}. Only the Window Manager can do this." >&2
echo "If you need this operation, finish your task and let the Window Manager handle it." >&2
exit 2
