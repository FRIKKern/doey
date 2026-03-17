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
      # Watchdogs live in Dashboard (window 0), panes 0.2-0.7 only.
      # Skip scan entirely for non-Dashboard windows and non-Watchdog slots.
      if [ "$WINDOW_INDEX" = "0" ]; then
        case "$CURRENT_PANE" in
          2|3|4|5|6|7)
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

# Session Manager — allow everything (routes tasks to Window Managers via send-keys)
if is_session_manager; then
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
    *"send-keys"*|*"send-key"*|*"paste-buffer"*|*"load-buffer"*)
      # Block ALL send-keys to the Manager pane when Manager is crashed.
      # This prevents the Watchdog death-loop: Watchdog detects MANAGER_CRASHED,
      # sends keys to "notify" the dead Manager, killing any restart attempts.
      TEAM_WINDOW="${DOEY_TEAM_WINDOW:-}"
      if [ -n "$TEAM_WINDOW" ] && [ -n "${RUNTIME_DIR:-}" ]; then
        if [ -f "${RUNTIME_DIR}/status/manager_crashed_W${TEAM_WINDOW}" ]; then
          # Check if the command targets the Manager pane (W.0)
          # Anchor with ":" prefix to prevent false-positives on multi-digit
          # windows (e.g. TEAM_WINDOW=2 must not match "12.0")
          case "$TOOL_COMMAND" in
            *":${TEAM_WINDOW}.0"*)
              echo "BLOCKED: Watchdog cannot send keys to crashed Manager pane ${TEAM_WINDOW}.0." >&2
              echo "Write an alert file for the Session Manager instead." >&2
              exit 2
              ;;
          esac
        fi
      fi
      # Allow specific watchdog operations with strict payload validation.
      # Strip trailing stderr redirect for cleaner matching.
      CLEAN_CMD=$(echo "$TOOL_COMMAND" | sed 's/[[:space:]]*2>\/dev\/null[[:space:]]*$//')
      # Target pane pattern: quoted ("...") or unquoted token
      _TP='(\"[^\"]*\"|[^[:space:]]+)'
      # Pattern 1: Slash commands — target + exactly one allowed command + Enter
      if echo "$CLEAN_CMD" | grep -qE "^[[:space:]]*tmux send-keys[[:space:]]+-t[[:space:]]+${_TP}[[:space:]]+\"?(/login|/compact)\"?[[:space:]]+Enter[[:space:]]*$"; then
        exit 0
      fi
      # Pattern 2: Bare Enter — target + Enter only (no text payload)
      if echo "$CLEAN_CMD" | grep -qE "^[[:space:]]*tmux send-keys[[:space:]]+-t[[:space:]]+${_TP}[[:space:]]+Enter[[:space:]]*$"; then
        exit 0
      fi
      # Pattern 3: Copy-mode — any copy-mode command
      if echo "$CLEAN_CMD" | grep -qE '^[[:space:]]*tmux copy-mode[[:space:]]'; then
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
