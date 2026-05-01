#!/usr/bin/env bash
# tests/test-silent-fail-detector.sh — synthetic-fixture coverage for R-1, R-3, R-11, R-14, R-15, R-16, R-17.
set -euo pipefail

DETECTOR="/home/doey/doey/shell/silent-fail-detector.sh"
[ -x "$DETECTOR" ] || { echo "FAIL: detector not executable at $DETECTOR"; exit 1; }

PASS=0
FAIL=0
FAILED_NAMES=""

assert_pass() {
  local name="$1"; PASS=$((PASS+1))
  printf '  PASS  %s\n' "$name"
}
assert_fail() {
  local name="$1" reason="$2"; FAIL=$((FAIL+1))
  FAILED_NAMES="$FAILED_NAMES $name"
  printf '  FAIL  %s — %s\n' "$name" "$reason"
}

# Each scenario builds an isolated sandbox.
make_sandbox() {
  local root
  root=$(mktemp -d 2>/dev/null || mktemp -d -t detector)
  mkdir -p "$root/runtime/status" "$root/runtime/results" "$root/runtime/findings"
  mkdir -p "$root/bin" "$root/capture"
  # tmux stub: list-panes returns canned roster, capture-pane reads from $root/capture/W.P.txt
  cat > "$root/bin/tmux" <<'STUB'
#!/usr/bin/env bash
# Minimal tmux stub. Honors STUB_DIR for fixture root.
STUB_DIR="${STUB_DIR:-}"
sub="${1:-}"
shift || true
case "$sub" in
  list-panes)
    if [ -f "$STUB_DIR/list-panes.txt" ]; then
      cat "$STUB_DIR/list-panes.txt"
    else
      echo "doey-test:2.1"
      echo "doey-test:2.2"
      echo "doey-test:3.1"
    fi
    ;;
  capture-pane)
    target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    pane="${target##*:}"
    f="$STUB_DIR/capture/$pane.txt"
    if [ -f "$f" ]; then cat "$f"; fi
    ;;
  *) ;;
esac
STUB
  chmod +x "$root/bin/tmux"
  # doey-ctl stub: serves last_output_age_sec from $STUB_DIR/observe-age.txt.
  # If the file is missing the stub exits 1 (the detector must then treat the
  # signal as stale per its fail-safe semantics).
  cat > "$root/bin/doey-ctl" <<'OBS'
#!/usr/bin/env bash
STUB_DIR="${STUB_DIR:-}"
sub="${1:-}"; sub2="${2:-}"
if [ "$sub" = "status" ] && [ "$sub2" = "observe" ]; then
  age_file="$STUB_DIR/observe-age.txt"
  if [ -f "$age_file" ]; then
    age=$(cat "$age_file")
    printf '{"active":true,"indicator":"idle","last_output_age_sec":%s}\n' "$age"
    exit 0
  fi
  exit 1
fi
exit 0
OBS
  chmod +x "$root/bin/doey-ctl"
  echo "$root"
}

run_once() {
  local root="$1"
  # Default project dir to a non-existent path so R-17 returns early on
  # tests that don't exercise it (avoids reading the real .doey/tasks).
  local proj="${2:-$root/__no_project__}"
  STUB_DIR="$root" \
  PATH="$root/bin:$PATH" \
  RUNTIME_DIR="$root/runtime" \
  DOEY_SESSION="doey-test" \
  DOEY_PROJECT_DIR="$proj" \
    bash "$DETECTOR" once
}

count_findings() {
  local root="$1" rule="$2" n=0 f
  for f in "$root/runtime/findings/${rule}-"*.json; do
    [ -f "$f" ] || continue
    n=$((n+1))
  done
  echo "$n"
}

