#!/usr/bin/env bash
# shell/trust-watcher.sh — Watches Doey panes for Claude Code's "trust this folder"
# dialog and sends Enter to accept the default. Background daemon, one per session.
#
# Inputs: env DOEY_RUNTIME (or arg --runtime), env SESSION_NAME (or arg --session).
# Lifetime: exits when session or runtime dir disappears.
#
# The dialog text is fixed: grep for 'Quick safety check: Is this a project you
# created' — strongest single-pattern match, zero false positives.

set -euo pipefail

RUNTIME_DIR="${DOEY_RUNTIME:-}"
SESSION="${SESSION_NAME:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime) RUNTIME_DIR="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --runtime=*) RUNTIME_DIR="${1#*=}"; shift ;;
    --session=*) SESSION="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

if [ -z "$SESSION" ] && [ -n "$RUNTIME_DIR" ] && [ -f "${RUNTIME_DIR}/session.env" ]; then
  # shellcheck disable=SC1091
  . "${RUNTIME_DIR}/session.env"
  SESSION="${SESSION_NAME:-$SESSION}"
fi

if [ -z "$RUNTIME_DIR" ] || [ -z "$SESSION" ]; then
  echo "trust-watcher: missing RUNTIME_DIR or SESSION" >&2
  exit 2
fi

STATUS_DIR="${RUNTIME_DIR}/status"
LOG_FILE="${RUNTIME_DIR}/logs/trust-watcher.log"
mkdir -p "${RUNTIME_DIR}/logs" "$STATUS_DIR" 2>/dev/null || true

SIGNATURE='Quick safety check: Is this a project you created'

SKIP_ROLES='info_panel doey-term'

POLL_INTERVAL="${DOEY_TRUST_POLL_INTERVAL:-1}"
PANE_TTL="${DOEY_TRUST_PANE_TTL:-60}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

decode_target() {
  local base="$1"
  local session_safe
  session_safe=$(printf '%s' "$SESSION" | tr ':.-' '_')
  case "$base" in
    "${session_safe}_"*)
      local rest="${base#${session_safe}_}"
      local win="${rest%_*}"
      local pane="${rest##*_}"
      printf '%s:%s.%s\n' "$SESSION" "$win" "$pane"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

role_skipped() {
  local role="$1"
  local r
  for r in $SKIP_ROLES; do
    if [ "$role" = "$r" ]; then return 0; fi
  done
  return 1
}

log "trust-watcher starting (session=$SESSION runtime=$RUNTIME_DIR pid=$$)"

_shutdown() {
  log "trust-watcher exiting (signal)"
  exit 0
}
trap _shutdown TERM INT

while :; do
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "session gone, exiting"
    exit 0
  fi
  if [ ! -d "$RUNTIME_DIR" ]; then
    log "runtime dir gone, exiting"
    exit 0
  fi

  shopt -s nullglob
  for rf in "${STATUS_DIR}"/*.role; do
    base="${rf##*/}"; base="${base%.role}"
    done_marker="${STATUS_DIR}/${base}.trust_done"
    [ -f "$done_marker" ] && continue

    role=$(head -n1 "$rf" 2>/dev/null || true)
    if [ -z "$role" ]; then continue; fi
    if role_skipped "$role"; then
      : > "$done_marker"
      continue
    fi

    target=$(decode_target "$base") || continue

    first_seen="${STATUS_DIR}/${base}.trust_first_seen"
    if [ ! -f "$first_seen" ]; then
      date '+%s' > "$first_seen"
    fi
    seen_at=$(cat "$first_seen" 2>/dev/null || echo "0")
    now=$(date '+%s')
    if [ $((now - seen_at)) -gt "$PANE_TTL" ]; then
      log "pane $target TTL expired, stop watching"
      : > "$done_marker"
      continue
    fi

    cap=$(tmux capture-pane -p -S -15 -t "$target" 2>/dev/null || true)
    if [ -n "$cap" ] && printf '%s' "$cap" | grep -qF "$SIGNATURE"; then
      log "trust dialog detected on $target — sending Enter"
      tmux send-keys -t "$target" C-m 2>/dev/null || true
      sleep 0.5
      cap2=$(tmux capture-pane -p -S -15 -t "$target" 2>/dev/null || true)
      if ! printf '%s' "$cap2" | grep -qF "$SIGNATURE"; then
        log "pane $target: dialog cleared after Enter"
      else
        log "pane $target: dialog still present, re-sending Enter"
        tmux send-keys -t "$target" C-m 2>/dev/null || true
      fi
      : > "$done_marker"
    fi
  done

  sleep "$POLL_INTERVAL"
done
