#!/usr/bin/env bash
# Tests for doey_scrub_secrets function in .claude/hooks/stop-results.sh
# Verifies each secret pattern is redacted and normal text is untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_FILE="$ROOT_DIR/.claude/hooks/stop-results.sh"

if [ ! -f "$HOOK_FILE" ]; then
  echo "FAIL: hook file not found at $HOOK_FILE"
  exit 1
fi

# Extract the doey_scrub_secrets function from stop-results.sh and eval it
# in this shell. Avoids sourcing the full hook (which exits on is_worker check).
FN_SRC=$(awk '
  /^doey_scrub_secrets\(\)/ {flag=1}
  flag {print}
  flag && /^}$/ {flag=0; exit}
' "$HOOK_FILE")

if [ -z "$FN_SRC" ]; then
  echo "FAIL: could not extract doey_scrub_secrets function from $HOOK_FILE"
  exit 1
fi

eval "$FN_SRC"

pass=0
fail=0

check() {
  local name="$1" input="$2" expect_kind="$3" leak_str="$4"
  local out
  out=$(printf '%s\n' "$input" | doey_scrub_secrets)
  if ! printf '%s' "$out" | grep -q "REDACTED:${expect_kind}"; then
    echo "FAIL: $name — missing [REDACTED:${expect_kind}]"
    echo "       input:  $input"
    echo "       output: $out"
    fail=$((fail + 1))
    return
  fi
  if printf '%s' "$out" | grep -qF "$leak_str"; then
    echo "FAIL: $name — secret leaked through"
    echo "       output: $out"
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $name"
  pass=$((pass + 1))
}

check "OpenAI/Anthropic sk- key" \
  "api_key=sk-abcdefghijklmnopqrstuvwxyz0123" \
  "openai" \
  "sk-abcdefghijklmnopqrstuvwxyz0123"

check "GitHub ghp_ token" \
  "token ghp_abcdefghijklmnopqrstuvwxyz0123" \
  "github" \
  "ghp_abcdefghijklmnopqrstuvwxyz0123"

check "GitHub gho_ token" \
  "gho_abcdefghijklmnopqrstuvwxyz0123" \
  "github" \
  "gho_abcdefghijklmnopqrstuvwxyz0123"

check "GitHub ghu_ token" \
  "ghu_abcdefghijklmnopqrstuvwxyz0123" \
  "github" \
  "ghu_abcdefghijklmnopqrstuvwxyz0123"

check "GitHub ghs_ token" \
  "ghs_abcdefghijklmnopqrstuvwxyz0123" \
  "github" \
  "ghs_abcdefghijklmnopqrstuvwxyz0123"

check "GitHub ghr_ token" \
  "ghr_abcdefghijklmnopqrstuvwxyz0123" \
  "github" \
  "ghr_abcdefghijklmnopqrstuvwxyz0123"

check "Slack xoxb- token" \
  "SLACK=xoxb-1234567890-abcdefghij" \
  "slack" \
  "xoxb-1234567890-abcdefghij"

check "Slack xoxp- token" \
  "xoxp-1234567890-abcdefghij" \
  "slack" \
  "xoxp-1234567890-abcdefghij"

check "AWS access key (AKIA)" \
  "aws key: AKIAIOSFODNN7EXAMPLE" \
  "aws-key" \
  "AKIAIOSFODNN7EXAMPLE"

check "AWS secret key (40-char base64)" \
  'aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"' \
  "aws-secret" \
  "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

check "Bearer token" \
  "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123" \
  "bearer" \
  "abcdefghijklmnopqrstuvwxyz0123"

check "Generic API_KEY=" \
  "API_KEY=super-secret-value-here" \
  "envvar" \
  "super-secret-value-here"

check "Generic SECRET=" \
  "SECRET=do-not-tell-anyone" \
  "envvar" \
  "do-not-tell-anyone"

check "Generic TOKEN=" \
  "TOKEN=shhhhh" \
  "envvar" \
  "shhhhh"

check "Generic PASSWORD=" \
  "PASSWORD=correcthorsebatterystaple" \
  "envvar" \
  "correcthorsebatterystaple"

# Normal text must be untouched.
NORMAL_INPUT="$(printf 'normal build output\nfile.go:42:23 error: something\nbash -n script.sh\nexit 0\npath: /usr/local/bin\n')"
NORMAL_OUT=$(printf '%s' "$NORMAL_INPUT" | doey_scrub_secrets)
if [ "$NORMAL_OUT" = "$NORMAL_INPUT" ]; then
  echo "PASS: normal text untouched"
  pass=$((pass + 1))
else
  echo "FAIL: normal text altered"
  echo "       input:  $NORMAL_INPUT"
  echo "       output: $NORMAL_OUT"
  fail=$((fail + 1))
fi

# Short strings that look similar but don't match (below min length) must be untouched.
SHORT_INPUT="sk-short ghp_short Bearer short"
SHORT_OUT=$(printf '%s' "$SHORT_INPUT" | doey_scrub_secrets)
if [ "$SHORT_OUT" = "$SHORT_INPUT" ]; then
  echo "PASS: short non-secret lookalikes untouched"
  pass=$((pass + 1))
else
  echo "FAIL: short lookalikes altered: $SHORT_OUT"
  fail=$((fail + 1))
fi

echo ""
echo "Result: ${pass} passed, ${fail} failed"
[ "$fail" = "0" ]