# ─── R-1 detect ───
test_r1_detect() {
  local s; s=$(make_sandbox)
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $(($(date +%s) - 30))
EOF
  cat > "$s/capture/2.1.txt" <<EOF
some prior output
[Pasted text #2 +5 lines]
❯
EOF
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-1")
  if [ "$n" -ge 1 ]; then assert_pass "R-1 detect"; else assert_fail "R-1 detect" "expected ≥1 R-1 finding, got $n"; fi
  rm -rf "$s"
}

# ─── R-1 no-fire (BUSY + fresh mtime) ───
test_r1_nofire_busy() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: BUSY
UPDATED: $now
EOF
  # touch fresh
  touch "$s/runtime/status/2_1.status"
  cat > "$s/capture/2.1.txt" <<EOF
[Pasted text #1 +5 lines]
EOF
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-1")
  if [ "$n" -eq 0 ]; then assert_pass "R-1 no-fire (BUSY fresh)"; else assert_fail "R-1 no-fire" "got $n findings"; fi
  rm -rf "$s"
}

# ─── R-3 detect (skew >120) ───
test_r3_detect() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local upd=$((now - 300))
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $upd
EOF
  touch "$s/runtime/status/2_1.heartbeat"
  # Backdate status file mtime so spawn-grace passes.
  touch -d "@$upd" "$s/runtime/status/2_1.status" 2>/dev/null || touch -t "$(date -r "$upd" +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$s/runtime/status/2_1.status" 2>/dev/null || true
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-3")
  if [ "$n" -ge 1 ]; then assert_pass "R-3 detect"; else assert_fail "R-3 detect" "expected ≥1 R-3, got $n"; fi
  rm -rf "$s"
}

# ─── R-3 no-fire (both fresh) ───
test_r3_nofire_fresh() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local recent=$((now - 90))
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $recent
EOF
  touch "$s/runtime/status/2_1.heartbeat"
  # backdate both files past spawn-grace, but with matching mtimes ⇒ low skew
  touch -d "@$recent" "$s/runtime/status/2_1.status" 2>/dev/null || true
  touch -d "@$recent" "$s/runtime/status/2_1.heartbeat" 2>/dev/null || true
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-3")
  if [ "$n" -eq 0 ]; then assert_pass "R-3 no-fire (both fresh)"; else assert_fail "R-3 no-fire fresh" "got $n findings"; fi
  rm -rf "$s"
}

# ─── R-3 no-fire (spawn-grace, <60s) ───
test_r3_nofire_grace() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local upd=$((now - 300))
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $upd
EOF
  touch "$s/runtime/status/2_1.heartbeat"
  # Both files freshly created (<60s old) ⇒ grace should suppress.
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-3")
  if [ "$n" -eq 0 ]; then assert_pass "R-3 no-fire (spawn grace)"; else assert_fail "R-3 no-fire grace" "got $n findings"; fi
  rm -rf "$s"
}

# ─── R-11 detect ───
test_r11_detect() {
  local s; s=$(make_sandbox)
  command -v jq >/dev/null 2>&1 || { assert_pass "R-11 detect (skipped: no jq)"; rm -rf "$s"; return 0; }
  local now; now=$(date +%s)
  printf '2_1 %s\n' "$now" > "$s/runtime/spawn.log"
  cat > "$s/runtime/results/pane_2_1.json" <<EOF
{
  "pane": "2.1",
  "tool_calls": 0,
  "last_output": {"text": "Welcome to Claude Code v2.1.123 — type /help for help"}
}
EOF
  # Live pane still shows the briefing-loss banner in last 30 lines AND
  # last_output_age_sec is fresh (<90s). The freshness gates added in task 671
  # demand both be present for R-11 to fire.
  cat > "$s/capture/2.1.txt" <<EOF
Welcome to Claude Code v2.1.123 — type /help for help

❯
EOF
  printf '5\n' > "$s/observe-age.txt"
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-11")
  if [ "$n" -ge 1 ]; then assert_pass "R-11 detect"; else assert_fail "R-11 detect" "expected ≥1 R-11, got $n"; fi
  rm -rf "$s"
}

# ─── R-11 no-fire (tool_calls > 0) ───
test_r11_nofire() {
  local s; s=$(make_sandbox)
  command -v jq >/dev/null 2>&1 || { assert_pass "R-11 no-fire (skipped: no jq)"; rm -rf "$s"; return 0; }
  local now; now=$(date +%s)
  printf '2_1 %s\n' "$now" > "$s/runtime/spawn.log"
  cat > "$s/runtime/results/pane_2_1.json" <<EOF
{
  "pane": "2.1",
  "tool_calls": 5,
  "last_output": {"text": "Claude Code v2.1.123 banner"}
}
EOF
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-11")
  if [ "$n" -eq 0 ]; then assert_pass "R-11 no-fire (tool_calls>0)"; else assert_fail "R-11 no-fire" "got $n findings"; fi
  rm -rf "$s"
}

