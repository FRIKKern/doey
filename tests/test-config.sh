#!/usr/bin/env bash
# test-config.sh — Smoke test for Doey config system
# Tests: config loading hierarchy, .doey/ creation, variable resolution, doey_config subcommand
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; TOTAL=0

_ok()   { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); printf '  \033[32m✔\033[0m %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); printf '  \033[31m✘\033[0m %s\n' "$1"; }

cleanup() {
  rm -rf "$SANDBOX" 2>/dev/null || true
}
trap cleanup EXIT

SANDBOX=$(mktemp -d)
FAKE_HOME="${SANDBOX}/home"
FAKE_PROJECT="${SANDBOX}/project"
mkdir -p "$FAKE_HOME/.config/doey" "$FAKE_HOME/.claude/doey" "$FAKE_PROJECT/.doey"
touch "$FAKE_HOME/.claude/doey/projects"

printf '\n\033[1;36m=== Doey Config Smoke Test ===\033[0m\n\n'

# ── Test 1: Defaults when no config files exist ─────────────────────

printf '\033[1mTest 1: Defaults (no config files)\033[0m\n'
result=$(HOME="$FAKE_HOME" bash -c "
  cd '$FAKE_PROJECT'
  rm -f '$FAKE_HOME/.config/doey/config.sh' '$FAKE_PROJECT/.doey/config.sh'
  SCRIPT_DIR='$REPO_DIR/shell'
  source '$REPO_DIR/shell/doey.sh' __doey_source_only 2>/dev/null || true
  echo \"COLS=\$DOEY_INITIAL_WORKER_COLS\"
  echo \"TEAMS=\$DOEY_INITIAL_TEAMS\"
  echo \"MGR_MODEL=\$DOEY_MANAGER_MODEL\"
  echo \"WKR_MODEL=\$DOEY_WORKER_MODEL\"
  echo \"WDG_MODEL=\$DOEY_WATCHDOG_MODEL\"
  echo \"REFRESH=\$DOEY_INFO_PANEL_REFRESH\"
  echo \"SCAN=\$DOEY_WATCHDOG_SCAN_INTERVAL\"
" 2>/dev/null)

echo "$result" | grep -q 'COLS=3'          && _ok "DOEY_INITIAL_WORKER_COLS defaults to 3"    || _fail "DOEY_INITIAL_WORKER_COLS default (got: $(echo "$result" | grep COLS))"
echo "$result" | grep -q 'TEAMS=2'         && _ok "DOEY_INITIAL_TEAMS defaults to 2"          || _fail "DOEY_INITIAL_TEAMS default (got: $(echo "$result" | grep TEAMS))"
echo "$result" | grep -q 'MGR_MODEL=opus'  && _ok "DOEY_MANAGER_MODEL defaults to opus"       || _fail "DOEY_MANAGER_MODEL default (got: $(echo "$result" | grep MGR))"
echo "$result" | grep -q 'WKR_MODEL=opus' && _ok "DOEY_WORKER_MODEL defaults to opus"     || _fail "DOEY_WORKER_MODEL default (got: $(echo "$result" | grep WKR))"
echo "$result" | grep -q 'WDG_MODEL=sonnet' && _ok "DOEY_WATCHDOG_MODEL defaults to sonnet"     || _fail "DOEY_WATCHDOG_MODEL default (got: $(echo "$result" | grep WDG))"
echo "$result" | grep -q 'REFRESH=300'     && _ok "DOEY_INFO_PANEL_REFRESH defaults to 300"   || _fail "DOEY_INFO_PANEL_REFRESH default (got: $(echo "$result" | grep REFRESH))"
echo "$result" | grep -q 'SCAN=30'         && _ok "DOEY_WATCHDOG_SCAN_INTERVAL defaults to 30" || _fail "DOEY_WATCHDOG_SCAN_INTERVAL default (got: $(echo "$result" | grep SCAN))"

# ── Test 2: Global config overrides defaults ─────────────────────────

printf '\n\033[1mTest 2: Global config overrides defaults\033[0m\n'
cat > "$FAKE_HOME/.config/doey/config.sh" << 'EOF'
DOEY_INITIAL_WORKER_COLS=5
DOEY_MANAGER_MODEL=sonnet
DOEY_WORKER_LAUNCH_DELAY=10
EOF
rm -f "$FAKE_PROJECT/.doey/config.sh"

result=$(HOME="$FAKE_HOME" bash -c "
  cd '$FAKE_PROJECT'
  SCRIPT_DIR='$REPO_DIR/shell'
  source '$REPO_DIR/shell/doey.sh' __doey_source_only 2>/dev/null || true
  echo \"COLS=\$DOEY_INITIAL_WORKER_COLS\"
  echo \"MGR_MODEL=\$DOEY_MANAGER_MODEL\"
  echo \"DELAY=\$DOEY_WORKER_LAUNCH_DELAY\"
  echo \"TEAMS=\$DOEY_INITIAL_TEAMS\"
" 2>/dev/null)

echo "$result" | grep -q 'COLS=5'           && _ok "Global config overrides DOEY_INITIAL_WORKER_COLS to 5" || _fail "Global COLS override (got: $(echo "$result" | grep COLS))"
echo "$result" | grep -q 'MGR_MODEL=sonnet' && _ok "Global config overrides DOEY_MANAGER_MODEL to sonnet"  || _fail "Global MGR_MODEL override (got: $(echo "$result" | grep MGR))"
echo "$result" | grep -q 'DELAY=10'         && _ok "Global config overrides DOEY_WORKER_LAUNCH_DELAY to 10" || _fail "Global DELAY override (got: $(echo "$result" | grep DELAY))"
echo "$result" | grep -q 'TEAMS=2'          && _ok "Unset vars still get default (TEAMS=2)"                 || _fail "Unset var default (got: $(echo "$result" | grep TEAMS))"

# ── Test 3: Project config overrides global ──────────────────────────

printf '\n\033[1mTest 3: Project config overrides global\033[0m\n'
cat > "$FAKE_PROJECT/.doey/config.sh" << 'EOF'
DOEY_INITIAL_WORKER_COLS=8
DOEY_WATCHDOG_MODEL=sonnet
EOF

result=$(HOME="$FAKE_HOME" bash -c "
  cd '$FAKE_PROJECT'
  SCRIPT_DIR='$REPO_DIR/shell'
  source '$REPO_DIR/shell/doey.sh' __doey_source_only 2>/dev/null || true
  echo \"COLS=\$DOEY_INITIAL_WORKER_COLS\"
  echo \"MGR_MODEL=\$DOEY_MANAGER_MODEL\"
  echo \"WDG_MODEL=\$DOEY_WATCHDOG_MODEL\"
  echo \"DELAY=\$DOEY_WORKER_LAUNCH_DELAY\"
" 2>/dev/null)

echo "$result" | grep -q 'COLS=8'           && _ok "Project overrides global COLS (8 > 5)"            || _fail "Project COLS override (got: $(echo "$result" | grep COLS))"
echo "$result" | grep -q 'MGR_MODEL=sonnet' && _ok "Global MGR_MODEL still applies (project didn't set it)" || _fail "Global still applies (got: $(echo "$result" | grep MGR))"
echo "$result" | grep -q 'WDG_MODEL=sonnet' && _ok "Project overrides WDG_MODEL to sonnet"            || _fail "Project WDG_MODEL override (got: $(echo "$result" | grep WDG))"
echo "$result" | grep -q 'DELAY=10'         && _ok "Global DELAY still applies (project didn't set it)" || _fail "Global still applies (got: $(echo "$result" | grep DELAY))"

# ── Test 4: Walk-up finds .doey/config.sh from subdirectory ──────────

printf '\n\033[1mTest 4: Walk-up config discovery from subdirectory\033[0m\n'
mkdir -p "$FAKE_PROJECT/src/deep/nested"

result=$(HOME="$FAKE_HOME" bash -c "
  cd '$FAKE_PROJECT/src/deep/nested'
  SCRIPT_DIR='$REPO_DIR/shell'
  source '$REPO_DIR/shell/doey.sh' __doey_source_only 2>/dev/null || true
  echo \"COLS=\$DOEY_INITIAL_WORKER_COLS\"
  echo \"WDG_MODEL=\$DOEY_WATCHDOG_MODEL\"
" 2>/dev/null)

echo "$result" | grep -q 'COLS=8'           && _ok "Walk-up finds .doey/config.sh from src/deep/nested" || _fail "Walk-up discovery (got: $(echo "$result" | grep COLS))"
echo "$result" | grep -q 'WDG_MODEL=sonnet' && _ok "Project config applied from nested dir"              || _fail "Project config from nested (got: $(echo "$result" | grep WDG))"

# ── Test 5: Env var overrides everything ─────────────────────────────

printf '\n\033[1mTest 5: Config file takes precedence (last-source-wins)\033[0m\n'
# Config files source unconditionally, so project > global > env > defaults
# Test: env var is overridden by project config that sets the same var
result=$(HOME="$FAKE_HOME" DOEY_INITIAL_WORKER_COLS=99 bash -c "
  cd '$FAKE_PROJECT'
  SCRIPT_DIR='$REPO_DIR/shell'
  source '$REPO_DIR/shell/doey.sh' __doey_source_only 2>/dev/null || true
  echo \"COLS=\$DOEY_INITIAL_WORKER_COLS\"
" 2>/dev/null)

echo "$result" | grep -q 'COLS=8' && _ok "Project config (8) overrides env var (99) — last-source-wins" || _fail "Precedence (got: $(echo "$result" | grep COLS))"

# But env var wins for vars NOT set in any config file
result=$(HOME="$FAKE_HOME" DOEY_MAX_WORKERS=50 bash -c "
  cd '$FAKE_PROJECT'
  SCRIPT_DIR='$REPO_DIR/shell'
  source '$REPO_DIR/shell/doey.sh' __doey_source_only 2>/dev/null || true
  echo \"MW=\$DOEY_MAX_WORKERS\"
" 2>/dev/null)

echo "$result" | grep -q 'MW=50' && _ok "Env var wins when not set in config files" || _fail "Env var for unset (got: $(echo "$result" | grep MW))"

# ── Test 6: Config template exists and is valid bash ─────────────────

printf '\n\033[1mTest 6: Config template validation\033[0m\n'
[ -f "$REPO_DIR/shell/doey-config-default.sh" ] && _ok "doey-config-default.sh exists" || _fail "doey-config-default.sh missing"
bash -n "$REPO_DIR/shell/doey-config-default.sh" 2>/dev/null && _ok "Template passes bash -n" || _fail "Template syntax error"

# Check all expected variables are in template
for var in DOEY_INITIAL_WORKER_COLS DOEY_INITIAL_TEAMS DOEY_INITIAL_WORKTREE_TEAMS \
           DOEY_MAX_WORKERS DOEY_WORKER_LAUNCH_DELAY DOEY_TEAM_LAUNCH_DELAY \
           DOEY_MANAGER_MODEL DOEY_WORKER_MODEL DOEY_WATCHDOG_MODEL \
           DOEY_INFO_PANEL_REFRESH DOEY_WATCHDOG_SCAN_INTERVAL \
           DOEY_IDLE_COLLAPSE_AFTER DOEY_IDLE_REMOVE_AFTER DOEY_PASTE_SETTLE_MS; do
  grep -q "$var" "$REPO_DIR/shell/doey-config-default.sh" \
    && _ok "Template has $var" \
    || _fail "Template missing $var"
done

# ── Test 7: Model variables used in launch commands ──────────────────

printf '\n\033[1mTest 7: Hardcoded models eliminated from doey.sh\033[0m\n'
# Should NOT find --model opus or --model haiku in launch commands (except test-driver)
bad_opus=$(grep -n '\-\-model opus' "$REPO_DIR/shell/doey.sh" | grep -v 'test-driver' | grep -v '^#' || true)
bad_haiku=$(grep -n '\-\-model haiku' "$REPO_DIR/shell/doey.sh" | grep -v '^#' || true)

[ -z "$bad_opus" ]  && _ok "No hardcoded --model opus (except test-driver)" || _fail "Found hardcoded --model opus: $bad_opus"
[ -z "$bad_haiku" ] && _ok "No hardcoded --model haiku"                     || _fail "Found hardcoded --model haiku: $bad_haiku"

# Should find $DOEY_MANAGER_MODEL, $DOEY_WORKER_MODEL, $DOEY_WATCHDOG_MODEL in launch commands
grep -q 'DOEY_MANAGER_MODEL' "$REPO_DIR/shell/doey.sh"  && _ok "doey.sh uses \$DOEY_MANAGER_MODEL"  || _fail "doey.sh missing DOEY_MANAGER_MODEL usage"
grep -q 'DOEY_WORKER_MODEL' "$REPO_DIR/shell/doey.sh"   && _ok "doey.sh uses \$DOEY_WORKER_MODEL"   || _fail "doey.sh missing DOEY_WORKER_MODEL usage"
grep -q 'DOEY_WATCHDOG_MODEL' "$REPO_DIR/shell/doey.sh" && _ok "doey.sh uses \$DOEY_WATCHDOG_MODEL" || _fail "doey.sh missing DOEY_WATCHDOG_MODEL usage"

# ── Test 8: Config hierarchy in settings-panel.sh ────────────────────

printf '\n\033[1mTest 8: Settings panel config awareness\033[0m\n'
bash -n "$REPO_DIR/shell/settings-panel.sh" 2>/dev/null && _ok "settings-panel.sh passes bash -n" || _fail "settings-panel.sh syntax error"
grep -q '\.doey/config\.sh' "$REPO_DIR/shell/settings-panel.sh" && _ok "Settings panel checks project config" || _fail "Settings panel missing project config check"

# ── Test 9: Info panel uses configurable refresh ─────────────────────

printf '\n\033[1mTest 9: Info panel configurable refresh\033[0m\n'
grep -q 'DOEY_INFO_PANEL_REFRESH' "$REPO_DIR/shell/info-panel.sh" && _ok "info-panel.sh uses DOEY_INFO_PANEL_REFRESH" || _fail "info-panel.sh missing DOEY_INFO_PANEL_REFRESH"
! grep -q 'sleep 300' "$REPO_DIR/shell/info-panel.sh" && _ok "info-panel.sh no hardcoded sleep 300" || _fail "info-panel.sh still has hardcoded sleep 300"

# ── Test 11: register_project creates .doey/ ─────────────────────────

printf '\n\033[1mTest 11: register_project creates .doey/ directory\033[0m\n'
grep -q 'mkdir -p.*\.doey' "$REPO_DIR/shell/doey.sh" && _ok "register_project creates .doey/ dir" || _fail "register_project missing .doey/ creation"
grep -q 'cp.*template.*\.doey/config\.sh' "$REPO_DIR/shell/doey.sh" && _ok "register_project copies config template" || _fail "register_project missing template copy"

# ── Test 12: doey_config function exists ─────────────────────────────

printf '\n\033[1mTest 12: doey_config subcommand\033[0m\n'
grep -q '^doey_config()' "$REPO_DIR/shell/doey.sh" && _ok "doey_config() function defined" || _fail "doey_config() missing"
grep -q 'config).*doey_config' "$REPO_DIR/shell/doey.sh" && _ok "config) case routes to doey_config" || _fail "config) case missing"
grep -q '\-\-show' "$REPO_DIR/shell/doey.sh" && _ok "doey config --show supported" || _fail "--show missing"
grep -q '\-\-global' "$REPO_DIR/shell/doey.sh" && _ok "doey config --global supported" || _fail "--global missing"
grep -q '\-\-reset' "$REPO_DIR/shell/doey.sh" && _ok "doey config --reset supported" || _fail "--reset missing"

# ── Summary ──────────────────────────────────────────────────────────

printf '\n\033[1;36m=== Results ===\033[0m\n'
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[1;32mAll %d tests passed\033[0m\n\n' "$TOTAL"
  exit 0
else
  printf '  \033[1;31m%d/%d failed\033[0m\n\n' "$FAIL" "$TOTAL"
  exit 1
fi
