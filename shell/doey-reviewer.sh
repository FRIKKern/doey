#!/usr/bin/env bash
# doey-reviewer.sh — `doey reviewer ...` subcommand module (task 591 Phase 0)
# Sourced from shell/doey.sh.
#
# Subcommands:
#   doey reviewer stats [--last N]   Print aggregate reviewer metrics
#
# Reads BOTH stores (runtime jsonl + persistent .doey/metrics/reviews.jsonl),
# deduplicates by full-line hash, sorts by timestamp_iso, slices to the last N.

set -euo pipefail

_doey_reviewer_resolve_paths() {
  local project_dir="" runtime_dir=""
  if [ -n "${DOEY_PROJECT_DIR:-}" ]; then
    project_dir="$DOEY_PROJECT_DIR"
  elif [ -d "$(pwd)/.doey" ]; then
    project_dir="$(pwd)"
  elif type find_project_dir >/dev/null 2>&1; then
    project_dir=$(find_project_dir 2>/dev/null || true)
  fi
  if [ -n "${DOEY_RUNTIME_DIR:-}" ]; then
    runtime_dir="$DOEY_RUNTIME_DIR"
  elif [ -n "${RUNTIME_DIR:-}" ]; then
    runtime_dir="$RUNTIME_DIR"
  elif [ -n "$project_dir" ]; then
    runtime_dir="/tmp/doey/$(basename "$project_dir")"
  fi
  printf '%s\n%s\n' "$project_dir" "$runtime_dir"
}

_doey_reviewer_merge_rows() {
  local runtime_file="$1" persist_file="$2" last_n="$3"
  local combined
  combined=$( { [ -f "$runtime_file" ] && cat "$runtime_file"; [ -f "$persist_file" ] && cat "$persist_file"; } 2>/dev/null \
    | awk 'NF' \
    | awk '!seen[$0]++' )
  if [ -z "$combined" ]; then
    printf ''
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    # Prefix each row with its timestamp, sort by it, strip prefix, tail N.
    printf '%s\n' "$combined" \
      | jq -rc '"\(.timestamp_iso // "0000")\t\(.)"' 2>/dev/null \
      | sort \
      | cut -f2- \
      | tail -n "$last_n"
  else
    printf '%s\n' "$combined" | tail -n "$last_n"
  fi
}

_doey_reviewer_stats_compute() {
  local rows="$1"
  if [ -z "$rows" ]; then
    printf 'total=0 pass=0 fail=0 unknown=0 reverts=0 avg_ms=0 p50_ms=0 p95_ms=0 avg_bytes=0\n'
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf 'total=? pass=? fail=? unknown=? reverts=? avg_ms=? p50_ms=? p95_ms=? avg_bytes=? (jq required)\n'
    return 0
  fi

  local total pass fail unknown reverts avg_ms avg_bytes
  total=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  pass=$(   printf '%s\n' "$rows" | jq -s '[.[] | select(.verdict=="PASS")]    | length' 2>/dev/null || printf '0')
  fail=$(   printf '%s\n' "$rows" | jq -s '[.[] | select(.verdict=="FAIL")]    | length' 2>/dev/null || printf '0')
  unknown=$(printf '%s\n' "$rows" | jq -s '[.[] | select(.verdict=="UNKNOWN")] | length' 2>/dev/null || printf '0')
  reverts=$(printf '%s\n' "$rows" | jq -s '[.[] | select(.reverted_after_pass==true)] | length' 2>/dev/null || printf '0')
  [ -z "$pass" ] && pass=0
  [ -z "$fail" ] && fail=0
  [ -z "$unknown" ] && unknown=0
  [ -z "$reverts" ] && reverts=0

  # Latency stats.
  local lats
  lats=$(printf '%s\n' "$rows" | jq -r '.reviewer_latency_ms // 0' 2>/dev/null | awk 'NF' | sort -n)
  if [ -z "$lats" ]; then
    avg_ms=0
    local p50_ms=0 p95_ms=0
  else
    avg_ms=$(printf '%s\n' "$lats" | awk '{s+=$1; n++} END {if(n>0) printf "%d", s/n; else print 0}')
    local count
    count=$(printf '%s\n' "$lats" | wc -l | tr -d ' ')
    local p50_idx p95_idx
    p50_idx=$(( (count + 1) / 2 ))
    p95_idx=$(awk -v n="$count" 'BEGIN { i = int(n*0.95 + 0.5); if (i<1) i=1; if (i>n) i=n; print i }')
    p50_ms=$(printf '%s\n' "$lats" | sed -n "${p50_idx}p")
    p95_ms=$(printf '%s\n' "$lats" | sed -n "${p95_idx}p")
    [ -z "$p50_ms" ] && p50_ms=0
    [ -z "$p95_ms" ] && p95_ms=0
  fi

  avg_bytes=$(printf '%s\n' "$rows" | jq -r '.payload_size_bytes // 0' 2>/dev/null \
    | awk 'NF' \
    | awk '{s+=$1; n++} END {if(n>0) printf "%d", s/n; else print 0}')

  printf 'total=%s pass=%s fail=%s unknown=%s reverts=%s avg_ms=%s p50_ms=%s p95_ms=%s avg_bytes=%s\n' \
    "$total" "$pass" "$fail" "$unknown" "$reverts" "$avg_ms" "$p50_ms" "$p95_ms" "$avg_bytes"
}

_doey_reviewer_pct() {
  local num="$1" den="$2"
  [ -z "$den" ] || [ "$den" = "0" ] && { printf '0.0'; return; }
  awk -v n="$num" -v d="$den" 'BEGIN { printf "%.1f", (n/d)*100 }'
}

