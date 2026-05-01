#!/usr/bin/env bash
# silent-fail-detector.sh — Doey Phase-1 silent-failure detection daemon.
# Rules: R-1 (paste-no-submit), R-3 (UPDATED/heartbeat skew), R-11 (briefing-handoff loss),
#        R-14 (STM tight-loop on empty msg-read).
# Read-only against project state. Writes only $RUNTIME_DIR/findings/* and detector.log.
set -euo pipefail

DOEY_DETECTOR_TICK="${DOEY_DETECTOR_TICK:-30}"
RUNTIME_DIR="${RUNTIME_DIR:-${DOEY_RUNTIME_DIR:-/tmp/doey/doey}}"
DOEY_SESSION="${DOEY_SESSION:-doey-$(basename "$RUNTIME_DIR")}"

FINDINGS_DIR="$RUNTIME_DIR/findings"
LOG_FILE="$FINDINGS_DIR/detector.log"
PID_FILE="$RUNTIME_DIR/silent-fail-detector.pid"
DEDUP_WINDOW="${DOEY_DETECTOR_DEDUP_WINDOW:-60}"

DETECTOR_START_TS=""

ensure_dirs() {
  mkdir -p "$FINDINGS_DIR" 2>/dev/null || true
}

logmsg() {
  ensure_dirs
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

now_epoch() { date +%s; }

# Portable mtime — Linux first, macOS fallback.
file_mtime() {
  local f="$1"
  [ -e "$f" ] || { echo ""; return 0; }
  local m
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "")
  echo "$m"
}

# Portable string fingerprint via cksum.
fingerprint() {
  printf '%s|%s|%s' "$1" "$2" "$3" | cksum 2>/dev/null | awk '{print $1}'
}

# Inspect existing finding files matching this fingerprint; return 0 if any
# was written within DEDUP_WINDOW seconds (skip emission), 1 otherwise.
# File mtime is the source of truth — no separate state file, self-healing
# under daemon restarts and tick drift.
fp_within_window() {
  local rule="$1" fp="$2" now existing m latest age
  now=$(now_epoch)
  latest=0
  for existing in "$FINDINGS_DIR/${rule}-"*"-${fp}.json"; do
    [ -f "$existing" ] || continue
    m=$(file_mtime "$existing")
    [ -n "$m" ] || continue
    case "$m" in ''|*[!0-9]*) continue ;; esac
    if [ "$m" -gt "$latest" ]; then latest="$m"; fi
  done
  [ "$latest" -gt 0 ] || return 1
  age=$((now - latest))
  [ "$age" -le "$DEDUP_WINDOW" ] && return 0
  return 1
}

# JSON-escape a string for embedding in a single-line JSON value.
json_escape() {
  printf '%s' "$1" | awk 'BEGIN{ORS=""} { gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"\\r"); gsub(/\n/,"\\n"); print }'
}

emit_finding() {
  local rule="$1" pane="$2" evidence="$3" severity="$4"
  local fp ts file ev_esc
  fp=$(fingerprint "$rule" "$pane" "$evidence")
  ensure_dirs
  if fp_within_window "$rule" "$fp"; then return 0; fi
  ts=$(now_epoch)
  file="$FINDINGS_DIR/${rule}-${ts}-${fp}.json"
  ev_esc=$(json_escape "$evidence")
  printf '{"rule":"%s","pane":"%s","evidence":"%s","severity":"%s","ts":%s}\n' \
    "$rule" "$pane" "$ev_esc" "$severity" "$ts" > "$file"
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$file" >/dev/null 2>&1; then
      logmsg "WARN emit_finding produced invalid JSON; removing $file"
      rm -f "$file"
      return 0
    fi
  fi
  logmsg "FIRE $rule pane=$pane sev=$severity evidence=\"$evidence\""
}

# Convert safe form '2_1' to canonical 'W.P' '2.1'.
safe_to_pane() { printf '%s' "$1" | tr '_' '.'; }

# Read named field from a status file. Field format is 'KEY: value' or 'KEY:value'.
status_field() {
  local file="$1" key="$2"
  [ -f "$file" ] || { echo ""; return 0; }
  awk -v k="^${key}:" 'BEGIN{IGNORECASE=0} $0 ~ k { sub(k,""); sub(/^[ \t]+/,""); print; exit }' "$file"
}