# ─── R-11 no-fire (stale scrollback: banner buried far above current activity) ───
# Task 671 — the detector previously refired every dedup-window because it
# only checked the result file's last_output JSON, which can carry a stale
# boot banner long after the pane recovered. Guard: capture-pane last 30 lines
# must contain the banner AND last_output_age_sec < 90s. Here the banner sits
# on lines 1-3 of a 100-line buffer with fresh activity in lines 80-100, and
# last_output_age_sec=300 (well past the 90s gate) — both gates fail, so no
# finding may emit.
test_r11_nofire_stale_scrollback() {
  local s; s=$(make_sandbox)
  command -v jq >/dev/null 2>&1 || { assert_pass "R-11 stale_scrollback (skipped: no jq)"; rm -rf "$s"; return 0; }
  local now; now=$(date +%s)
  printf '2_1 %s\n' "$now" > "$s/runtime/spawn.log"
  cat > "$s/runtime/results/pane_2_1.json" <<EOF
{
  "pane": "2.1",
  "tool_calls": 0,
  "last_output": {"text": "Welcome to Claude Code v2.1.123 — type /help for help"}
}
EOF
  # Banner buried at the top of a 100-line buffer; current activity below.
  {
    printf 'Welcome to Claude Code v2.1.123 — type /help for help\n'
    printf 'briefing line 2\n'
    printf 'briefing line 3\n'
    local i
    for i in $(seq 4 79); do printf 'old scrollback line %s\n' "$i"; done
    for i in $(seq 80 99); do printf '✻ Cogitated for %ss · running task #666\n' "$i"; done
    printf '❯\n'
  } > "$s/capture/2.1.txt"
  printf '300\n' > "$s/observe-age.txt"
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-11")
  if [ "$n" -eq 0 ]; then
    assert_pass "R-11 no-fire (stale scrollback / age=300s)"
  else
    assert_fail "R-11 stale_scrollback" "expected 0, got $n"
  fi
  rm -rf "$s"
}

# ─── R-11 fire (fresh scrollback: banner in last 30 lines + age<90s) ───
# Companion to the stale-scrollback test: when the buried-brief signal IS
# present in the most recent 30 lines AND the pane just stopped (age=10s),
# both freshness gates pass so the detector still emits — confirming the
# guard does NOT suppress legitimate detection of a current failure.
test_r11_fire_fresh_scrollback() {
  local s; s=$(make_sandbox)
  command -v jq >/dev/null 2>&1 || { assert_pass "R-11 fresh_scrollback (skipped: no jq)"; rm -rf "$s"; return 0; }
  local now; now=$(date +%s)
  printf '2_1 %s\n' "$now" > "$s/runtime/spawn.log"
  cat > "$s/runtime/results/pane_2_1.json" <<EOF
{
  "pane": "2.1",
  "tool_calls": 0,
  "last_output": {"text": "Welcome to Claude Code v2.1.123 — type /help for help"}
}
EOF
  # 100-line buffer with the banner on lines 95-100 (well inside the last 30).
  {
    local i
    for i in $(seq 1 94); do printf 'older scrollback line %s\n' "$i"; done
    printf 'Welcome to Claude Code v2.1.123 — type /help for help\n'
    printf '/help for help, /status for status\n'
    printf 'briefing waited for input\n'
    printf '\n'
    printf '\n'
    printf '❯\n'
  } > "$s/capture/2.1.txt"
  printf '10\n' > "$s/observe-age.txt"
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-11")
  if [ "$n" -ge 1 ]; then
    assert_pass "R-11 fire (fresh scrollback / age=10s)"
  else
    assert_fail "R-11 fresh_scrollback" "expected ≥1, got $n"
  fi
  rm -rf "$s"
}

