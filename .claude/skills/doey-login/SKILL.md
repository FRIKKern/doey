---
name: doey-login
description: Fix auth across Doey sessions. Checks Keychain token — if valid, restarts instances immediately. If expired, prompts for one /login then restarts. Use when you need to "login", "fix auth", "not logged in", or "refresh authentication".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- All sessions: !`tmux list-sessions -F '#{session_name} #{session_windows}w' 2>/dev/null | grep doey || true`

Usage: `/doey-login` (ask scope) | `session` (default) | `all` | `team N`

### 1. Parse → set TARGET_SCOPE (`session`|`all`|window number)

### 2. Check token validity

```bash
CRED=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
echo "$CRED" | python3 -c "
import json, sys, datetime
d = json.load(sys.stdin)
oauth = d.get('claudeAiOauth', {})
exp = oauth.get('expiresAt', 0)
exp_dt = datetime.datetime.fromtimestamp(exp/1000 if exp > 1e12 else exp)
now = datetime.datetime.now()
remaining = exp_dt - now
print(f'Expires: {exp_dt}  Remaining: {remaining}  Valid: {now < exp_dt}')
print(f'Tier: {oauth.get(\"rateLimitTier\", \"unknown\")}')
print('ACTION: restart_only' if now < exp_dt and remaining >= datetime.timedelta(hours=1) else 'ACTION: needs_login')
" 2>/dev/null
```

`restart_only` → Step 3. `needs_login` → tell user to `/login`, wait, re-check.

### 3. Restart (never 0.0 or current pane)

```bash
kill_and_relaunch() {
  local PANE="$1" CMD="$2" SHELL_PID CHILD_PID
  SHELL_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}' 2>/dev/null || true)
  [ -z "$SHELL_PID" ] && return 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null || true; sleep 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && { kill -9 "$CHILD_PID" 2>/dev/null || true; sleep 0.5; }
  tmux copy-mode -q -t "$PANE" 2>/dev/null || true
  tmux send-keys -t "$PANE" Escape 2>/dev/null || true
  tmux send-keys -t "$PANE" "clear" Enter 2>/dev/null || true; sleep 0.5
  tmux send-keys -t "$PANE" "$CMD" Enter; sleep 0.5
}

restart_team() {
  local SESS="$1" RT="$2" W="$3" SKIP_PANE="$4"
  local TEAM_ENV="${RT}/team_${W}.env"
  [ ! -f "$TEAM_ENV" ] && { echo "WARNING: team_${W}.env not found"; return; }
  local WORKER_PANES=$(grep '^WORKER_PANES=' "$TEAM_ENV" | cut -d= -f2 | tr -d '"')
  echo "=== Team $W ==="
  [ "${SESS}:${W}.0" != "$SKIP_PANE" ] && {
    kill_and_relaunch "${SESS}:${W}.0" "claude --dangerously-skip-permissions --model opus --name \"T${W} Subtaskmaster\" --agent \"t${W}-manager\""
    echo "  ${W}.0 Subtaskmaster ✓"; }
  for wp in $(echo "$WORKER_PANES" | tr ',' ' '); do
    local PANE="${SESS}:${W}.${wp}" PANE_SAFE=$(echo "${SESS}:${W}.${wp}" | tr ':-.' '_')
    [ "$PANE" = "$SKIP_PANE" ] && continue
    [ -f "${RT}/status/${PANE_SAFE}.reserved" ] && { echo "  ${W}.${wp} — reserved"; continue; }
    local W_NAME=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null || echo "T${W} W${wp}")
    local WORKER_PROMPT=$(grep -rl "pane ${W}\.${wp} " "${RT}"/worker-system-prompt-*.md 2>/dev/null | head -1 || true)
    local CMD="claude --dangerously-skip-permissions --model opus --name \"${W_NAME}\""
    [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
    kill_and_relaunch "$PANE" "$CMD"
    doey status set --pane "$PANE" --status READY --task "login-restart"
    echo "  ${W}.${wp} ✓"
  done
}
```

### Apply scope

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION_NAME=$(grep '^SESSION_NAME=' "${RD}/session.env" | cut -d= -f2 | tr -d '"')
TASKMASTER_PANE=$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)
MY_PANE="${SESSION_NAME}:${TASKMASTER_PANE:-0.2}"
TEAM_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RD}/session.env" | cut -d= -f2 | tr -d '"')
case "$TARGET_SCOPE" in
[0-9]|[0-9][0-9]) restart_team "$SESSION_NAME" "$RD" "$TARGET_SCOPE" "$MY_PANE" ;;
session) for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do restart_team "$SESSION_NAME" "$RD" "$W" "$MY_PANE"; done ;;
all)
  for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do restart_team "$SESSION_NAME" "$RD" "$W" "$MY_PANE"; done
  for OTHER in $(tmux list-sessions -F '#{session_name}' | grep '^doey-' | grep -v "$SESSION_NAME"); do
    OTHER_RT=$(tmux show-environment -t "$OTHER" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
    [ -z "$OTHER_RT" ] && continue
    for W in $(grep '^TEAM_WINDOWS=' "${OTHER_RT}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr ',' ' '); do
      restart_team "$OTHER" "$OTHER_RT" "$W" ""
    done
  done ;;
esac
```

Report: token status, scope, counts. Never restart current pane or 0.0. Skip reserved.
