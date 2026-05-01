#!/usr/bin/env bash
# silent-fail-detector.sh — Doey Phase-1 silent-failure detection daemon.
# Rules: R-1 (paste-no-submit), R-3 (UPDATED/heartbeat skew), R-11 (briefing-handoff loss),
#        R-14 (STM tight-loop on empty msg-read), R-15 (Claude UX popup blocks pane),
#        R-16 (coordinator /clear strands in-flight requests),
#        R-17 (completion-claim vs filesystem mismatch).
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

# ────── R-15 Claude UX feedback popup blocks pane ──────
# Symptom: Claude's "1: Bad  2: Fine  3: Good  0: Dismiss" feedback popup is
# rendered in the pane and consumes all keystrokes. Status file says READY/IDLE
# (the harness believes the pane is free) but real input is blocked.
# Recovery: send '0' + Enter to dismiss popup.
check_r15_claude_ux_popup() {
  case "${DOEY_DETECTOR_DISABLE:-}" in
    *R-15*|all|1) return 0 ;;
  esac
  local status_dir="$RUNTIME_DIR/status"
  [ -d "$status_dir" ] || return 0
  local panes_present=""
  if command -v tmux >/dev/null 2>&1; then
    panes_present=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "")
  fi
  local f base safe pane status mtime now mtime_age cap has_work
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
      READY|IDLE) ;;
      *) continue ;;
    esac
    mtime=$(file_mtime "$f")
    [ -n "$mtime" ] || continue
    mtime_age=$((now - mtime))
    # Age guard: only fire if pane has been quiet long enough that a popup is
    # not just transient (>300s).
    [ "$mtime_age" -gt 300 ] || continue

    # Pane existence check (only if tmux gave us a list).
    if [ -n "$panes_present" ]; then
      if ! printf '%s\n' "$panes_present" | grep -Fxq "$DOEY_SESSION:$pane"; then
        continue
      fi
    fi

    # Assigned-work check: task_id file or non-empty TASK_ID in status.
    has_work=0
    if [ -f "$status_dir/${safe}.task_id" ]; then has_work=1; fi
    if [ "$has_work" -eq 0 ]; then
      local tid
      tid=$(status_field "$f" "TASK_ID")
      [ -n "$tid" ] && has_work=1
    fi
    [ "$has_work" -eq 1 ] || continue

    # Capture last 30 lines and look for the literal popup signature.
    cap=$(tmux capture-pane -t "$DOEY_SESSION:$pane" -p -S -30 2>/dev/null || echo "")
    [ -n "$cap" ] || continue
    printf '%s' "$cap" | grep -Fq '1: Bad' || continue
    printf '%s' "$cap" | grep -Fq '0: Dismiss' || continue

    emit_finding "R-15" "$pane" "claude-ux-popup blocks pane; status=${status}; recovery: send '0' + Enter to dismiss popup" "P0"
  done
}

# ────── R-16 Coordinator /clear strands in-flight requests ──────
# Symptom: a coordinator pane (Reviewer/STM/TM) ran `/clear`, dropping all
# context. Pending inbound .msg files addressed to that pane are now orphaned
# because the cleared coordinator has no memory of them. Senders sleep waiting
# for verdicts that never come.
# Recovery: nudge cleared pane to re-process inbox.
check_r16_clear_strands_requests() {
  case "${DOEY_DETECTOR_DISABLE:-}" in
    *R-16*|all|1) return 0 ;;
  esac
  local status_dir="$RUNTIME_DIR/status"
  local msg_dir="$RUNTIME_DIR/messages"
  [ -d "$status_dir" ] || return 0
  [ -d "$msg_dir" ] || return 0
  local panes_present=""
  if command -v tmux >/dev/null 2>&1; then
    panes_present=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "")
  fi
  local f base safe pane status mtime now mtime_age cap m_file m_mtime unread_old
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
      READY|IDLE) ;;
      *) continue ;;
    esac
    mtime=$(file_mtime "$f")
    [ -n "$mtime" ] || continue
    mtime_age=$((now - mtime))
    # Status transition recency: status mtime within last 60s ⇒ recently went READY.
    [ "$mtime_age" -le 60 ] || continue

    # Pane existence check (only if tmux gave us a list).
    if [ -n "$panes_present" ]; then
      if ! printf '%s\n' "$panes_present" | grep -Fxq "$DOEY_SESSION:$pane"; then
        continue
      fi
    fi

    # Scrollback-freshness guard: capture-pane is live, so a literal `/clear`
    # in last 30 lines paired with a recent status mtime localizes the event.
    cap=$(tmux capture-pane -t "$DOEY_SESSION:$pane" -p -S -30 2>/dev/null || echo "")
    [ -n "$cap" ] || continue
    printf '%s' "$cap" | grep -Eq '(^|[[:space:]])/clear([[:space:]]|$)' || continue

    # Completion-aware: only fire when there is at least one unread .msg
    # addressed to this pane older than 60s — otherwise no work is stranded.
    unread_old=0
    for m_file in "$msg_dir/${safe}_"*.msg; do
      [ -f "$m_file" ] || continue
      m_mtime=$(file_mtime "$m_file")
      [ -n "$m_mtime" ] || continue
      case "$m_mtime" in ''|*[!0-9]*) continue ;; esac
      if [ $((now - m_mtime)) -gt 60 ]; then
        unread_old=$((unread_old + 1))
      fi
    done
    [ "$unread_old" -ge 1 ] || continue

    emit_finding "R-16" "$pane" "coordinator-clear-strand: ${unread_old} stale unread msg(s); recovery: nudge cleared pane to re-process inbox" "P0"
  done
}

