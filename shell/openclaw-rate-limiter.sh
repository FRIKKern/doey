#!/usr/bin/env bash
# shell/openclaw-rate-limiter.sh — Outbound rate ceiling for OpenClaw notify.
#
# Cap: 5 events per second per (task_id, role). Events beyond the ceiling are
# suppressed (counted, not lost) and emitted as a rolled-up notice on flush.
#
# Algorithm: sliding 1-second calendar window. Each (task, role) bucket has a
# state file under ${RUNTIME_DIR:-/tmp/doey/doey}/openclaw/rate/<task>_<role>.state
# State fields:
#   LAST_SECOND_EPOCH=<epoch>   epoch of the second the count tracks
#   COUNT_THIS_SECOND=<n>       events allowed in that second
#   SUPPRESSED_TOTAL=<n>        suppressed events not yet flushed
#   BURST_START_EPOCH=<epoch>   epoch of the most recent suppressed event
#   LAST_FLUSH_EPOCH=<epoch>    epoch of the most recent flush
#
# Flush triggers (oc_rate_pending_flush):
#   1. Post-burst: now - LAST_FLUSH_EPOCH >= 1 with SUPPRESSED_TOTAL > 0 and
#      no new suppressed events arrived (covered by the same condition; if
#      events keep arriving we still tick once per second).
#   2. Sustained burst: ditto — same predicate fires once per second while a
#      burst persists. consume_flush updates LAST_FLUSH_EPOCH so it self-limits.
#   3. Pre-emit: caller passes "pre_emit" as 3rd arg — bypasses the timing
#      gate so a non-suppressed event can carry a prepended suppression notice.
#
# All state writes are atomic via mktemp + mv, safe across concurrent callers.
# Counter increments may race; this is acceptable per spec — we accept tiny
# undercounts of SUPPRESSED_TOTAL in exchange for no flock dependency.
#
# Bash 3.2 compatible.

set -euo pipefail

[ "${__doey_oc_rate_limiter_sourced:-}" = "1" ] && return 0 2>/dev/null || true
__doey_oc_rate_limiter_sourced=1

OC_RATE_CEILING=5

_oc_rate_dir() {
  local rt="${RUNTIME_DIR:-/tmp/doey/doey}"
  echo "${rt}/openclaw/rate"
}

# Sanitize a token to filename-safe characters. Bash 3.2: tr-based.
_oc_rate_sanitize() {
  printf '%s' "${1:-_}" | tr -c 'A-Za-z0-9._-' '_'
}

_oc_rate_state_path() {
  local task role d t r
  task="${1:-_}"; role="${2:-_}"
  t=$(_oc_rate_sanitize "$task")
  r=$(_oc_rate_sanitize "$role")
  d=$(_oc_rate_dir)
  mkdir -p "$d" 2>/dev/null || true
  echo "${d}/${t}_${r}.state"
}

# Load state file into module-scope vars. Defaults to zeros if absent.
_oc_rate_load() {
  local f="$1" line key val
  _LSE=0; _CTS=0; _ST=0; _BSE=0; _LFE=0
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      LAST_SECOND_EPOCH)  _LSE="$val" ;;
      COUNT_THIS_SECOND)  _CTS="$val" ;;
      SUPPRESSED_TOTAL)   _ST="$val"  ;;
      BURST_START_EPOCH)  _BSE="$val" ;;
      LAST_FLUSH_EPOCH)   _LFE="$val" ;;
    esac
  done < "$f"
  # Coerce empties to 0 (defensive).
  : "${_LSE:=0}" "${_CTS:=0}" "${_ST:=0}" "${_BSE:=0}" "${_LFE:=0}"
}

# Atomic write via mktemp + mv (same dir to keep mv on one filesystem).
_oc_rate_save() {
  local f="$1" d tmp
  d=$(dirname "$f")
  tmp=$(mktemp "${d}/.rate.XXXXXX")
  {
    printf 'LAST_SECOND_EPOCH=%s\n' "$_LSE"
    printf 'COUNT_THIS_SECOND=%s\n' "$_CTS"
    printf 'SUPPRESSED_TOTAL=%s\n' "$_ST"
    printf 'BURST_START_EPOCH=%s\n' "$_BSE"
    printf 'LAST_FLUSH_EPOCH=%s\n' "$_LFE"
  } > "$tmp"
  mv -f "$tmp" "$f"
}