# ────── R-1 paste-no-submit ──────
detect_r1() {
  local status_dir="$RUNTIME_DIR/status"
  [ -d "$status_dir" ] || return 0
  local panes_present=""
  if command -v tmux >/dev/null 2>&1; then
    panes_present=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "")
  fi
  local f base safe pane status updated mtime now mtime_age cap
  now=$(now_epoch)
  for f in "$status_dir"/*.status; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .status)
    case "$base" in
      [0-9]*_[0-9]*)
        # only canonical W_P safe-form filenames
        ;;
      *) continue ;;
    esac
    if ! printf '%s' "$base" | grep -Eq '^[0-9]+_[0-9]+$'; then continue; fi
    safe="$base"
    pane=$(safe_to_pane "$safe")
    status=$(status_field "$f" "STATUS")
    updated=$(status_field "$f" "UPDATED")
    mtime=$(file_mtime "$f")
    [ -n "$mtime" ] || continue
    mtime_age=$((now - mtime))

    [ "$status" = "RESERVED" ] && continue

    # Pane existence check (only if tmux gave us a list).
    if [ -n "$panes_present" ]; then
      if ! printf '%s\n' "$panes_present" | grep -Fxq "$DOEY_SESSION:$pane"; then
        continue
      fi
    fi

    # Capture last 10 lines.
    cap=$(tmux capture-pane -t "$DOEY_SESSION:$pane" -p -S -10 2>/dev/null || echo "")
    [ -n "$cap" ] || continue

    # Spinner glyphs present? skip.
    case "$cap" in
      *✻*|*●*|*⎿*) continue ;;
    esac

    # Paste marker?
    if ! printf '%s' "$cap" | grep -Eq '\[Pasted text #[0-9]+ \+[0-9]+ lines\]'; then
      continue
    fi

    # BUSY guards.
    if [ "$status" = "BUSY" ]; then
      [ "$mtime_age" -le 5 ] && continue
    fi
    if [ -n "$updated" ] && [ "$updated" -gt 0 ] 2>/dev/null; then
      if [ $((now - updated)) -lt 3 ] && [ "$status" = "BUSY" ]; then
        continue
      fi
    fi

    emit_finding "R-1" "$pane" "paste-no-submit @ $pane; status=${status:-unknown}" "P0"
  done
}

# ────── R-3 UPDATED vs heartbeat skew ──────
detect_r3() {
  local status_dir="$RUNTIME_DIR/status"
  [ -d "$status_dir" ] || return 0
  local f base safe pane status upd hb hb_file st_mtime spawn upd_age hb_age skew now
  now=$(now_epoch)
  for f in "$status_dir"/*.status; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .status)
    if ! printf '%s' "$base" | grep -Eq '^[0-9]+_[0-9]+$'; then continue; fi
    safe="$base"
    pane=$(safe_to_pane "$safe")
    status=$(status_field "$f" "STATUS")
    [ "$status" = "RESERVED" ] && continue
    case "$status" in
      READY|BUSY|IDLE|WAITING) ;;
      *) continue ;;
    esac

    upd=$(status_field "$f" "UPDATED")
    [ -n "$upd" ] || continue
    hb_file="$status_dir/${safe}.heartbeat"
    [ -f "$hb_file" ] || continue
    hb=$(file_mtime "$hb_file")
    [ -n "$hb" ] || continue
    st_mtime=$(file_mtime "$f")
    [ -n "$st_mtime" ] || continue

    # Spawn-grace: take earliest of status & heartbeat mtimes as spawn proxy.
    spawn="$st_mtime"
    if [ -n "$hb" ] && [ "$hb" -lt "$spawn" ] 2>/dev/null; then spawn="$hb"; fi
    [ $((now - spawn)) -lt 60 ] && continue

    upd_age=$((now - upd))
    hb_age=$((now - hb))
    if [ "$upd_age" -ge "$hb_age" ]; then skew=$((upd_age - hb_age)); else skew=$((hb_age - upd_age)); fi
    [ "$skew" -gt 120 ] || continue

    # bucket skew to 30s granularity for dedup stability
    local skew_b=$(( (skew / 30) * 30 ))
    emit_finding "R-3" "$pane" "skew_bucket=${skew_b}s (UPDATED ${upd_age}s, hb ${hb_age}s)" "P1"
  done
}

# ────── R-11 briefing-handoff loss ──────
detect_r11() {
  local results_dir="$RUNTIME_DIR/results"
  [ -d "$results_dir" ] || return 0
  local spawn_log="$RUNTIME_DIR/spawn.log"
  local f pane safe tool_calls last_text mtime now spawn_time delta
  now=$(now_epoch)
  for f in "$results_dir"/pane_*.json; do
    [ -f "$f" ] || continue
    mtime=$(file_mtime "$f")
    [ -n "$mtime" ] || continue
    [ $((now - mtime)) -le 300 ] || continue
    if [ -n "$DETECTOR_START_TS" ] && [ "$mtime" -lt "$DETECTOR_START_TS" ] 2>/dev/null; then
      continue
    fi
    if ! command -v jq >/dev/null 2>&1; then return 0; fi
    pane=$(jq -r '.pane // empty' "$f" 2>/dev/null || echo "")
    [ -n "$pane" ] || continue
    tool_calls=$(jq -r '.tool_calls // 0' "$f" 2>/dev/null || echo 0)
    last_text=$(jq -r '.last_output.text // .summary // empty' "$f" 2>/dev/null || echo "")

    # RESERVED guard via status file.
    safe=$(printf '%s' "$pane" | tr '.' '_')
    local st="$RUNTIME_DIR/status/${safe}.status"
    if [ -f "$st" ]; then
      local s
      s=$(status_field "$st" "STATUS")
      [ "$s" = "RESERVED" ] && continue
    fi

    spawn_time="$mtime"
    if [ -f "$spawn_log" ]; then
      local sp
      sp=$(awk -v p="$safe" '$1 == p { print $2 }' "$spawn_log" 2>/dev/null | tail -1)
      if [ -n "$sp" ]; then spawn_time="$sp"; fi
    fi
    delta=$((mtime - spawn_time))

    [ "$tool_calls" -eq 0 ] 2>/dev/null || continue
    [ "$delta" -lt 10 ] || continue
    printf '%s' "$last_text" | grep -Eq 'Claude Code v[0-9.]+' || continue

    emit_finding "R-11" "$pane" "buried-brief: stop ${delta}s post-spawn, 0 tool calls" "P0"
  done
}

# ────── R-14 STM tight-loop on empty msg-read ──────
# Backstop for task 665 (stm-wait.sh false MSG wake fix). Catches the symptom:
# a pane runs >5 'doey msg read' calls within a 60s window AND every result is
# 0 unread → STM is busy-looping on phantom messages. Source-of-truth is
# $RUNTIME_DIR/msg-read.log with one line per call: "<epoch_ts> <pane> <unread_count>".
# Honors DOEY_DETECTOR_DISABLE (substring match on "R-14", or "all"/"1") and
# DOEY_DETECTOR_DEDUP_WINDOW (via shared fp_within_window helper).
detect_r14() {
  case "${DOEY_DETECTOR_DISABLE:-}" in
    *R-14*|all|1) return 0 ;;
  esac
  local log="$RUNTIME_DIR/msg-read.log"
  [ -f "$log" ] || return 0
  local now window_start results pane count
  now=$(now_epoch)
  window_start=$((now - 60))
  # Per-pane: count calls in window; flag any with non-zero unread.
  # Emit "<pane> <count>" only for panes with count>5 AND every call 0 unread.
  results=$(awk -v ws="$window_start" '
    $1 >= ws {
      pane = $2
      cnt[pane]++
      if ($3 != "0") nonzero[pane] = 1
    }
    END {
      for (p in cnt) {
        if (cnt[p] > 5 && !(p in nonzero)) {
          print p, cnt[p]
        }
      }
    }
  ' "$log" 2>/dev/null) || results=""
  [ -n "$results" ] || return 0
  while IFS=' ' read -r pane count; do
    [ -n "$pane" ] || continue
    # RESERVED guard — match the convention used by R-1/R-3/R-11.
    local safe st status
    safe=$(printf '%s' "$pane" | tr '.' '_')
    st="$RUNTIME_DIR/status/${safe}.status"
    if [ -f "$st" ]; then
      status=$(status_field "$st" "STATUS")
      [ "$status" = "RESERVED" ] && continue
    fi

    emit_finding "R-14" "$pane" "stm-tight-loop: ${count} zero-msg-reads in 60s" "P0"

    # Escalate to Taskmaster's crash-handling path. Idempotent: the existing
    # marker is left alone so taskmaster-wait clears it on its own cycle.
    local crash_file="$RUNTIME_DIR/status/crash_pane_${safe}"
    if [ ! -f "$crash_file" ]; then
      printf 'STM_TIGHT_LOOP %s reads=%s window=60s\n' "$safe" "$count" \
        > "$crash_file" 2>/dev/null || true
      logmsg "CRASH R-14 pane=$pane reads=${count}"
    fi
  done <<EOF
$results
EOF
}

run_tick() {
  ensure_dirs
  logmsg "TICK start"
  detect_r1 || logmsg "ERROR R-1 failed"
  detect_r3 || logmsg "ERROR R-3 failed"
  detect_r11 || logmsg "ERROR R-11 failed"
  detect_r14 || logmsg "ERROR R-14 failed"
  logmsg "TICK end"
}

cmd_once() {
  DETECTOR_START_TS=$(now_epoch)
  # In once mode treat detector_start as 0 so historical fixtures aren't skipped.
  DETECTOR_START_TS=0
  run_tick
}

cmd_start() {
  ensure_dirs
  if [ -f "$PID_FILE" ]; then
    local existing
    existing=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
      exit 0
    fi
    rm -f "$PID_FILE"
  fi
  (
    trap 'rm -f "$PID_FILE" 2>/dev/null || true' EXIT INT TERM
    echo $$ > "$PID_FILE"
    DETECTOR_START_TS=$(now_epoch)
    logmsg "DAEMON start pid=$$"
    while :; do
      run_tick
      sleep "$DOEY_DETECTOR_TICK"
    done
  ) >> "$LOG_FILE" 2>&1 &
  disown 2>/dev/null || true
}

cmd_stop() {
  if [ ! -f "$PID_FILE" ]; then echo "not running"; return 0; fi
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  echo "stopped"
}

cmd_status() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "running pid=$pid"
      return 0
    fi
  fi
  echo "not running"
}

main() {
  local sub="${1:-}"
  case "$sub" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    once)   cmd_once ;;
    *) echo "usage: $0 start|stop|status|once" >&2; exit 1 ;;
  esac
}

main "$@"
