---
name: doey-login
description: Fix auth across Doey sessions. Checks Keychain token — if valid, restarts instances immediately. If expired, prompts for one /login then restarts. Use when you need to "login", "fix auth", "not logged in", or "refresh authentication".
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- All sessions: !`tmux list-sessions -F '#{session_name} #{session_windows}w' 2>/dev/null | grep doey || true`
- Window index: !`echo "${DOEY_WINDOW_INDEX:-0}"`

## Usage

`/doey-login` — interactive (ask scope)
`/doey-login session` — current session only (default)
`/doey-login all` — all doey sessions
`/doey-login team N` — specific team window only

## Step 1: Parse arguments

No args → ask (default: this session). Set **TARGET_SCOPE** to `session`, `all`, or a window number.

## Step 2: Check token validity

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
print(f'Expires: {exp_dt}')
print(f'Remaining: {remaining}')
valid = now < exp_dt
print(f'Valid: {valid}')
print(f'Tier: {oauth.get(\"rateLimitTier\", \"unknown\")}')
if not valid:
    print('ACTION: needs_login')
elif remaining < datetime.timedelta(hours=1):
    print('ACTION: needs_login')
else:
    print('ACTION: restart_only')
" 2>/dev/null
```

**If `restart_only`:** proceed to Step 3.
**If `needs_login`:** tell user to run `/login`, wait for confirmation, re-check, then proceed.

## Step 3: Restart instances

Restart based on TARGET_SCOPE. Never restart Info Panel (0.0) or the current pane.

### Helper

```bash
kill_and_relaunch() {
  local PANE="$1" CMD="$2"
  local SHELL_PID CHILD_PID
  SHELL_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}' 2>/dev/null || true)
  [ -z "$SHELL_PID" ] && return 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null || true; sleep 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && { kill -9 "$CHILD_PID" 2>/dev/null || true; sleep 0.5; }
  tmux copy-mode -q -t "$PANE" 2>/dev/null || true
  tmux send-keys -t "$PANE" "clear" Enter 2>/dev/null || true; sleep 0.5
  tmux send-keys -t "$PANE" "$CMD" Enter; sleep 0.5
}
```

### restart_team function

```bash
restart_team() {
  local SESS="$1" RT="$2" W="$3" SKIP_PANE="$4"
  local TEAM_ENV="${RT}/team_${W}.env"
  [ ! -f "$TEAM_ENV" ] && { echo "WARNING: team_${W}.env not found"; return; }
  local WORKER_PANES=$(grep '^WORKER_PANES=' "$TEAM_ENV" | cut -d= -f2 | tr -d '"')
  echo "=== Team $W ==="

  [ "${SESS}:${W}.0" != "$SKIP_PANE" ] && {
    kill_and_relaunch "${SESS}:${W}.0" "claude --dangerously-skip-permissions --model opus --name \"T${W} Window Manager\" --agent \"t${W}-manager\""
    echo "  ${W}.0 Manager ✓"; }

  for wp in $(echo "$WORKER_PANES" | tr ',' ' '); do
    local PANE="${SESS}:${W}.${wp}" PANE_SAFE=$(echo "${SESS}:${W}.${wp}" | tr ':-.' '_')
    [ "$PANE" = "$SKIP_PANE" ] && continue
    [ -f "${RT}/status/${PANE_SAFE}.reserved" ] && { echo "  ${W}.${wp} — reserved"; continue; }
    local W_NAME=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null || echo "T${W} W${wp}")
    local WORKER_PROMPT=$(grep -rl "pane ${W}\.${wp} " "${RT}"/worker-system-prompt-*.md 2>/dev/null | head -1 || true)
    local CMD="claude --dangerously-skip-permissions --model opus --name \"${W_NAME}\""
    [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
    kill_and_relaunch "$PANE" "$CMD"
    mkdir -p "${RT}/status"
    printf 'PANE: %s\nUPDATED: %s\nSTATUS: READY\nTASK: login-restart\n' "$PANE" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "${RT}/status/${PANE_SAFE}.status"
    echo "  ${W}.${wp} ✓"
  done
}
```

### Apply based on scope

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION_NAME=$(grep '^SESSION_NAME=' "${RUNTIME_DIR}/session.env" | cut -d= -f2 | tr -d '"')
MY_PANE="${SESSION_NAME}:0.2"  # SM pane (0.1 is Boss)
TEAM_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" | cut -d= -f2 | tr -d '"')

# Scope: team N — single team in current session
case "$TARGET_SCOPE" in
[0-9]|[0-9][0-9])
  restart_team "$SESSION_NAME" "$RUNTIME_DIR" "$TARGET_SCOPE" "$MY_PANE"
  ;;

# Scope: session — all teams in current session
session)
  for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
    restart_team "$SESSION_NAME" "$RUNTIME_DIR" "$W" "$MY_PANE"
  done
  ;;

# Scope: all — all doey sessions
all)
  for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
    restart_team "$SESSION_NAME" "$RUNTIME_DIR" "$W" "$MY_PANE"
  done
  for OTHER in $(tmux list-sessions -F '#{session_name}' | grep '^doey-' | grep -v "$SESSION_NAME"); do
    OTHER_RT=$(tmux show-environment -t "$OTHER" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
    [ -z "$OTHER_RT" ] && continue
    OTHER_TEAMS=$(grep '^TEAM_WINDOWS=' "${OTHER_RT}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
    for W in $(echo "$OTHER_TEAMS" | tr ',' ' '); do
      restart_team "$OTHER" "$OTHER_RT" "$W" ""
    done
  done
  ;;
esac
```

## Step 4: Report

Print: token status, scope, counts (restarted/skipped).

## Rules

- Never restart current pane or Info Panel (0.0). Skip reserved panes
- 0.5s between restarts. Valid token = skip /login. Default scope: session. Bash 3.2