# ─── Idempotency ───
test_idempotency() {
  local s; s=$(make_sandbox)
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $(($(date +%s) - 30))
EOF
  cat > "$s/capture/2.1.txt" <<EOF
[Pasted text #1 +5 lines]
EOF
  run_once "$s" >/dev/null 2>&1
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-1")
  if [ "$n" -eq 1 ]; then assert_pass "idempotency (single R-1 across two ticks)"; else assert_fail "idempotency" "expected 1 R-1, got $n"; fi
  rm -rf "$s"
}

# ─── Dedup window: 3 successive emissions w/ same (rule,pane,evidence) → 1 file ───
test_dedup_3x_same_hash() {
  local s; s=$(make_sandbox)
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $(($(date +%s) - 30))
EOF
  cat > "$s/capture/2.1.txt" <<EOF
[Pasted text #7 +9 lines]
EOF
  run_once "$s" >/dev/null 2>&1
  run_once "$s" >/dev/null 2>&1
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-1")
  # capture trace artifacts so the proof can be inspected
  ls "$s/runtime/findings" >"$s/dedup-trace.txt" 2>/dev/null || true
  if [ "$n" -eq 1 ]; then
    assert_pass "dedup 3x same (rule,pane,evidence) within window → 1 finding"
  else
    assert_fail "dedup 3x" "expected 1 R-1 finding, got $n"
  fi
  rm -rf "$s"
}

# ─── Dedup window: stale finding past window → new emission allowed ───
test_dedup_window_expiry() {
  local s; s=$(make_sandbox)
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $(($(date +%s) - 30))
EOF
  cat > "$s/capture/2.1.txt" <<EOF
[Pasted text #4 +3 lines]
EOF
  # First emission seeds a finding file with current mtime.
  run_once "$s" >/dev/null 2>&1
  local first
  first=$(ls "$s/runtime/findings/R-1-"*.json 2>/dev/null | head -1)
  if [ -z "$first" ]; then assert_fail "dedup window expiry" "no seed finding"; rm -rf "$s"; return 0; fi
  # Rename the seed file so its ts-encoded prefix is old AND backdate mtime
  # past the dedup window (default 60s). Without renaming, a second emission
  # in the same epoch-second as the seed would collide on filename.
  local back=$(($(date +%s) - 120))
  local fp; fp="${first##*-}"; fp="${fp%.json}"
  local aged="$s/runtime/findings/R-1-${back}-${fp}.json"
  mv "$first" "$aged"
  touch -d "@$back" "$aged" 2>/dev/null || \
    touch -t "$(date -r "$back" +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$aged" 2>/dev/null || true
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-1")
  if [ "$n" -eq 2 ]; then
    assert_pass "dedup window expiry (>60s) → new emission"
  else
    assert_fail "dedup window expiry" "expected 2 R-1 findings, got $n"
  fi
  rm -rf "$s"
}

# ─── JSON validity ───
test_json_validity() {
  local s; s=$(make_sandbox)
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $(($(date +%s) - 30))
EOF
  cat > "$s/capture/2.1.txt" <<EOF
[Pasted text #3 +12 lines]
EOF
  run_once "$s" >/dev/null 2>&1
  if ! command -v jq >/dev/null 2>&1; then
    assert_pass "json validity (skipped: no jq)"
    rm -rf "$s"; return 0
  fi
  local f
  f=$(ls "$s/runtime/findings/R-1-"*.json 2>/dev/null | head -1)
  if [ -n "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
    assert_pass "JSON validity (R-1 finding parses)"
  else
    assert_fail "JSON validity" "no parseable R-1 finding emitted"
  fi
  rm -rf "$s"
}

# ─── R-14 tight-loop emits (6 calls/60s, all 0 unread) ───
test_r14_tight_loop_emits() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local i
  : > "$s/runtime/msg-read.log"
  for i in 1 2 3 4 5 6; do
    printf '%s 2.1 0\n' "$((now - 30 + i))" >> "$s/runtime/msg-read.log"
  done
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-14")
  if [ "$n" -ge 1 ]; then assert_pass "R-14 tight_loop_emits"; else assert_fail "R-14 tight_loop_emits" "expected >=1 R-14, got $n"; fi
  rm -rf "$s"
}

# ─── R-14 below threshold (5 calls/60s, all 0) → no emit ───
test_r14_below_threshold_no_emit() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local i
  : > "$s/runtime/msg-read.log"
  for i in 1 2 3 4 5; do
    printf '%s 2.1 0\n' "$((now - 30 + i))" >> "$s/runtime/msg-read.log"
  done
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-14")
  if [ "$n" -eq 0 ]; then assert_pass "R-14 below_threshold_no_emit"; else assert_fail "R-14 below_threshold_no_emit" "got $n findings"; fi
  rm -rf "$s"
}

# ─── R-14 mixed (>=6 calls but at least one nonzero unread) → no emit ───
test_r14_mixed_no_emit() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  : > "$s/runtime/msg-read.log"
  printf '%s 2.1 0\n' "$((now - 30))" >> "$s/runtime/msg-read.log"
  printf '%s 2.1 0\n' "$((now - 25))" >> "$s/runtime/msg-read.log"
  printf '%s 2.1 1\n' "$((now - 20))" >> "$s/runtime/msg-read.log"
  printf '%s 2.1 0\n' "$((now - 15))" >> "$s/runtime/msg-read.log"
  printf '%s 2.1 0\n' "$((now - 10))" >> "$s/runtime/msg-read.log"
  printf '%s 2.1 0\n' "$((now - 5))"  >> "$s/runtime/msg-read.log"
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-14")
  if [ "$n" -eq 0 ]; then assert_pass "R-14 mixed_no_emit"; else assert_fail "R-14 mixed_no_emit" "got $n findings"; fi
  rm -rf "$s"
}

# ─── R-14 dedup within 60s ───
test_r14_dedup_within_60s() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local i
  : > "$s/runtime/msg-read.log"
  for i in 1 2 3 4 5 6; do
    printf '%s 2.1 0\n' "$((now - 30 + i))" >> "$s/runtime/msg-read.log"
  done
  run_once "$s" >/dev/null 2>&1
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-14")
  if [ "$n" -eq 1 ]; then assert_pass "R-14 dedup_within_60s"; else assert_fail "R-14 dedup_within_60s" "expected 1 R-14, got $n"; fi
  rm -rf "$s"
}

# ─── R-14 emits crash_pane marker for Taskmaster intervention ───
test_r14_crash_pane_emitted() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local i
  : > "$s/runtime/msg-read.log"
  for i in 1 2 3 4 5 6 7; do
    printf '%s 2.1 0\n' "$((now - 30 + i))" >> "$s/runtime/msg-read.log"
  done
  run_once "$s" >/dev/null 2>&1
  if [ -f "$s/runtime/status/crash_pane_2_1" ]; then
    if grep -q '^STM_TIGHT_LOOP 2_1 reads=' "$s/runtime/status/crash_pane_2_1"; then
      assert_pass "R-14 crash_pane marker written with STM_TIGHT_LOOP body"
    else
      assert_fail "R-14 crash_pane body" "missing STM_TIGHT_LOOP signature"
    fi
  else
    assert_fail "R-14 crash_pane" "expected crash_pane_2_1 marker"
  fi
  rm -rf "$s"
}

