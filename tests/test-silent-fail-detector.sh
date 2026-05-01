#!/usr/bin/env bash
# tests/test-silent-fail-detector.sh — synthetic-fixture coverage for R-1, R-3, R-11, R-14, R-15, R-16.
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
  echo "$root"
}

run_once() {
  local root="$1"
  STUB_DIR="$root" \
  PATH="$root/bin:$PATH" \
  RUNTIME_DIR="$root/runtime" \
  DOEY_SESSION="doey-test" \
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

echo "═══ silent-fail-detector tests ═══"
test_r1_detect
test_r1_nofire_busy
test_r3_detect
test_r3_nofire_fresh
test_r3_nofire_grace
test_r11_detect
test_r11_nofire
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

echo "─────────────────────────────────"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed:%s\n' "$FAILED_NAMES"
  exit 1
fi
exit 0