# ────── R-17 completion-claim vs filesystem mismatch ──────
# Symptom: a task is reported complete (or about to be forwarded as complete)
# but the artifacts it claims under DELIVERABLES / PROOF do not actually exist
# on disk. Background: tasks 659/668 — Smart SQLite search was reported shipped
# while 4 of 7 deliverables (docs/search.md, MCP server, msg search subcommand,
# tests) were not landed; Boss verification caught the gap and #668 had to
# retroactively land them.
#
# Heuristic: scan task files in $DOEY_PROJECT_DIR/.doey/tasks/, skip
# done / pending_user_confirmation, extract path-shaped tokens (slash-bearing,
# ASCII path chars only), and verify each against the filesystem. Glob tokens
# are checked via `compgen -G`; bare paths via `[ -e ]`. Reuses the shared
# mtime-based dedup window from #667 (fp_within_window).
# Severity: P0 default; downgrade with DOEY_R17_SEVERITY=P1.
check_r17_completion_filesystem_mismatch() {
  case "${DOEY_DETECTOR_DISABLE:-}" in
    *R-17*|all|1) return 0 ;;
  esac
  local proj="${DOEY_PROJECT_DIR:-${PWD:-.}}"
  local tasks_dir="$proj/.doey/tasks"
  [ -d "$tasks_dir" ] || return 0
  local sev="${DOEY_R17_SEVERITY:-P0}"
  local f
  for f in "$tasks_dir"/*.task "$tasks_dir"/*.json; do
    [ -f "$f" ] || continue
    _r17_check_task_file "$f" "$proj" "$sev" || true
  done
}

_r17_check_task_file() {
  local f="$1" proj="$2" sev="$3"
  local task_id status content tokens token actual fname

  content=$(cat "$f" 2>/dev/null || echo "")
  [ -n "$content" ] || return 0

  # Status: KEY=VALUE (.task) preferred; JSON "status":"..." fallback.
  status=$(printf '%s\n' "$content" | awk -F= '/^TASK_STATUS=/ { print $2; exit }')
  if [ -z "$status" ]; then
    status=$(printf '%s\n' "$content" \
      | sed -nE 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
      | head -1)
  fi
  case "$status" in
    done|pending_user_confirmation) return 0 ;;
  esac

  # Gate: only tasks that actually claim deliverables / proof.
  printf '%s\n' "$content" \
    | grep -Eq '(DELIVERABLES|PROOF|"deliverables"|"proof")' \
    || return 0

  # Task id: KEY=VALUE → JSON "id" → filename stem.
  task_id=$(printf '%s\n' "$content" | awk -F= '/^TASK_ID=/ { print $2; exit }')
  if [ -z "$task_id" ]; then
    task_id=$(printf '%s\n' "$content" \
      | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' \
      | head -1)
  fi
  if [ -z "$task_id" ]; then
    fname=$(basename "$f")
    task_id="${fname%.task}"
    task_id="${task_id%.json}"
  fi
  [ -n "$task_id" ] || return 0

  # Strip URLs (avoid host/path false positives) and TASK_FILES= line
  # (auto-populated changed-file roster, not deliverable claims).
  content=$(printf '%s\n' "$content" \
    | sed -E 's|https?://[^[:space:])"]+||g' \
    | grep -v '^TASK_FILES=' || true)

  # Path-shaped tokens: must contain a slash, ASCII path chars only.
  tokens=$(printf '%s\n' "$content" \
    | grep -oE '[A-Za-z_.][A-Za-z0-9_./*+-]*/[A-Za-z0-9_./*+-]*' 2>/dev/null \
    | sort -u || true)
  [ -n "$tokens" ] || return 0

  while IFS= read -r token; do
    [ -n "$token" ] || continue
    token=$(printf '%s' "$token" | sed -E 's/[.,;:)]+$//')
    case "$token" in
      ''|/*|*://*) continue ;;
    esac
    case "$token" in
      */*) ;;
      *) continue ;;
    esac
    [ "${#token}" -ge 5 ] || continue
    if printf '%s' "$token" | grep -q '\*'; then
      if ( cd "$proj" 2>/dev/null && compgen -G "$token" >/dev/null 2>&1 ); then
        continue
      fi
      actual="glob-matched-0-entries"
    else
      if [ -e "$proj/$token" ]; then continue; fi
      actual="missing"
    fi
    emit_finding "R-17" "task:${task_id}" \
      "completion_filesystem_mismatch task=${task_id} claim=\"${token}\" actual=${actual}" \
      "$sev"
  done <<EOF
$tokens
EOF
}

run_tick() {
  ensure_dirs
  logmsg "TICK start"
  detect_r1 || logmsg "ERROR R-1 failed"
  detect_r3 || logmsg "ERROR R-3 failed"
  detect_r11 || logmsg "ERROR R-11 failed"
  detect_r14 || logmsg "ERROR R-14 failed"
  check_r15_claude_ux_popup || logmsg "ERROR R-15 failed"
  check_r16_clear_strands_requests || logmsg "ERROR R-16 failed"
  check_r17_completion_filesystem_mismatch || logmsg "ERROR R-17 failed"
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