# ─── R-14 no crash_pane on below-threshold ───
test_r14_no_crash_pane_when_below_threshold() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local i
  : > "$s/runtime/msg-read.log"
  for i in 1 2 3 4 5; do
    printf '%s 2.1 0\n' "$((now - 30 + i))" >> "$s/runtime/msg-read.log"
  done
  run_once "$s" >/dev/null 2>&1
  if [ ! -f "$s/runtime/status/crash_pane_2_1" ]; then
    assert_pass "R-14 no crash_pane below threshold"
  else
    assert_fail "R-14 no crash_pane below threshold" "marker should not exist"
  fi
  rm -rf "$s"
}

# ─── R-14 RESERVED pane is skipped ───
test_r14_reserved_skipped() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local i
  : > "$s/runtime/msg-read.log"
  for i in 1 2 3 4 5 6 7; do
    printf '%s 2.1 0\n' "$((now - 30 + i))" >> "$s/runtime/msg-read.log"
  done
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: RESERVED
UPDATED: $now
EOF
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-14")
  if [ "$n" -eq 0 ] && [ ! -f "$s/runtime/status/crash_pane_2_1" ]; then
    assert_pass "R-14 RESERVED pane skipped (no finding, no crash_pane)"
  else
    assert_fail "R-14 RESERVED skipped" "got $n findings, crash_pane_2_1 exists=$([ -f "$s/runtime/status/crash_pane_2_1" ] && echo yes || echo no)"
  fi
  rm -rf "$s"
}

# ─── R-14 crash_pane idempotency: existing marker preserved verbatim ───
test_r14_crash_pane_idempotent() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local i
  : > "$s/runtime/msg-read.log"
  for i in 1 2 3 4 5 6 7; do
    printf '%s 2.1 0\n' "$((now - 30 + i))" >> "$s/runtime/msg-read.log"
  done
  # Pre-existing marker — detector must not overwrite.
  printf 'PRE_EXISTING_MARKER do-not-overwrite\n' > "$s/runtime/status/crash_pane_2_1"
  run_once "$s" >/dev/null 2>&1
  if grep -q '^PRE_EXISTING_MARKER' "$s/runtime/status/crash_pane_2_1"; then
    assert_pass "R-14 crash_pane idempotent (pre-existing marker preserved)"
  else
    assert_fail "R-14 crash_pane idempotent" "marker was overwritten"
  fi
  rm -rf "$s"
}

# ─── R-15 detect (popup line + idle + assigned work + old mtime) ───
test_r15_detect() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local old=$((now - 400))
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $old
EOF
  # Backdate status mtime past the 300s freshness gate.
  touch -d "@$old" "$s/runtime/status/2_1.status" 2>/dev/null || \
    touch -t "$(date -r "$old" +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$s/runtime/status/2_1.status" 2>/dev/null || true
  # Assigned-work signal.
  printf '670\n' > "$s/runtime/status/2_1.task_id"
  cat > "$s/capture/2.1.txt" <<EOF
