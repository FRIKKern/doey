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
DOEY_DETECTOR_RELOAD_EVERY="${DOEY_DETECTOR_RELOAD_EVERY:-10}"

DETECTOR_START_TS=""
DETECTOR_SCRIPT_MTIME=""

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

    # Scrollback-freshness guard (mirrors R-3 pattern): the buried-brief signal
    # must still be visible in the LIVE pane right now, AND the pane must be
    # actively producing output. Without this, R-11 refires every dedup-window
    # on stale result files even after the pane has long since recovered (task
    # 671). Two combined gates:
    #   (a) tmux capture-pane last 30 lines must contain the "Claude Code v"
    #       banner — the briefing-loss signal must be visible NOW, not buried
    #       deep in scrollback above current activity.
    #   (b) doey-ctl status observe last_output_age_sec must be < 90s — pane
    #       has not moved past the failure into normal work. If doey-ctl is
    #       missing or fails to return an age, fail safe and skip emission.
    local cap_recent age_json age
    cap_recent=$(tmux capture-pane -t "$DOEY_SESSION:$pane" -p -S -30 2>/dev/null || echo "")
    [ -n "$cap_recent" ] || continue
    printf '%s' "$cap_recent" | grep -Eq 'Claude Code v[0-9.]+' || continue

    command -v doey-ctl >/dev/null 2>&1 || continue
    age_json=$(doey-ctl status observe "$DOEY_SESSION:$pane" --json 2>/dev/null || echo "")
    [ -n "$age_json" ] || continue
    age=$(printf '%s' "$age_json" | sed -nE 's/.*"last_output_age_sec"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    case "$age" in ''|*[!0-9]*) continue ;; esac
    [ "$age" -lt 90 ] || continue

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
# Symptom: a task transitions to pending_user_confirmation but the artifacts
# it claims as deliverables don't exist on disk. Background: tasks 659/668 —
# Smart SQLite search was reported shipped while 4 of 7 deliverables were not
# landed; Boss verification caught the gap and #668 had to retroactively land
# them. Task 672: naive path-grep produced 299 false positives in hours by
# treating any slash-token in any task content as a claim.
#
# Trigger: ONLY tasks with status=pending_user_confirmation (the completion
# claim gate). Skip done (past gate). Skip in_progress / pending (no claim).
# Claim sources (structured only — never free-text descriptions or logs):
#   1. JSON "deliverables": [ ... ] arrays (multi-line aware)
#   2. Lines under DELIVERABLES:/FILES:/ARTIFACTS:/NEW:/MODIFIED: headers
# Non-local claims skipped: absolute paths, URLs, Users/* (macOS workstation),
# ~/* (unresolved home), tmp/* (transient).
# Reuses the shared mtime-based dedup window (fp_within_window).
# Severity: P0 default; downgrade with DOEY_R17_SEVERITY=P1.
check_r17_completion_filesystem_mismatch() {
  case "${DOEY_DETECTOR_DISABLE:-}" in
    *R-17*|all|1) return 0 ;;
  esac
  local proj="${DOEY_PROJECT_DIR:-${PWD:-.}}"
  local tasks_dir="$proj/.doey/tasks"
  [ -d "$tasks_dir" ] || return 0
  local sev="${DOEY_R17_SEVERITY:-P0}"
  local f base
  for f in "$tasks_dir"/*.task "$tasks_dir"/*.json; do
    [ -f "$f" ] || continue
    # Only canonical per-task files — skip aggregates (tasks.json), result
    # files (NNN.result.json), tmp save files (NNN.task.tmp.*), and any other
    # auxiliary file under .doey/tasks/.
    base=$(basename "$f")
    case "$base" in
      [0-9]*.task|[0-9]*.json) ;;
      *) continue ;;
    esac
    case "$base" in
      *.result.json|*.task.tmp.*) continue ;;
    esac
    _r17_check_task_file "$f" "$proj" "$sev" || true
  done
}

# Emit one claim per line. Reads task content on stdin. Two structured sources:
# JSON "deliverables": [...] arrays, and lines under DELIVERABLES:/FILES:/
# ARTIFACTS:/NEW:/MODIFIED: headers (terminated by blank line or new header).
_r17_extract_claims() {
  awk '
    BEGIN { in_arr = 0; in_sec = 0 }
    function emit_quoted(line,   s, tok) {
      s = line
      while (match(s, /"[^"]*"/)) {
        tok = substr(s, RSTART + 1, RLENGTH - 2)
        if (tok != "") print tok
        s = substr(s, RSTART + RLENGTH)
      }
    }
    function emit_tokens(line,   n, parts, i, t) {
      sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
      sub(/^[[:space:]]+/, "", line)
      n = split(line, parts, /[[:space:],]+/)
      for (i = 1; i <= n; i++) {
        t = parts[i]
        gsub(/^["`]+|["`,;.]+$/, "", t)
        if (t != "") print t
      }
    }
    /"deliverables"[[:space:]]*:[[:space:]]*\[/ {
      in_arr = 1
      tail = $0
      sub(/.*\[/, "", tail)
      emit_quoted(tail)
      if (index($0, "]")) in_arr = 0
      next
    }
    in_arr == 1 {
      emit_quoted($0)
      if (index($0, "]")) in_arr = 0
      next
    }
    /^[[:space:]]*(DELIVERABLES|FILES|ARTIFACTS|NEW|MODIFIED)[[:space:]]*:/ {
      in_sec = 1
      tail = $0
      sub(/^[[:space:]]*[A-Z_]+[[:space:]]*:[[:space:]]*/, "", tail)
      if (tail != "") emit_tokens(tail)
      next
    }
    in_sec == 1 && /^[[:space:]]*$/ { in_sec = 0; next }
    in_sec == 1 && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[:=]/ { in_sec = 0 }
    in_sec == 1 { emit_tokens($0) }
  '
}

