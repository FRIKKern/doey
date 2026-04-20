#!/usr/bin/env bash
# test-discord-e2e.sh — opt-in real-API probe for `doey-tui discord send`.
#
# Skipped (exit 0) when:
#   - $DOEY_DISCORD_E2E_WEBHOOK is unset or empty
#   - $CI is truthy (1 / true / yes, case-insensitive)
#   - doey-tui binary is not on PATH
#
# When running, this test writes a throwaway XDG config + project binding
# under a mktemp dir, then calls `doey-tui discord send --if-bound` with a
# tiny body on stdin. It asserts exit code 0 but DOES NOT verify delivery —
# that's a manual human-eyes check in Discord. The webhook URL is masked
# before printing (first 32 chars + ellipsis).
#
# Usage:
#   DOEY_DISCORD_E2E_WEBHOOK="https://discord.com/api/webhooks/<id>/<token>" \
#     bash tests/test-discord-e2e.sh
set -euo pipefail

is_truthy() {
  local v="${1:-}"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -z "${DOEY_DISCORD_E2E_WEBHOOK:-}" ]; then
  echo "test-discord-e2e: skipped (DOEY_DISCORD_E2E_WEBHOOK unset)"
  exit 0
fi
if is_truthy "${CI:-}"; then
  echo "test-discord-e2e: skipped (CI is truthy)"
  exit 0
fi
if ! command -v doey-tui >/dev/null 2>&1; then
  echo "test-discord-e2e: skipped (doey-tui not on PATH)"
  exit 0
fi

WEBHOOK="$DOEY_DISCORD_E2E_WEBHOOK"
# Mask: show the first 32 chars + ellipsis. Never print the token segment.
MASKED="$(printf '%s' "$WEBHOOK" | cut -c1-32)…"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/xdg/doey" "$TMPDIR/proj/.doey"

CONF="$TMPDIR/xdg/doey/discord.conf"
{
  printf '%s\n' "[default]"
  printf '%s\n' "kind=webhook"
  printf '%s=%s\n' "webhook_url" "$WEBHOOK"
  printf '%s\n' "label=doey-e2e throwaway"
  printf 'created=%s\n' "$(date +%Y-%m-%d)"
} > "$CONF"
chmod 600 "$CONF"

printf '%s\n' "default" > "$TMPDIR/proj/.doey/discord-binding"

export XDG_CONFIG_HOME="$TMPDIR/xdg"
export PROJECT_DIR="$TMPDIR/proj"

TITLE="doey-e2e-$(date +%s)"
STDERR_LOG="$TMPDIR/stderr.log"

echo "test-discord-e2e: sending probe title=\"$TITLE\" webhook=${MASKED}"

set +e
printf '%s' "e2e probe" | \
  doey-tui discord send \
    --if-bound \
    --title "$TITLE" \
    --event generic \
    --task-id e2e \
    2>"$STDERR_LOG"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "FAIL: doey-tui discord send exited rc=$rc"
  if [ -s "$STDERR_LOG" ]; then
    echo "--- stderr ---"
    cat "$STDERR_LOG"
    echo "--- /stderr ---"
  fi
  exit 1
fi

echo "PASS: probe sent (rc=0). Verify in Discord channel manually."
exit 0