some prior output
... was that response helpful?
1: Bad    2: Fine   3: Good   0: Dismiss
EOF
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-15")
  if [ "$n" -ge 1 ]; then assert_pass "R-15 detect"; else assert_fail "R-15 detect" "expected ≥1 R-15, got $n"; fi
  rm -rf "$s"
}

# ─── R-15 no-fire (no popup line in capture) ───
test_r15_nofire_no_popup() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local old=$((now - 400))
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $old
EOF
  touch -d "@$old" "$s/runtime/status/2_1.status" 2>/dev/null || true
  printf '670\n' > "$s/runtime/status/2_1.task_id"
  cat > "$s/capture/2.1.txt" <<EOF
some prior output
❯
EOF
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-15")
  if [ "$n" -eq 0 ]; then assert_pass "R-15 no-fire (no popup)"; else assert_fail "R-15 no-fire (no popup)" "got $n findings"; fi
  rm -rf "$s"
}

# ─── R-15 no-fire (popup line present but no assigned work) ───
test_r15_nofire_no_work() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  local old=$((now - 400))
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $old
EOF
  touch -d "@$old" "$s/runtime/status/2_1.status" 2>/dev/null || true
  cat > "$s/capture/2.1.txt" <<EOF
1: Bad    2: Fine   3: Good   0: Dismiss
EOF
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-15")
  if [ "$n" -eq 0 ]; then assert_pass "R-15 no-fire (no assigned work)"; else assert_fail "R-15 no-fire (no work)" "got $n findings"; fi
  rm -rf "$s"
}

# ─── R-16 detect (/clear in scrollback + recent READY transition + old unread msg) ───
test_r16_detect() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $now
EOF
  cat > "$s/capture/2.1.txt" <<EOF
some prior thinking
> /clear
context cleared
❯
EOF
  mkdir -p "$s/runtime/messages"
  local old=$((now - 120))
  printf 'FROM: 0.1\nSUBJECT: review\nplease verify\n' > "$s/runtime/messages/2_1_${old}_1234.msg"
  touch -d "@$old" "$s/runtime/messages/2_1_${old}_1234.msg" 2>/dev/null || true
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-16")
  if [ "$n" -ge 1 ]; then assert_pass "R-16 detect"; else assert_fail "R-16 detect" "expected ≥1 R-16, got $n"; fi
  rm -rf "$s"
}

# ─── R-16 no-fire (/clear alone, no unread msgs) ───
test_r16_nofire_clear_alone() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $now
EOF
  cat > "$s/capture/2.1.txt" <<EOF
> /clear
❯
EOF
  mkdir -p "$s/runtime/messages"
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-16")
  if [ "$n" -eq 0 ]; then assert_pass "R-16 no-fire (/clear alone)"; else assert_fail "R-16 no-fire (/clear alone)" "got $n findings"; fi
  rm -rf "$s"
}

# ─── R-16 no-fire (unread alone, no /clear) ───
test_r16_nofire_unread_alone() {
  local s; s=$(make_sandbox)
  local now; now=$(date +%s)
  cat > "$s/runtime/status/2_1.status" <<EOF
STATUS: READY
UPDATED: $now
EOF
  cat > "$s/capture/2.1.txt" <<EOF
some prior output
❯
EOF
  mkdir -p "$s/runtime/messages"
  local old=$((now - 120))
  printf 'FROM: 0.1\nSUBJECT: review\nplease verify\n' > "$s/runtime/messages/2_1_${old}_1234.msg"
  touch -d "@$old" "$s/runtime/messages/2_1_${old}_1234.msg" 2>/dev/null || true
  run_once "$s" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-16")
  if [ "$n" -eq 0 ]; then assert_pass "R-16 no-fire (unread alone)"; else assert_fail "R-16 no-fire (unread alone)" "got $n findings"; fi
  rm -rf "$s"
}