doey_reviewer_stats() {
  local last_n=50
  while [ $# -gt 0 ]; do
    case "$1" in
      --last)
        shift
        last_n="${1:-50}"
        ;;
      --last=*) last_n="${1#--last=}" ;;
      -h|--help)
        cat <<'H'
Usage: doey reviewer stats [--last N]

Print aggregate reviewer metrics from the Phase 0 store. Default N=50.

Reads both stores:
  runtime:    /tmp/doey/<project>/metrics/reviews.jsonl
  persistent: <project>/.doey/metrics/reviews.jsonl
H
        return 0
        ;;
      *) ;;
    esac
    shift || true
  done
  case "$last_n" in ''|*[!0-9]*) last_n=50 ;; esac

  local paths project_dir runtime_dir
  paths=$(_doey_reviewer_resolve_paths)
  project_dir=$(printf '%s\n' "$paths" | sed -n '1p')
  runtime_dir=$(printf '%s\n' "$paths" | sed -n '2p')

  if [ -z "${DOEY_REVIEWER_METRICS_LIB:-}" ]; then
    local _lib=""
    for _cand in "$(dirname "${BASH_SOURCE[0]}")/doey-review-metrics.sh" \
                 "$HOME/.local/bin/doey-review-metrics.sh"; do
      [ -f "$_cand" ] && { _lib="$_cand"; break; }
    done
    [ -n "$_lib" ] && . "$_lib"
  fi

  local runtime_file="" persist_file=""
  if type doey_review_metrics_paths >/dev/null 2>&1; then
    local _mp
    _mp=$(doey_review_metrics_paths "$project_dir" "$runtime_dir")
    runtime_file=$(printf '%s\n' "$_mp" | sed -n '1p')
    persist_file=$(printf '%s\n' "$_mp" | sed -n '2p')
  else
    [ -n "$runtime_dir" ] && runtime_file="${runtime_dir}/metrics/reviews.jsonl"
    [ -n "$project_dir" ] && persist_file="${project_dir}/.doey/metrics/reviews.jsonl"
  fi

  local rows
  rows=$(_doey_reviewer_merge_rows "$runtime_file" "$persist_file" "$last_n")

  local stats_line
  stats_line=$(_doey_reviewer_stats_compute "$rows")

  local total pass fail unknown reverts avg_ms p50_ms p95_ms avg_bytes
  total=$(  printf '%s' "$stats_line" | sed -n 's/.*total=\([^ ]*\).*/\1/p')
  pass=$(   printf '%s' "$stats_line" | sed -n 's/.*pass=\([^ ]*\).*/\1/p')
  fail=$(   printf '%s' "$stats_line" | sed -n 's/.*fail=\([^ ]*\).*/\1/p')
  unknown=$(printf '%s' "$stats_line" | sed -n 's/.*unknown=\([^ ]*\).*/\1/p')
  reverts=$(printf '%s' "$stats_line" | sed -n 's/.*reverts=\([^ ]*\).*/\1/p')
  avg_ms=$( printf '%s' "$stats_line" | sed -n 's/.*avg_ms=\([^ ]*\).*/\1/p')
  p50_ms=$( printf '%s' "$stats_line" | sed -n 's/.*p50_ms=\([^ ]*\).*/\1/p')
  p95_ms=$( printf '%s' "$stats_line" | sed -n 's/.*p95_ms=\([^ ]*\).*/\1/p')
  avg_bytes=$(printf '%s' "$stats_line" | sed -n 's/.*avg_bytes=\([^ ]*\).*/\1/p')

  local pass_pct fail_pct revert_pass_pct
  pass_pct=$(_doey_reviewer_pct "$pass" "$total")
  fail_pct=$(_doey_reviewer_pct "$fail" "$total")
  revert_pass_pct=$(_doey_reviewer_pct "$reverts" "${pass:-0}")

  printf '\nDoey reviewer metrics — last %s rows\n' "$last_n"
  printf '  runtime:    %s\n' "${runtime_file:-<unset>}"
  printf '  persistent: %s\n' "${persist_file:-<unset>}"
  printf '\n'
  printf '  %-22s %s\n' "Total reviews:"      "${total:-0}"
  printf '  %-22s %s (%s%%)\n' "PASS:"         "${pass:-0}"    "$pass_pct"
  printf '  %-22s %s (%s%%)\n' "FAIL:"         "${fail:-0}"    "$fail_pct"
  printf '  %-22s %s\n' "UNKNOWN:"              "${unknown:-0}"
  printf '  %-22s %s (%s%% of PASSes)\n' "Reverts after PASS:" "${reverts:-0}" "$revert_pass_pct"
  printf '  %-22s %s ms\n' "Avg latency:"       "${avg_ms:-0}"
  printf '  %-22s %s ms\n' "p50 latency:"       "${p50_ms:-0}"
  printf '  %-22s %s ms\n' "p95 latency:"       "${p95_ms:-0}"
  printf '  %-22s %s\n' "Avg payload bytes:"    "${avg_bytes:-0}"
  printf '\n'
  return 0
}

doey_reviewer() {
  local sub="${1:-stats}"
  shift || true
  case "$sub" in
    stats) doey_reviewer_stats "$@" ;;
    -h|--help|help)
      cat <<'H'
Usage: doey reviewer <subcommand>

Subcommands:
  stats [--last N]   Print reviewer metrics from the Phase 0 store
H
      ;;
    *)
      printf 'doey reviewer: unknown subcommand: %s\n' "$sub" >&2
      return 2
      ;;
  esac
}
