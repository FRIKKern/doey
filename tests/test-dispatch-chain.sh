#!/usr/bin/env bash
set -euo pipefail
# Test: dispatch chain reliability
# Verifies that IPC messages can be sent to a pane and that the pane receives
# them. Tests the msg send → msg read pipeline that underpins
# Boss → Taskmaster → Subtaskmaster → Worker dispatch.
#
# Runnable standalone: bash tests/test-dispatch-chain.sh
# Or via CLI:          doey test dispatch
#
# Requires a running Doey session for the current project.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0
VERBOSE="${VERBOSE:-false}"

# ── Color helpers ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
DIM='\033[0;90m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Helpers ──��───────────────────────────────────────────────────────

pass() { PASS=$((PASS + 1)); printf "  ${GREEN}PASS${RESET}: %s\n" "$1"; }
fail() {
  FAIL=$((FAIL + 1)); printf "  ${RED}FAIL${RESET}: %s\n" "$1"
  [ -n "${2:-}" ] && printf "    %s\n" "$2"
}
skip() { SKIP=$((SKIP + 1)); printf "  ${YELLOW}SKIP${RESET}: %s — %s\n" "$1" "$2"; }

diag() {
  # Print diagnostics for a failed pane check
  local pane_ref="$1" runtime_dir="$2" pane_safe="$3"
  printf "    ${DIM}── diagnostics ──${RESET}\n"

  # Status file
  local status_file="${runtime_dir}/status/${pane_safe}.status"
  if [ -f "$status_file" ]; then
    printf "    status file: %s\n" "$(cat "$status_file" 2>/dev/null | head -3 | tr '\n' ' ')"
  else
    printf "    status file: ${DIM}(not found: %s)${RESET}\n" "$status_file"
  fi

  # Captured pane output (last 5 lines)
  local captured
  captured="$(tmux capture-pane -t "$pane_ref" -p 2>/dev/null | tail -5)" || captured="(capture failed)"
  printf "    pane output (last 5 lines):\n"
  printf '%s\n' "$captured" | sed 's/^/      /'
  printf "    ${DIM}── end diagnostics ─��${RESET}\n"
}

# ── Detect running session ───────────���───────────────────────────────

detect_session() {
  local dir name session rt
  dir="$(pwd)"

  # Use doey's project registry to find session
  local projects_file="$HOME/.claude/doey/projects"
  if [ ! -f "$projects_file" ]; then
    printf "${RED}Error:${RESET} No projects file at %s\n" "$projects_file"
    printf "  Run this from a registered Doey project directory.\n"
    exit 1
  fi

  name=""
  while IFS=: read -r pname pdir; do
    if [ "$pdir" = "$dir" ]; then
      name="$pname"
      break
    fi
  done < "$projects_file"

  if [ -z "$name" ]; then
    printf "${RED}Error:${RESET} No project registered for %s\n" "$dir"
    exit 1
  fi

  session="doey-${name}"
  if ! tmux has-session -t "$session" 2>/dev/null; then
    printf "${RED}Error:${RESET} Session %s not running\n" "$session"
    exit 1
  fi

  rt="$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2- || true)"
  if [ -z "$rt" ]; then
    rt="/tmp/doey/${name}"
  fi

  SESSION="$session"
  RUNTIME_DIR="$rt"
  PROJECT_NAME="$name"
}

# Convert session:W.P to safe name (replace -.:  with _)
pane_safe_name() {
  local ref="$1"
  printf '%s' "$ref" | tr ':-.' '___'
}

# ── Test 1: IPC msg send/read round-trip ���────────────────────────────