# oc_rate_check task_id role
# Returns 0 if event passes the 5/sec ceiling, 1 if suppressed.
oc_rate_check() {
  local task="${1:-}" role="${2:-}" f now
  f=$(_oc_rate_state_path "$task" "$role")
  now=$(date +%s)

  _oc_rate_load "$f"

  if [ "$_LSE" != "$now" ]; then
    _LSE="$now"
    _CTS=0
  fi

  if [ "$_CTS" -lt "$OC_RATE_CEILING" ]; then
    _CTS=$((_CTS + 1))
    _oc_rate_save "$f"
    return 0
  fi

  _ST=$((_ST + 1))
  _BSE="$now"
  _oc_rate_save "$f"
  return 1
}

# oc_rate_pending_flush task_id role [pre_emit]
# Echoes the rolled-up suppression message and returns 0 if a flush is due.
# Returns 1 (silent) if no flush trigger has fired since last flush.
oc_rate_pending_flush() {
  local task="${1:-}" role="${2:-}" mode="${3:-}" f now since
  f=$(_oc_rate_state_path "$task" "$role")
  [ -f "$f" ] || return 1
  _oc_rate_load "$f"
  [ "$_ST" -gt 0 ] || return 1

  if [ "$mode" = "pre_emit" ]; then
    printf 'rate-limit: %s events suppressed in last second\n' "$_ST"
    return 0
  fi

  now=$(date +%s)
  since=$((now - _LFE))
  if [ "$since" -ge 1 ]; then
    printf 'rate-limit: %s events suppressed in last second\n' "$_ST"
    return 0
  fi
  return 1
}

# oc_rate_consume_flush task_id role
# Clears suppression counter and stamps last_flush. Idempotent — safe to call
# even when nothing was suppressed.
oc_rate_consume_flush() {
  local task="${1:-}" role="${2:-}" f
  f=$(_oc_rate_state_path "$task" "$role")
  [ -f "$f" ] || return 0
  _oc_rate_load "$f"
  _ST=0
  _LFE=$(date +%s)
  _oc_rate_save "$f"
  return 0
}

# oc_rate_self_test
# Sanity check: 20 rapid events into a temp bucket — expect 5 allowed, 15
# suppressed. Wait for post-burst trigger and verify the rolled-up message.
oc_rate_self_test() {
  local saved_runtime saved_set td pass supp i msg rc
  saved_runtime="${RUNTIME_DIR:-__UNSET__}"
  td=$(mktemp -d -t oc-rate-self.XXXXXX 2>/dev/null) || td=$(mktemp -d) \
    || { echo "FAIL: mktemp"; return 1; }
  RUNTIME_DIR="$td"
  export RUNTIME_DIR

  # Align to the start of a fresh second so the 20-event burst is guaranteed
  # to land in a single counting window (avoids boundary flake on slow CI).
  local _t0
  _t0=$(date +%s)
  while [ "$(date +%s)" = "$_t0" ]; do : ; done

  pass=0; supp=0; i=0
  while [ "$i" -lt 20 ]; do
    if oc_rate_check selftest worker 2>/dev/null; then
      pass=$((pass + 1))
    else
      supp=$((supp + 1))
    fi
    i=$((i + 1))
  done

  rc=0
  if [ "$pass" != "5" ]; then
    echo "FAIL: expected 5 passes, got $pass"
    rc=1
  fi
  if [ "$supp" != "15" ]; then
    echo "FAIL: expected 15 suppressed, got $supp"
    rc=1
  fi

  # Wait for the post-burst flush trigger (>=1s since LAST_FLUSH_EPOCH=0).
  sleep 2
  if msg=$(oc_rate_pending_flush selftest worker 2>/dev/null); then
    case "$msg" in
      *"15 events suppressed in last second"*) : ;;
      *) echo "FAIL: flush message wrong: $msg"; rc=1 ;;
    esac
  else
    echo "FAIL: pending_flush did not fire post-burst"
    rc=1
  fi

  rm -rf "$td" 2>/dev/null || true
  if [ "$saved_runtime" = "__UNSET__" ]; then
    unset RUNTIME_DIR
  else
    RUNTIME_DIR="$saved_runtime"
    export RUNTIME_DIR
  fi

  if [ "$rc" = "0" ]; then
    echo "PASS"
    return 0
  fi
  return 1
}