# ─── R-17 detect (status not done + missing deliverable) ───
test_r17_detect_missing() {
  local s; s=$(make_sandbox)
  mkdir -p "$s/project/.doey/tasks"
  cat > "$s/project/.doey/tasks/999.json" <<EOF
{
  "id": 999,
  "status": "pending_user_confirmation",
  "deliverables": [
    "docs/r17-fixture-missing.md",
    "tests/test-r17-fixture-glob-*.sh"
  ],
  "proof": "PROOF_TYPE=FEATURE_VERIFY"
}
EOF
  run_once "$s" "$s/project" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-17")
  if [ "$n" -ge 1 ]; then
    local f; f=$(ls "$s/runtime/findings/R-17-"*.json 2>/dev/null | head -1)
    if grep -q 'task=999' "$f" && \
       grep -q 'r17-fixture-missing.md' "$f" && \
       grep -Eq 'missing|glob-matched-0-entries' "$f"; then
      assert_pass "R-17 detect (missing deliverables)"
    else
      assert_fail "R-17 detect body" "missing required strings in $f"
    fi
  else
    assert_fail "R-17 detect" "expected ≥1 R-17, got $n"
  fi
  rm -rf "$s"
}

# ─── R-17 no-fire (all deliverables present) ───
test_r17_nofire_all_present() {
  local s; s=$(make_sandbox)
  mkdir -p "$s/project/.doey/tasks" "$s/project/docs" "$s/project/tests"
  touch "$s/project/docs/r17-fixture-present.md"
  touch "$s/project/tests/test-r17-fixture-glob-1.sh"
  cat > "$s/project/.doey/tasks/998.json" <<EOF
{
  "id": 998,
  "status": "pending_user_confirmation",
  "deliverables": [
    "docs/r17-fixture-present.md",
    "tests/test-r17-fixture-glob-*.sh"
  ]
}
EOF
  run_once "$s" "$s/project" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-17")
  if [ "$n" -eq 0 ]; then
    assert_pass "R-17 no-fire (all deliverables present)"
  else
    assert_fail "R-17 no-fire" "got $n findings"
  fi
  rm -rf "$s"
}

# ─── R-17 dedup within 60s ───
test_r17_dedup_within_60s() {
  local s; s=$(make_sandbox)
  mkdir -p "$s/project/.doey/tasks"
  cat > "$s/project/.doey/tasks/996.json" <<EOF
{
  "id": 996,
  "status": "pending_user_confirmation",
  "deliverables": ["docs/r17-fixture-dedup.md"]
}
EOF
  run_once "$s" "$s/project" >/dev/null 2>&1
  run_once "$s" "$s/project" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-17")
  if [ "$n" -eq 1 ]; then
    assert_pass "R-17 dedup (2 ticks → 1 finding)"
  else
    assert_fail "R-17 dedup" "expected 1 R-17, got $n"
  fi
  rm -rf "$s"
}

# ─── R-17 skips done / in_progress ───
# After task 672: only pending_user_confirmation triggers R-17.
# Both done (past gate) and in_progress (no completion claim yet) are skipped.
test_r17_skip_done_status() {
  local s; s=$(make_sandbox)
  mkdir -p "$s/project/.doey/tasks"
  cat > "$s/project/.doey/tasks/995.json" <<EOF
{
  "id": 995,
  "status": "done",
  "deliverables": ["docs/r17-never-existed.md"]
}
EOF
  cat > "$s/project/.doey/tasks/994.json" <<EOF
{
  "id": 994,
  "status": "in_progress",
  "deliverables": ["tui/cmd/r17-never-existed/"]
}
EOF
  run_once "$s" "$s/project" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-17")
  if [ "$n" -eq 0 ]; then
    assert_pass "R-17 skip done / in_progress (only pending_user_confirmation fires)"
  else
    assert_fail "R-17 skip done" "got $n findings"
  fi
  rm -rf "$s"
}

# ─── R-17 fires on .task with structured DELIVERABLES section + missing file ───
# Task 672: claims must come from explicit DELIVERABLES:/FILES:/etc. sections.
test_r17_structured_deliverables_missing() {
  local s; s=$(make_sandbox)
  mkdir -p "$s/project/.doey/tasks"
  cat > "$s/project/.doey/tasks/780.task" <<EOF
TASK_ID=780
TASK_STATUS=pending_user_confirmation
TASK_TITLE=ship widget
TASK_DESCRIPTION=Build the widget feature.

DELIVERABLES:
  - docs/widget-guide.md
  - tests/test-widget.sh
EOF
  run_once "$s" "$s/project" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-17")
  if [ "$n" -ge 1 ]; then
    local f; f=$(ls "$s/runtime/findings/R-17-"*.json 2>/dev/null | head -1)
    if grep -q 'task=780' "$f" && grep -q '"P0"' "$f"; then
      assert_pass "R-17 fires on structured DELIVERABLES + missing file (P0)"
    else
      assert_fail "R-17 structured fire body" "missing strings in $f"
    fi
  else
    assert_fail "R-17 structured fire" "expected ≥1 R-17, got $n"
  fi
  rm -rf "$s"
}