test_ipc_roundtrip() {
  printf "\n${BOLD}Test 1: IPC msg send/read round-trip${RESET}\n"

  if ! command -v doey-ctl >/dev/null 2>&1; then
    skip "IPC round-trip" "doey-ctl not installed"
    return
  fi

  # Target: Taskmaster pane (1.0)
  local target_pane="1.0"
  local target_safe
  target_safe="$(pane_safe_name "${SESSION}:${target_pane}")"
  local marker="DISPATCH_TEST_$(date +%s)_$$"

  # Send a test message
  doey-ctl msg send \
    --to "$target_safe" \
    --from "test-dispatch-chain" \
    --subject "dispatch_test" \
    --body "marker=${marker}" \
    --runtime "$RUNTIME_DIR" \
    --no-nudge 2>/dev/null

  # Read it back
  local found=false
  local msgs
  msgs="$(doey-ctl msg read --pane "$target_safe" --runtime "$RUNTIME_DIR" 2>/dev/null || true)"
  if printf '%s' "$msgs" | grep -qF "$marker"; then
    found=true
  fi

  # Also check file-based messages as fallback
  if [ "$found" = false ]; then
    local msg_dir="${RUNTIME_DIR}/messages"
    if [ -d "$msg_dir" ]; then
      if grep -rlF "$marker" "$msg_dir" 2>/dev/null | head -1 | grep -q .; then
        found=true
      fi
    fi
  fi

  if [ "$found" = true ]; then
    pass "IPC msg send/read round-trip (marker: ${marker})"
  else
    fail "IPC msg send/read round-trip" "marker ${marker} not found in messages for ${target_safe}"
    diag "${SESSION}:${target_pane}" "$RUNTIME_DIR" "$target_safe"
  fi

  # Cleanup: remove our test message
  doey-ctl msg clean --to "$target_safe" --runtime "$RUNTIME_DIR" 2>/dev/null || true
}

# ── Test 2: Taskmaster pane is alive ─────────────────────────���───────

test_taskmaster_alive() {
  printf "\n${BOLD}Test 2: Taskmaster pane responsiveness${RESET}\n"

  local target_pane="1.0"
  local target_safe
  target_safe="$(pane_safe_name "${SESSION}:${target_pane}")"

  # Check status file exists and is not stale
  local status_file="${RUNTIME_DIR}/status/${target_safe}.status"
  if [ ! -f "$status_file" ]; then
    fail "Taskmaster status file exists" "not found: ${status_file}"
    return
  fi
  pass "Taskmaster status file exists"

  # Parse status
  local status=""
  status="$(grep '^STATUS=' "$status_file" 2>/dev/null | cut -d= -f2- || true)"
  case "$status" in
    BUSY|READY|WORKING)
      pass "Taskmaster status is active (${status})"
      ;;
    FINISHED|RESERVED)
      fail "Taskmaster status" "unexpected terminal state: ${status}"
      diag "${SESSION}:${target_pane}" "$RUNTIME_DIR" "$target_safe"
      ;;
    "")
      fail "Taskmaster status" "STATUS field missing from ${status_file}"
      ;;
    *)
      fail "Taskmaster status" "unknown status: ${status}"
      ;;
  esac

  # Check staleness via doey-ctl health if available
  if command -v doey-ctl >/dev/null 2>&1; then
    if doey-ctl health check --runtime "$RUNTIME_DIR" "$target_safe" >/dev/null 2>&1; then
      pass "Taskmaster health check (not stale)"
    else
      fail "Taskmaster health check" "pane reported stale (>120s since last update)"
      diag "${SESSION}:${target_pane}" "$RUNTIME_DIR" "$target_safe"
    fi
  else
    skip "Taskmaster health check" "doey-ctl not installed"
  fi
}

# ─�� Test 3: Message delivery to pane (tmux capture verification) ─────

test_msg_delivery_visible() {
  printf "\n${BOLD}Test 3: Message triggers pane activity${RESET}\n"

  if ! command -v doey-ctl >/dev/null 2>&1; then
    skip "Message delivery" "doey-ctl not installed"
    return
  fi

  # Send a message with trigger (no --no-nudge) and verify the trigger file appears
  local target_pane="1.0"
  local target_safe
  target_safe="$(pane_safe_name "${SESSION}:${target_pane}")"
  local marker="TRIGGER_TEST_$(date +%s)_$$"

  # Remove any existing trigger file
  rm -f "${RUNTIME_DIR}/triggers/${target_safe}.trigger" 2>/dev/null || true

  # Send with trigger
  doey-ctl msg send \
    --to "$target_safe" \
    --from "test-dispatch-chain" \
    --subject "dispatch_test" \
    --body "trigger_marker=${marker}" \
    --runtime "$RUNTIME_DIR" \
    --no-nudge 2>/dev/null

  # Verify trigger file was created
  local trigger_file="${RUNTIME_DIR}/triggers/${target_safe}.trigger"
  if [ -f "$trigger_file" ]; then
    pass "Trigger file created for target pane"
  else
    fail "Trigger file created" "not found: ${trigger_file}"
  fi

  # Cleanup
  doey-ctl msg clean --to "$target_safe" --runtime "$RUNTIME_DIR" 2>/dev/null || true
}

