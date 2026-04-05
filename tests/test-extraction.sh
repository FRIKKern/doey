#!/usr/bin/env bash
set -euo pipefail

# test-extraction.sh — Verify every function in doey.sh and shell modules is callable
#
# Sources doey.sh (with __doey_source_only guard) plus all safe-to-source
# modules, then asserts every extracted function is callable via `type`.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHELL_DIR="${PROJECT_ROOT}/shell"

pass=0
fail_count=0
total=0

echo "=== Function Extraction Test ==="
echo ""

# ── Source doey.sh (auto-sources: doey-go-helpers.sh, doey-roles.sh, doey-send.sh)
echo "Sourcing doey.sh..."
source "${SHELL_DIR}/doey.sh" __doey_source_only

# ── Source additional safe modules (pure function/variable definitions)
safe_modules="doey-constants.sh doey-go-check.sh doey-ipc-helpers.sh doey-plan-helpers.sh doey-task-helpers.sh"
for mod in $safe_modules; do
  if [ -f "${SHELL_DIR}/${mod}" ]; then
    echo "Sourcing ${mod}..."
    source "${SHELL_DIR}/${mod}" || true
  fi
done

echo ""

# ── Standalone scripts that cannot be sourced (would hang, exit, or require root)
skip_modules="doey-config-default.sh doey-remote-provision.sh doey-render-task.sh doey-statusline.sh doey-tunnel.sh"

# ── Collect all sourced .sh files to extract functions from
sourced_files="${SHELL_DIR}/doey.sh"
# Modules auto-sourced by doey.sh
for mod in doey-go-helpers.sh doey-helpers.sh doey-ui.sh doey-remote.sh doey-purge.sh doey-update.sh doey-doctor.sh doey-task-cli.sh doey-test-runner.sh doey-grid.sh doey-menu.sh doey-team-mgmt.sh doey-session.sh doey-roles.sh doey-send.sh; do
  [ -f "${SHELL_DIR}/${mod}" ] && sourced_files="${sourced_files} ${SHELL_DIR}/${mod}"
done
# Manually sourced safe modules
for mod in $safe_modules; do
  [ -f "${SHELL_DIR}/${mod}" ] && sourced_files="${sourced_files} ${SHELL_DIR}/${mod}"
done

# ── Extract and test every function
for file in $sourced_files; do
  [ -f "$file" ] || continue
  basename_file="$(basename "$file")"
  # For doey.sh, only extract functions before the __doey_source_only guard
  # (functions after the guard are unreachable when sourcing with the guard)
  if [ "$basename_file" = "doey.sh" ]; then
    guard_line=$(grep -n '__doey_source_only' "$file" | head -1 | cut -d: -f1)
    guard_line="${guard_line:-99999}"
    func_names=$(head -n "$guard_line" "$file" | grep -E '^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*\{' | sed 's/[[:space:]]*().*//' || true)
  else
    func_names=$(grep -E '^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*\{' "$file" | sed 's/[[:space:]]*().*//' || true)
  fi
  [ -z "$func_names" ] && continue

  file_pass=0
  file_fail=0
  while IFS= read -r func; do
    [ -z "$func" ] && continue
    total=$((total + 1))
    if type "$func" >/dev/null 2>&1; then
      file_pass=$((file_pass + 1))
      pass=$((pass + 1))
    else
      echo "FAIL: ${func} (from ${basename_file}) — not callable"
      file_fail=$((file_fail + 1))
      fail_count=$((fail_count + 1))
    fi
  done <<EOF
$func_names
EOF
  echo "  ${basename_file}: ${file_pass} passed, ${file_fail} failed"
done

# ── Report standalone modules (informational)
echo ""
standalone_count=0
for mod in $skip_modules; do
  [ -f "${SHELL_DIR}/${mod}" ] || continue
  count=$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*\{' "${SHELL_DIR}/${mod}" 2>/dev/null) || count=0
  standalone_count=$((standalone_count + count))
  if [ "$count" -gt 0 ]; then
    echo "SKIP: ${mod} (${count} functions) — standalone script, cannot source"
  fi
done

echo ""
echo "=== Extraction Test: ${total} tested, ${pass} passed, ${fail_count} failed, ${standalone_count} standalone (skipped) ==="

if [ "$fail_count" -gt 0 ]; then
  echo "FAIL"
  exit 1
fi
echo "PASS"
exit 0