# ─── R-17 ignores path mentions in free-text descriptions ───
# Random path-like tokens in description body must NOT be parsed as claims.
test_r17_ignore_freetext_paths() {
  local s; s=$(make_sandbox)
  mkdir -p "$s/project/.doey/tasks"
  cat > "$s/project/.doey/tasks/781.task" <<EOF
TASK_ID=781
TASK_STATUS=pending_user_confirmation
TASK_TITLE=research notes
TASK_DESCRIPTION=Investigated docs/missing-thing.md as part of analysis.
The error message was: cannot find tests/never-built.sh in source tree.
See also Users/frikk.jarl/Documents/GitHub/doey/old-thing.txt for context.
No actual deliverables were produced.
EOF
  run_once "$s" "$s/project" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-17")
  if [ "$n" -eq 0 ]; then
    assert_pass "R-17 ignores free-text path mentions (no DELIVERABLES section)"
  else
    assert_fail "R-17 freetext_paths" "expected 0 R-17, got $n"
  fi
  rm -rf "$s"
}

# ─── R-17 skips done state even with structured DELIVERABLES + missing ───
# Past-gate: done tasks are not re-validated.
test_r17_done_with_structured_missing() {
  local s; s=$(make_sandbox)
  mkdir -p "$s/project/.doey/tasks"
  cat > "$s/project/.doey/tasks/782.task" <<EOF
TASK_ID=782
TASK_STATUS=done
TASK_TITLE=already shipped
DELIVERABLES:
  - docs/never-existed-but-marked-done.md
  - tests/missing-test.sh
EOF
  run_once "$s" "$s/project" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-17")
  if [ "$n" -eq 0 ]; then
    assert_pass "R-17 skips done state even with structured-missing claims"
  else
    assert_fail "R-17 done_with_structured" "expected 0, got $n"
  fi
  rm -rf "$s"
}

# ─── R-17 skips non-local Users/ macOS workstation paths in DELIVERABLES ───
# A claim that starts with Users/ is a stray macOS path, not a local deliverable.
test_r17_skip_users_macos_path() {
  local s; s=$(make_sandbox)
  mkdir -p "$s/project/.doey/tasks"
  cat > "$s/project/.doey/tasks/783.task" <<EOF
TASK_ID=783
TASK_STATUS=pending_user_confirmation
TASK_TITLE=workstation report
DELIVERABLES:
  - Users/frikk.jarl/Documents/GitHub/doey/tests/test-bash-compat.sh
  - ~/old-stuff/notes.md
  - tmp/transient-artifact.log
EOF
  run_once "$s" "$s/project" >/dev/null 2>&1
  local n; n=$(count_findings "$s" "R-17")
  if [ "$n" -eq 0 ]; then
    assert_pass "R-17 skips non-local claims (Users/, ~/, tmp/)"
  else
    assert_fail "R-17 skip_users_macos" "expected 0, got $n"
  fi
  rm -rf "$s"
}

echo "═══ silent-fail-detector tests ═══"
test_r1_detect
test_r1_nofire_busy
test_r3_detect
test_r3_nofire_fresh
test_r3_nofire_grace
test_r11_detect
test_r11_nofire
test_r11_nofire_stale_scrollback
test_r11_fire_fresh_scrollback
test_idempotency
test_dedup_3x_same_hash
test_dedup_window_expiry
test_json_validity
test_r14_tight_loop_emits
test_r14_below_threshold_no_emit
test_r14_mixed_no_emit
test_r14_dedup_within_60s
test_r14_crash_pane_emitted
test_r14_no_crash_pane_when_below_threshold
test_r14_reserved_skipped
test_r14_crash_pane_idempotent
test_r15_detect
test_r15_nofire_no_popup
test_r15_nofire_no_work
test_r16_detect
test_r16_nofire_clear_alone
test_r16_nofire_unread_alone
test_r17_detect_missing
test_r17_nofire_all_present
test_r17_dedup_within_60s
test_r17_skip_done_status
test_r17_structured_deliverables_missing
test_r17_ignore_freetext_paths
test_r17_done_with_structured_missing
test_r17_skip_users_macos_path

echo "─────────────────────────────────"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed:%s\n' "$FAILED_NAMES"
  exit 1
fi
exit 0
