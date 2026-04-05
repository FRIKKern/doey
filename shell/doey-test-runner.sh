#!/usr/bin/env bash
# doey-test-runner.sh — E2E test runner: sandbox creation, test launch, result reporting.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_test_runner_sourced:-}" = "1" ] && return 0
__doey_test_runner_sourced=1

# ── Dependencies ────────────────────────────────────────────────────
# Expects doey-helpers.sh and doey-ui.sh to be sourced by caller.
# Expects these globals from doey.sh: PROJECTS_FILE
# Expects these functions from doey.sh: install_doey_hooks, launch_session_headless

# ── Named Test Suites ──────────────────────────────────────────────

# Route named test suites (e.g. `doey test dispatch`).
# Returns 0 if a suite was matched (and exec'd), 1 otherwise.
_run_named_test_suite() {
  local suite="${1:-}"
  case "$suite" in
    dispatch)
      local _repo_dir
      _repo_dir="$(resolve_repo_dir)"
      local _test_script="${_repo_dir}/tests/test-dispatch-chain.sh"
      if [ ! -f "$_test_script" ]; then
        doey_error "Test script not found: $_test_script"
        return 1
      fi
      exec bash "$_test_script"
      ;;
    *)
      return 1
      ;;
  esac
}

# ── Test Sandbox ───────────────────────────────────────────────────

# Create a temporary sandbox project for E2E testing.
# Sets variables: test_id, test_root, project_dir, report_file, test_project_name, session
_create_test_sandbox() {
  local grid="$1"

  test_id="e2e-test-$(date +%s)"
  test_root="/tmp/doey-test/${test_id}"
  project_dir="${test_root}/project"
  report_file="${test_root}/report.md"
  local last8="${test_id: -8}"
  test_project_name="e2e-test-${last8}"
  session="doey-${test_project_name}"

  doey_header "Doey — E2E Test"
  printf '\n'
  doey_info "Test ID    ${test_id}"
  doey_info "Grid       ${grid}"
  doey_info "Sandbox    ${project_dir}"
  doey_info "Report     ${report_file}"
  printf '\n'

  doey_step "1/6" "Creating sandbox project..."
  mkdir -p "${project_dir}/.claude/hooks"
  cd "$project_dir"
  git init -q
  printf '# E2E Test Sandbox\n\nThis project was created by `doey test` for automated testing.\n' > README.md
  printf 'E2E Test Sandbox - build whatever is requested\n' > CLAUDE.md
  install_doey_hooks "$project_dir" "  "
  git add -A && git commit -q -m "Initial sandbox commit"
  doey_ok "Sandbox created"

  doey_step "2/6" "Registering sandbox..."
  echo "${test_project_name}:${project_dir}" >> "$PROJECTS_FILE"
  doey_ok "Registered ${test_project_name}"
}

# ── Wait for Boot ──────────────────────────────────────────────────

# Wait for the Taskmaster to report BUSY or READY (up to 60s).
_wait_for_taskmaster_boot() {
  local test_project_name="$1" session="$2"

  doey_step "4/6" "Waiting for Taskmaster boot..."
  local _wait_count=0
  local _safe_session="${session//[-:.]/_}"
  local _tm_status="${TMPDIR:-/tmp}/doey/${test_project_name}/status/${_safe_session}_0_2.status"
  while [ "$_wait_count" -lt 30 ]; do
    if [ -f "$_tm_status" ]; then
      local _tm_state
      _tm_state="$(cat "$_tm_status" 2>/dev/null || true)"
      case "$_tm_state" in
        BUSY|READY) break ;;
      esac
    fi
    sleep 2
    _wait_count=$((_wait_count + 1))
  done
  if [ "$_wait_count" -ge 30 ]; then
    doey_warn "Taskmaster did not report ready within 60s — continuing anyway"
  fi
  doey_ok "Boot complete"
}

# ── Test Result Reporting ──────────────────────────────────────────

# Print test results and optionally open the report.
_report_test_results() {
  local report_file="$1" open="$2"

  doey_step "6/6" "Results"
  if [ -f "$report_file" ]; then
    local result_color="$ERROR" result_text="TEST FAILED"
    grep -q "Result: PASS" "$report_file" 2>/dev/null && { result_color="$SUCCESS"; result_text="TEST PASSED"; }
    printf '\n  %s══════ %s ══════%s\n\n' "$result_color" "$result_text" "$RESET"
    doey_info "Report: ${report_file}"
  else
    doey_warn "No report generated"
  fi

  if [ "$open" = true ]; then open "${project_dir}/index.html" 2>/dev/null || true; fi
}

# ── Test Cleanup ───────────────────────────────────────────────────

# Clean up test sandbox or print inspection info.
_cleanup_test() {
  local keep="$1" session="$2" test_project_name="$3" test_root="$4" project_dir="$5" report_file="$6"

  if [ "$keep" = false ]; then
    doey_info "Cleaning up..."
    tmux kill-session -t "$session" 2>/dev/null || true
    grep -v "^${test_project_name}:" "$PROJECTS_FILE" > "${PROJECTS_FILE}.tmp" && mv "${PROJECTS_FILE}.tmp" "$PROJECTS_FILE"
    rm -rf "$test_root"
    doey_ok "Cleaned up"
  else
    printf '\n  %sKept for inspection:%s\n' "$BOLD" "$RESET"
    printf "    ${DIM}Session${RESET}   tmux attach -t ${session}\n"
    printf "    ${DIM}Sandbox${RESET}   ${project_dir}\n"
    printf "    ${DIM}Runtime${RESET}   ${TMPDIR:-/tmp}/doey/${test_project_name}\n"
    printf "    ${DIM}Report${RESET}    ${report_file}\n\n"
  fi
}

# ── Main Entry Point ──────────────────────────────────────────────

run_test() {
  # Route named test suites before processing E2E flags
  if _run_named_test_suite "${1:-}"; then
    return 0
  fi

  local keep=false open=false grid="3x2"
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep) keep=true; shift ;;
      --open) open=true; shift ;;
      --grid) grid="$2"; shift 2 ;;
      [0-9]*x[0-9]*) grid="$1"; shift ;;
      *) doey_error "Unknown test flag: $1"; return 1 ;;
    esac
  done

  # Sandbox variables — set by _create_test_sandbox
  local test_id test_root project_dir report_file test_project_name session
  _create_test_sandbox "$grid"

  doey_step "3/6" "Launching team..."
  launch_session_headless "$test_project_name" "$project_dir" "$grid"

  _wait_for_taskmaster_boot "$test_project_name" "$session"

  doey_step "5/6" "Launching test driver..."
  local repo_dir
  repo_dir="$(resolve_repo_dir)"
  local journey_file="${repo_dir}/tests/e2e/journey.md"
  if [ ! -f "$journey_file" ]; then
    doey_error "Journey file not found: $journey_file"
    return 1
  fi
  mkdir -p "${test_root}/observations"
  doey_info "Watch live: tmux attach -t ${session}"
  printf '\n'

  claude --dangerously-skip-permissions --agent test-driver --model opus \
    "Run the E2E test. Session: ${session}. Project name: ${test_project_name}. Project dir: ${project_dir}. Runtime dir: ${TMPDIR:-/tmp}/doey/${test_project_name}. Journey file: ${journey_file}. Observations dir: ${test_root}/observations. Report file: ${report_file}. Test ID: ${test_id}"

  printf '\n'
  _report_test_results "$report_file" "$open"
  _cleanup_test "$keep" "$session" "$test_project_name" "$test_root" "$project_dir" "$report_file"
}