_r17_check_task_file() {
  local f="$1" proj="$2" sev="$3"
  local task_id status ttype content claims claim actual fname

  content=$(cat "$f" 2>/dev/null || echo "")
  [ -n "$content" ] || return 0

  # Status: KEY=VALUE (.task) preferred; JSON "status":"..." fallback.
  status=$(printf '%s\n' "$content" | awk -F= '/^TASK_STATUS=/ { print $2; exit }')
  if [ -z "$status" ]; then
    status=$(printf '%s\n' "$content" \
      | sed -nE 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
      | head -1)
  fi
  # Trigger gate — only pending_user_confirmation (the completion claim state).
  case "$status" in
    pending_user_confirmation) ;;
    *) return 0 ;;
  esac

  # Type guard (task 674) — research/audit/question/interview/masterplan tasks
  # describe FUTURE artifacts in DESIGN/PROPOSED sections; their DELIVERABLES
  # listings are proposals, not completion claims. R-17 must skip them.
  # Bug: task #443 (type=research) flooded 980+ findings claiming proposed
  # paths from PHASE 2 DESIGN. Use a blocklist so newly-added action types
  # remain covered by default.
  ttype=$(printf '%s\n' "$content" | awk -F= '/^TASK_TYPE=/ { print $2; exit }')
  if [ -z "$ttype" ]; then
    ttype=$(printf '%s\n' "$content" \
      | sed -nE 's/.*"type"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
      | head -1)
  fi
  case "$ttype" in
    research|audit|question|interview|masterplan) return 0 ;;
  esac

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

  # Strip URLs to avoid host/path false positives leaking into claims.
  content=$(printf '%s\n' "$content" \
    | sed -E 's|https?://[^[:space:])"]+||g')

  claims=$(printf '%s\n' "$content" | _r17_extract_claims | sort -u)
  [ -n "$claims" ] || return 0

  while IFS= read -r claim; do
    [ -n "$claim" ] || continue
    claim=$(printf '%s' "$claim" | sed -E 's/[.,;:)]+$//')
    [ -n "$claim" ] || continue
    case "$claim" in
      ''|/*|*://*) continue ;;
      Users/*|tmp/*) continue ;;
      '~'/*) continue ;;
    esac
    case "$claim" in
      */*) ;;
      *) continue ;;
    esac
    # Reject word-pairs ("Pass/fail", "read/consume", "Watchdog/watchdog"):
    # a real path either has a file extension OR at least two slashes.
    case "$claim" in
      *.*|*/*/*) ;;
      *) continue ;;
    esac
    [ "${#claim}" -ge 5 ] || continue
    if printf '%s' "$claim" | grep -q '\*'; then
      if ( cd "$proj" 2>/dev/null && compgen -G "$claim" >/dev/null 2>&1 ); then
        continue
      fi
      actual="glob-matched-0-entries"
    else
      if [ -e "$proj/$claim" ]; then continue; fi
      actual="missing"
    fi
    emit_finding "R-17" "task:${task_id}" \
      "completion_filesystem_mismatch task=${task_id} claim=\"${claim}\" actual=${actual}" \
      "$sev"
  done <<EOF
$claims
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

# Cmdline check: confirm that a PID is actually a silent-fail-detector
# process, not a recycled PID belonging to something else. /proc on Linux,
# `ps` fallback for macOS / other UNIX.
detector_pid_matches() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null \
      | grep -Fq 'silent-fail-detector' && return 0 || return 1
  fi
  ps -p "$pid" -o args= 2>/dev/null | grep -Fq 'silent-fail-detector'
}

# Atomic PID write: tmp + mv (mv is atomic on the same filesystem).
write_pid_atomic() {
  local pid="$1" tmp
  tmp="${PID_FILE}.tmp.$$"
  printf '%s\n' "$pid" > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$PID_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# Atomic check-and-write under a mkdir-mutex. mkdir is atomic in POSIX, so
# only one caller succeeds. Stale lock dirs older than 30s are reclaimed.
_acquire_lock_mkdir() {
  local lock_dir="$1" attempts=0 age now
  while [ "$attempts" -lt 50 ]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      return 0
    fi
    if [ -d "$lock_dir" ]; then
      age=$(stat -c %Y "$lock_dir" 2>/dev/null || stat -f %m "$lock_dir" 2>/dev/null || echo 0)
      now=$(date +%s)
      if [ "$age" -gt 0 ] 2>/dev/null && [ $((now - age)) -gt 30 ] 2>/dev/null; then
        rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
      fi
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done
  return 1
}

# Singleton guard. Returns 0 if caller should proceed (we now own PID file),
# 1 if another detector already owns it (caller must exit silently).
# Uses $BASHPID — in a subshell, $$ still returns the *parent* shell's PID,
# which is the bug that caused 30+ duplicate detectors to accumulate.
# Race-safe: the check-and-write is serialized via a mkdir-mutex so two
# concurrent detector starts cannot both pass the "is anyone alive?" check.
acquire_singleton() {
  ensure_dirs
  local self_pid="${BASHPID:-$$}"
  local lock_dir="$RUNTIME_DIR/silent-fail-detector.singleton.lock"
  local got_lock=0
  if _acquire_lock_mkdir "$lock_dir"; then got_lock=1; fi

  local existing=""
  if [ -f "$PID_FILE" ]; then
    existing=$(cat "$PID_FILE" 2>/dev/null || echo "")
    existing="${existing%%[!0-9]*}"
    # Self-detection: after exec, the new process inherits the old PID.
    # If the PID file already names *us*, treat it as a clean re-entry.
    if [ -n "$existing" ] && [ "$existing" = "$self_pid" ]; then
      logmsg "detector: re-entering after exec, pid=$self_pid"
    elif [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null && detector_pid_matches "$existing"; then
      logmsg "detector: already running pid=$existing, exiting"
      [ "$got_lock" = "1" ] && rmdir "$lock_dir" 2>/dev/null || true
      return 1
    else
      logmsg "detector: stale pid file, taking over (was=$existing self=$self_pid)"
    fi
  else
    logmsg "detector: starting, pid=$self_pid"
  fi

  if ! write_pid_atomic "$self_pid"; then
    logmsg "ERROR detector: failed to write pid file"
    [ "$got_lock" = "1" ] && rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi

  [ "$got_lock" = "1" ] && rmdir "$lock_dir" 2>/dev/null || true
  return 0
}

cmd_start() {
  ensure_dirs
  # Pre-check before forking — avoids spawning a child that immediately exits.
  if [ -f "$PID_FILE" ]; then
    local existing
    existing=$(cat "$PID_FILE" 2>/dev/null || echo "")
    existing="${existing%%[!0-9]*}"
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null && detector_pid_matches "$existing"; then
      return 0
    fi
  fi
  (
    # Disable strict-mode in the daemon loop — individual detectors already
    # catch their own errors via `|| logmsg ERROR`. set -e in a long-running
    # loop is a footgun: a single non-zero pipefail can take the whole
    # daemon down silently.
    set +e
    set +o pipefail
    if ! acquire_singleton; then
      exit 0
    fi
    trap '
      _file_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
      if [ "$_file_pid" = "${BASHPID:-$$}" ]; then rm -f "$PID_FILE" 2>/dev/null || true; fi
    ' EXIT INT TERM
    DETECTOR_START_TS=$(now_epoch)
    DETECTOR_SCRIPT_MTIME=$(file_mtime "$0")
    logmsg "DAEMON start pid=${BASHPID:-$$} script=$0 mtime=${DETECTOR_SCRIPT_MTIME}"
    _tick_n=0
    while :; do
      run_tick
      _tick_n=$((_tick_n + 1))
      # Auto-reload on source change every N ticks. exec preserves PID,
      # so the singleton guard sees its own pid still in PID_FILE on re-entry.
      if [ "$DOEY_DETECTOR_RELOAD_EVERY" -gt 0 ] 2>/dev/null \
         && [ $((_tick_n % DOEY_DETECTOR_RELOAD_EVERY)) -eq 0 ]; then
        _cur_mtime=$(file_mtime "$0")
        if [ -n "$_cur_mtime" ] && [ -n "$DETECTOR_SCRIPT_MTIME" ] \
           && [ "$_cur_mtime" != "$DETECTOR_SCRIPT_MTIME" ]; then
          logmsg "detector: source mtime changed (was=${DETECTOR_SCRIPT_MTIME} now=${_cur_mtime}), reloading via exec"
          exec "$0" start-foreground
        fi
      fi
      sleep "$DOEY_DETECTOR_TICK"
    done
  ) >> "$LOG_FILE" 2>&1 &
  disown 2>/dev/null || true
}

# Foreground start used by exec-on-reload. Same loop as cmd_start's child
# but in-process (no double-fork) so the PID is preserved across reloads.
cmd_start_foreground() {
  ensure_dirs
  if ! acquire_singleton; then
    exit 0
  fi
  # Same rationale as cmd_start subshell: don't let strict-mode tear the
  # daemon down on a transient pipefail inside a detector.
  set +e
  set +o pipefail
  trap '
    _self_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ "$_self_pid" = "$$" ]; then rm -f "$PID_FILE" 2>/dev/null || true; fi
  ' EXIT INT TERM
  DETECTOR_START_TS=$(now_epoch)
  DETECTOR_SCRIPT_MTIME=$(file_mtime "$0")
  logmsg "DAEMON start pid=$$ script=$0 mtime=${DETECTOR_SCRIPT_MTIME}"
  local _tick_n=0
  while :; do
    run_tick
    _tick_n=$((_tick_n + 1))
    if [ "$DOEY_DETECTOR_RELOAD_EVERY" -gt 0 ] 2>/dev/null \
       && [ $((_tick_n % DOEY_DETECTOR_RELOAD_EVERY)) -eq 0 ]; then
      local _cur_mtime
      _cur_mtime=$(file_mtime "$0")
      if [ -n "$_cur_mtime" ] && [ -n "$DETECTOR_SCRIPT_MTIME" ] \
         && [ "$_cur_mtime" != "$DETECTOR_SCRIPT_MTIME" ]; then
        logmsg "detector: source mtime changed (was=${DETECTOR_SCRIPT_MTIME} now=${_cur_mtime}), reloading via exec"
        exec "$0" start-foreground
      fi
    fi
    sleep "$DOEY_DETECTOR_TICK"
  done
}

cmd_stop() {
  if [ ! -f "$PID_FILE" ]; then echo "not running"; return 0; fi
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  pid="${pid%%[!0-9]*}"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    # Wait up to ~3s for graceful shutdown.
    local _i=0
    while [ "$_i" -lt 30 ]; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
      _i=$((_i + 1))
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
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
    start)            cmd_start ;;
    start-foreground) cmd_start_foreground ;;
    stop)             cmd_stop ;;
    status)           cmd_status ;;
    once)             cmd_once ;;
    *) echo "usage: $0 start|start-foreground|stop|status|once" >&2; exit 1 ;;
  esac
}

main "$@"
