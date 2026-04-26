#!/usr/bin/env bash
# tests/test-chain-bypass-block.sh — task 618 regression
# Verifies on-pre-tool-use.sh blocks non-Boss → 0.1 send-keys for:
#   - Subtaskmaster (TEAM_LEAD, window >= 2)
#   - Deployment (1.2)
#   - Doey Expert (1.3)
#   - Worker (window >= 2, pane >= 1)  — already enforced (regression check)
# And allows:
#   - Taskmaster (coordinator) → 0.1
#   - Subtaskmaster → Taskmaster (1.0)
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/on-pre-tool-use.sh"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable"; exit 1; }

TMP_RT="/tmp/doey/test-$$"
mkdir -p "$TMP_RT/status" "$TMP_RT/errors" "$TMP_RT/lifecycle" "$TMP_RT/messages" "$TMP_RT/triggers"

PASS=0
FAIL=0

_run_role() {
  local _role="$1" _win="$2" _pane="$3" _target="$4" _expect="$5" _name="$6"
  local _input
  _input=$(printf '{"tool_name":"Bash","tool_input":{"command":"tmux send-keys -t %s hello Enter"}}' "$_target")
  local _out _ec
  # Unset TMUX_PANE so the hook does not pull live tmux pane metadata —
  # we drive the role purely from DOEY_ROLE env to keep the test deterministic.
  # NB: env-var prefix on a pipeline applies to the FIRST command, so we feed
  # the hook directly via here-string instead of `printf | hook`.
  set +e
  _out=$( unset TMUX_PANE TMUX; \
          DOEY_ROLE="$_role" \
          DOEY_WINDOW_INDEX="$_win" \
          DOEY_PANE_INDEX="$_pane" \
          DOEY_PANE_ID="d-w${_win}-p${_pane}" \
          DOEY_TASKMASTER_PANE="1.0" \
          SESSION_NAME="doey-test" \
          DOEY_RUNTIME="$TMP_RT" \
          "$HOOK" <<< "$_input" 2>&1 )
  _ec=$?
  set -e
  if [ "$_expect" = "block" ] && [ "$_ec" = "2" ]; then
    PASS=$((PASS+1)); printf '  PASS: %s (blocked as expected, exit=2)\n' "$_name"
  elif [ "$_expect" = "allow" ] && [ "$_ec" = "0" ]; then
    PASS=$((PASS+1)); printf '  PASS: %s (allowed as expected, exit=0)\n' "$_name"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL: %s (expect=%s got_ec=%s)\n' "$_name" "$_expect" "$_ec"
    printf '        out=%s\n' "${_out:0:200}"
  fi
}

echo "Running chain-bypass regression tests (task #618)..."
echo

# Subtaskmaster (team_lead) at 2.0 → 0.1 must BLOCK
_run_role "team_lead"   "2" "0" "doey-test:0.1" "block" "Subtaskmaster -> 0.1"
# Deployment at 1.2 → 0.1 must BLOCK
_run_role "deployment"  "1" "2" "doey-test:0.1" "block" "Deployment -> 0.1"
# Doey Expert at 1.3 → 0.1 must BLOCK
_run_role "doey_expert" "1" "3" "doey-test:0.1" "block" "DoeyExpert -> 0.1"
# Worker at 2.1 → 0.1 must BLOCK (already enforced; regression)
_run_role "worker"      "2" "1" "doey-test:0.1" "block" "Worker -> 0.1 (regression)"
# Taskmaster (coordinator) at 1.0 → 0.1 must ALLOW (sanctioned chain)
_run_role "coordinator" "1" "0" "doey-test:0.1" "allow" "Taskmaster -> 0.1 (allowed)"
# Subtaskmaster (team_lead) at 2.0 → 1.0 must ALLOW (legit chain)
_run_role "team_lead"   "2" "0" "doey-test:1.0" "allow" "Subtaskmaster -> 1.0 (allowed)"

# Cleanup
rm -rf "$TMP_RT" 2>/dev/null || true

echo
printf 'RESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
