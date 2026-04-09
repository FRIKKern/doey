---
name: doey-respawn-me
description: Restart this Claude instance with fresh context. Use when you need to "respawn me", "restart myself", "fresh context", or "reset my pane". Kills the current Claude process and relaunches in the same tmux pane.
---

# doey-respawn-me

Run all of the following as a **single** Bash tool call. If any step fails, report the error and stop.

```bash
# ── 1. Derive pane identity from tmux (no env vars needed) ──
SESSION=$(tmux display-message -p '#{session_name}')
WINDOW=$(tmux display-message -p '#{window_index}')
PANE_IDX=$(tmux display-message -p '#{pane_index}')
PANE_TARGET="${SESSION}:${WINDOW}.${PANE_IDX}"

# ── 2. Compute safe name and runtime dir ──
SAFE=$(printf '%s_%s_%s' "$SESSION" "$WINDOW" "$PANE_IDX" | tr ':-.' '___')
RUNTIME_DIR="${DOEY_RUNTIME:-}"
if [ -z "$RUNTIME_DIR" ]; then
  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | sed 's/^DOEY_RUNTIME=//')
fi
if [ -z "$RUNTIME_DIR" ]; then
  RUNTIME_DIR="/tmp/doey/${SESSION#doey-}"
fi

# ── 3. Read launch command ──
LAUNCH_FILE="${RUNTIME_DIR}/status/${SAFE}.launch_cmd"
if [ -f "$LAUNCH_FILE" ]; then
  LAUNCH_CMD=$(cat "$LAUNCH_FILE")
else
  LAUNCH_CMD='claude --dangerously-skip-permissions'
fi

# ── 4. Write respawn script that runs after Claude exits ──
RESPAWN_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/doey_respawn_XXXXXX.sh")
cat > "$RESPAWN_SCRIPT" <<'INNER_EOF'
#!/usr/bin/env bash
set -euo pipefail
PANE_TARGET="$1"; shift
LAUNCH_CMD="$*"
sleep 2
tmux send-keys -t "$PANE_TARGET" "$LAUNCH_CMD" Enter
rm -f "$0"
INNER_EOF
chmod +x "$RESPAWN_SCRIPT"

# ── 5. Launch respawn in background ──
nohup bash "$RESPAWN_SCRIPT" "$PANE_TARGET" "$LAUNCH_CMD" >/dev/null 2>&1 &
echo "Respawn scheduled for ${PANE_TARGET} — exiting now."
```

After the bash command succeeds, **immediately run `/exit`** to quit Claude. The background script will relaunch this pane in ~2 seconds.