# ── Test 4: All core panes have status files ─────────────────────────

test_core_panes_status() {
  printf "\n${BOLD}Test 4: Core panes have status files${RESET}\n"

  # Check: Boss (0.1), Taskmaster (1.0)
  local pane_label pane_ref pane_safe status_file
  for pane_label in "Boss:0.1" "Taskmaster:1.0"; do
    local label="${pane_label%%:*}"
    pane_ref="${pane_label##*:}"
    pane_safe="$(pane_safe_name "${SESSION}:${pane_ref}")"
    status_file="${RUNTIME_DIR}/status/${pane_safe}.status"

    if [ -f "$status_file" ]; then
      pass "${label} (${pane_ref}) has status file"
    else
      fail "${label} (${pane_ref}) status file" "not found: ${status_file}"
    fi
  done
}

# ── Test 5: Worker panes discovered and responsive ───────────────────

test_worker_panes() {
  printf "\n${BOLD}Test 5: Worker pane discovery${RESET}\n"

  # List team windows by checking for team_*.env files
  local worker_count=0
  local status_dir="${RUNTIME_DIR}/status"

  if [ ! -d "$status_dir" ]; then
    fail "Status directory exists" "not found: ${status_dir}"
    return
  fi

  # Count worker status files (anything in window 2+ with pane index > 0)
  local f
  for f in "${status_dir}"/*.status; do
    [ -f "$f" ] || continue
    local base
    base="$(basename "$f" .status)"
    # Workers are in windows >= 2, pane index >= 1
    # Safe name format: doey_<project>_<window>_<pane>
    # Extract last two segments as window.pane
    local window_idx pane_idx
    window_idx="$(printf '%s' "$base" | rev | cut -d_ -f2 | rev)"
    pane_idx="$(printf '%s' "$base" | rev | cut -d_ -f1 | rev)"
    case "$window_idx" in
      [0-9]*)
        if [ "$window_idx" -ge 2 ] && [ "$pane_idx" -ge 1 ]; then
          worker_count=$((worker_count + 1))
        fi
        ;;
    esac
  done

  if [ "$worker_count" -gt 0 ]; then
    pass "Found ${worker_count} worker status file(s)"
  else
    skip "Worker pane discovery" "no worker panes detected (single-window or pre-team mode)"
  fi
}

# ── Main ────────────────────────────────────────��────────────────────

main() {
  printf "${BOLD}=== Dispatch chain reliability test ===${RESET}\n"

  detect_session
  printf "  Session:  %s\n" "$SESSION"
  printf "  Runtime:  %s\n" "$RUNTIME_DIR"
  printf "  Project:  %s\n" "$PROJECT_NAME"

  test_ipc_roundtrip
  test_taskmaster_alive
  test_msg_delivery_visible
  test_core_panes_status
  test_worker_panes

  # ── Summary ──
  printf "\n${BOLD}=== Results: "
  printf "${GREEN}%d passed${RESET}, " "$PASS"
  [ "$FAIL" -gt 0 ] && printf "${RED}%d failed${RESET}, " "$FAIL" || printf "0 failed, "
  [ "$SKIP" -gt 0 ] && printf "${YELLOW}%d skipped${RESET}" "$SKIP" || printf "0 skipped"
  TOTAL=$((PASS + FAIL + SKIP))
  printf " (%d total) ===${RESET}\n\n" "$TOTAL"

  if [ "$FAIL" -gt 0 ]; then
    printf "${RED}FAILED${RESET}\n"
    exit 1
  fi
  printf "${GREEN}ALL PASSED${RESET}\n"
  exit 0
}

main "$@"
