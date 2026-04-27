#!/usr/bin/env bash
# doey-doctor.sh — Installation health check and diagnostics.
# Sourceable library, not standalone.
set -euo pipefail

[ "${__doey_doctor_sourced:-}" = "1" ] && return 0
__doey_doctor_sourced=1

# Doctor counters — reset before each run, read after
_DOC_OK=0 _DOC_WARN=0 _DOC_FAIL=0 _DOC_SKIP=0

# Print a doctor-style check line.
# Usage: _doc_check ok|warn|fail|skip "label" ["detail"]
_doc_check() {
  local level="$1" label="$2" detail="${3:-}"
  case "$level" in
    ok)   _DOC_OK=$((_DOC_OK + 1)) ;;
    warn) _DOC_WARN=$((_DOC_WARN + 1)) ;;
    fail) _DOC_FAIL=$((_DOC_FAIL + 1)) ;;
    skip) _DOC_SKIP=$((_DOC_SKIP + 1)) ;;
  esac
  if [ "$HAS_GUM" = true ]; then
    local icon color
    case "$level" in
      ok)   icon="✓"; color="2" ;;
      warn) icon="⚠"; color="3" ;;
      fail) icon="✗"; color="1" ;;
      skip) icon="–"; color="8" ;;
    esac
    printf '  %s %-22s %s\n' \
      "$(gum style --foreground "$color" "$icon")" \
      "$label" \
      "$([ -n "$detail" ] && gum style --foreground 240 "$detail")"
  else
    case "$level" in
      ok)   printf "  ${SUCCESS}✓${RESET} %-22s" "$label" ;;
      warn) printf "  ${WARN}⚠${RESET} %-22s" "$label" ;;
      fail) printf "  ${ERROR}✗${RESET} %-22s" "$label" ;;
      skip) printf "  ${DIM}–${RESET} %-22s" "$label" ;;
    esac
    [ -n "$detail" ] && printf " ${DIM}%s${RESET}" "$detail"
    printf '\n'
  fi
}

# Stats schema version — must match tui/internal/statsdb/types.go::SchemaVersion.
# Hardcoded here so doctor never needs doey-ctl to determine "what version
# should the DB be at". Kept in sync manually with the Go constant.
DOEY_STATSDB_SCHEMA_VERSION="${DOEY_STATSDB_SCHEMA_VERSION:-1}"

# ── Stats health check ────────────────────────────────────────────────
# Verifies stats.db reachability, schema version, kill-switch state, and
# session ID presence. Gracefully handles fresh-install (no DB yet) and
# missing doey-ctl. Never hard-fails — reports warn/skip instead so the
# overall doctor exit code is not poisoned by stats.
check_stats() {
  printf "\n  ${BOLD}Stats:${RESET}\n"

  # (d) DOEY_SESSION_ID presence — purely informational
  if [ -n "${DOEY_SESSION_ID:-}" ]; then
    _doc_check ok "session id" "set"
  else
    _doc_check skip "session id" "DOEY_SESSION_ID not set (outside doey session)"
  fi

  # (c) kill switch state
  if [ "${DOEY_STATS:-}" = "0" ]; then
    _doc_check warn "stats kill switch" "DOEY_STATS=0 (disabled)"
  else
    _doc_check ok "stats kill switch" "enabled"
  fi

  # (a) DB reachability — tolerate fresh install
  local _stats_proj="${PROJECT_DIR:-$(pwd)}"
  local _stats_db="${_stats_proj}/.doey/stats.db"
  local _stats_parent="${_stats_proj}/.doey"
  if [ -f "$_stats_db" ]; then
    _doc_check ok "stats.db" "${_stats_db/#$HOME/~}"
  elif [ -d "$_stats_parent" ] && [ -w "$_stats_parent" ]; then
    _doc_check ok "stats.db" "absent but .doey/ writable (will create on first emit)"
  elif [ -d "$_stats_proj" ] && [ -w "$_stats_proj" ]; then
    _doc_check ok "stats.db" "absent; project dir writable (fresh install OK)"
  else
    _doc_check warn "stats.db" "no writable .doey/ under $_stats_proj"
  fi

  # (b) schema version match — requires doey-ctl + live DB; skip gracefully
  if ! command -v doey-ctl >/dev/null 2>&1; then
    _doc_check skip "stats schema" "doey-ctl not on PATH — deep check skipped"
  elif [ ! -f "$_stats_db" ]; then
    _doc_check skip "stats schema" "stats.db not yet created"
  else
    # Probe via doey-ctl query — Phase 1 stubs return empty JSON but the
    # binary will still open the DB and run bootstrap. If that works, we
    # treat schema as current. Deep version-pinning lands in Phase 4.
    if doey-ctl stats query counters --project-dir "$_stats_proj" >/dev/null 2>&1; then
      _doc_check ok "stats schema" "version ${DOEY_STATSDB_SCHEMA_VERSION}"
    else
      _doc_check warn "stats schema" "doey-ctl query counters failed"
    fi
  fi

  # --stats-verbose: dump last 10 events and counters (Phase 1 stubs → empty)
  if [ "${_DOC_STATS_VERBOSE:-0}" = "1" ]; then
    printf "\n  ${BOLD}Stats — recent events (last 10):${RESET}\n"
    if command -v doey-ctl >/dev/null 2>&1; then
      local _stats_out
      _stats_out=$(doey-ctl stats query recent --project-dir "$_stats_proj" --limit 10 2>/dev/null || true)
      if [ -n "$_stats_out" ]; then
        printf '    %s\n' "$_stats_out"
      else
        printf "    ${DIM}(no events returned)${RESET}\n"
      fi
    else
      printf "    ${DIM}doey-ctl unavailable${RESET}\n"
    fi
    printf "\n  ${BOLD}Stats — counters:${RESET}\n"
    if command -v doey-ctl >/dev/null 2>&1; then
      local _stats_counts
      _stats_counts=$(doey-ctl stats query counters --project-dir "$_stats_proj" 2>/dev/null || true)
      if [ -n "$_stats_counts" ]; then
        printf '    %s\n' "$_stats_counts"
      else
        printf "    ${DIM}(no counters returned)${RESET}\n"
      fi
    else
      printf "    ${DIM}doey-ctl unavailable${RESET}\n"
    fi
  fi
}

# ── Stats allowlist sync check ────────────────────────────────────────
# The stats allowlist lives in two places: shell/ (source of truth) and
# tui/cmd/doey-ctl/ (Go embed copy). If they diverge, events get dropped.
check_stats_allowlist() {
  local _repo="${1:-}"
  if [ -z "$_repo" ]; then
    _doc_check skip "allowlist sync" "repo dir unknown"
    return 0
  fi
  local _shell_al="$_repo/shell/doey-stats-allowlist.txt"
  local _go_al="$_repo/tui/cmd/doey-ctl/doey-stats-allowlist.txt"
  if [ ! -f "$_shell_al" ]; then
    _doc_check warn "allowlist sync" "shell copy missing: ${_shell_al/#$HOME/~}"
    return 0
  fi
  if [ ! -f "$_go_al" ]; then
    _doc_check warn "allowlist sync" "Go embed copy missing: ${_go_al/#$HOME/~}"
    return 0
  fi
  if cmp -s "$_shell_al" "$_go_al"; then
    _doc_check ok "allowlist sync" "shell ↔ Go embed identical"
  else
    _doc_check warn "allowlist sync" "files differ — run: cp ${_shell_al/#$HOME/~} ${_go_al/#$HOME/~}"
    # Show which lines differ
    local _diff_out
    _diff_out="$(diff --label shell --label go-embed "$_shell_al" "$_go_al" 2>/dev/null | head -10 || true)"
    if [ -n "$_diff_out" ]; then
      printf '%s\n' "$_diff_out" | while IFS= read -r _line; do
        printf '         %s\n' "$_line"
      done
    fi
  fi
}

# ── Discord integration check ──────────────────────────────────────────
# Phase-1 scope (task 612): presence + permissions only, NO network.
# Outcomes:
#   No binding → ✓ (Discord is optional)
#   Binding + creds parse OK + mode 0600 → ✓
#   Binding + missing/bad-perms/parse-error/unknown-stanza → ✗ with detail
#   Non-POSIX FS → ⚠ with docs link
#   flock(2) unsupported → ⚠ with docs link
check_discord() {
  printf "\n  ${BOLD}Discord:${RESET}\n"

  local _proj="${PROJECT_DIR:-$(pwd)}"
  local _binding_file="${_proj}/.doey/discord-binding"

  if [ ! -f "$_binding_file" ]; then
    _doc_check ok "binding" "no binding (Discord disabled — optional)"
    return 0
  fi

  local _stanza
  _stanza="$(head -n1 "$_binding_file" 2>/dev/null | tr -d '[:space:]')"
  if [ "$_stanza" != "default" ]; then
    _doc_check fail "binding" "unknown stanza: '${_stanza}' (expected 'default') — see docs/discord.md"
    return 0
  fi
  _doc_check ok "binding" "stanza=default"

  local _conf="${XDG_CONFIG_HOME:-$HOME/.config}/doey/discord.conf"
  if [ ! -f "$_conf" ]; then
    _doc_check fail "creds file" "${_conf/#$HOME/~} missing — see docs/discord.md"
    return 0
  fi

  local _mode
  _mode="$(stat -c '%a' "$_conf" 2>/dev/null || stat -f '%Lp' "$_conf" 2>/dev/null || true)"
  if [ -z "$_mode" ]; then
    _doc_check warn "posix fs" "could not stat creds — see docs/discord.md POSIX requirement"
    return 0
  fi
  if [ "$_mode" != "600" ]; then
    _doc_check fail "creds perms" "mode=${_mode} (expected 600); fix: chmod 600 ${_conf/#$HOME/~}"
    return 0
  fi
  _doc_check ok "creds perms" "mode=600"

  # Quick parse probe — refuse unknown stanzas / missing kind early.
  # We only need to confirm the first stanza header is [default] and a
  # kind= line is present; don't re-implement the Go parser.
  if ! head -n 20 "$_conf" 2>/dev/null | grep -Eq '^\[default\][[:space:]]*$'; then
    _doc_check fail "creds stanza" "missing [default] header — see docs/discord.md"
    return 0
  fi
  if ! head -n 40 "$_conf" 2>/dev/null | grep -Eq '^kind[[:space:]]*=[[:space:]]*(webhook|bot_dm)'; then
    _doc_check fail "creds kind" "missing/unknown kind= (expected webhook|bot_dm)"
    return 0
  fi

  # flock(2) probe — best-effort; flock binary missing is informational.
  if command -v flock >/dev/null 2>&1; then
    local _flock_tmp
    _flock_tmp="$(mktemp 2>/dev/null || true)"
    if [ -n "$_flock_tmp" ]; then
      if flock -n -x "$_flock_tmp" true 2>/dev/null; then
        _doc_check ok "flock(2)" "supported"
      else
        _doc_check warn "flock(2)" "lock failed on tmp fs — see docs/discord.md"
      fi
      rm -f "$_flock_tmp"
    else
      _doc_check warn "flock(2)" "mktemp failed — see docs/discord.md"
    fi
  else
    _doc_check warn "flock(2)" "flock binary not on PATH — see docs/discord.md"
  fi

  # Opt-in network probe — only when --network was passed.
  # Binding + creds have already been validated above (early returns above
  # ensure we only reach here on the happy path). The 60s cache lives
  # inside the Go subcommand; the shell just calls through.
  if [ "${DOEY_DOCTOR_NETWORK:-0}" = "1" ]; then
    if command -v doey-tui >/dev/null 2>&1; then
      local _probe_out
      if _probe_out=$(doey-tui discord doctor-network 2>&1); then
        _doc_check ok "network probe" "$_probe_out"
      else
        _doc_check warn "network probe" "$_probe_out"
      fi
    else
      _doc_check warn "network probe" "doey-tui not on PATH"
    fi
  fi
}

# ── Launch-bypass probe (task 617) ────────────────────────────────────
# Greps for Claude launches that bypass doey_send_launch. WARN-only.
# Skips shell/doey-send.sh itself (the helper definitions live there).
_check_launch_bypass() {
  local _repo="$1"
  [ -z "$_repo" ] && return 0
  [ -d "$_repo" ] || return 0
  local _hits
  _hits=$(grep -rnE \
    -e 'tmux send-keys[^|]*claude --dangerously' \
    -e 'doey_send_command[^|]*claude --dangerously' \
    "$_repo/shell" "$_repo/.claude/hooks" "$_repo/.claude/skills" 2>/dev/null \
    | grep -v '/doey-send\.sh:' \
    | grep -v '\.md\.tmpl:' \
    || true)
  if [ -n "$_hits" ]; then
    local _count
    _count=$(printf '%s\n' "$_hits" | wc -l | tr -d ' ')
    _doc_check warn "Launch bypass" "$_count send-keys site(s) bypassing doey_send_launch (task 617)"
    printf '%s\n' "$_hits" | head -5 | while IFS= read -r _line; do
      printf "         ${DIM}WARN: %s${RESET}\n" "$_line"
    done
  else
    _doc_check ok "Launch bypass" "all Claude launches use doey_send_launch"
  fi
}

# ── Chain-bypass probe (task 618) — non-Boss roles must not send-keys to 0.1 ──
# WARN-only. Skips sanctioned files (launcher briefings, Taskmaster→Boss fan-out,
# Boss/Taskmaster prompts, Boss-invoked skills, focus-only select-pane sites).
_check_chain_bypass() {
  local _repo="$1"
  [ -z "$_repo" ] && return 0
  [ -d "$_repo" ] || return 0
  local _hits
  _hits=$(grep -rnE \
    -e 'tmux[[:space:]]+(send-keys|paste-buffer|load-buffer)[^|]*[: ]0\.1([^0-9]|$)' \
    -e 'doey_send_(verified|launch|command)[^|]*[: ]0\.1([^0-9]|$)' \
    "$_repo/shell" "$_repo/agents" "$_repo/.claude" 2>/dev/null \
    | grep -v '/doey-session\.sh:' \
    | grep -v '/stop-notify\.sh:' \
    | grep -v '/common\.sh:' \
    | grep -v '/on-pre-tool-use\.sh:' \
    | grep -v '/on-notification\.sh:' \
    | grep -v '/doey-boss\.md:' \
    | grep -v '/doey-taskmaster\.md:' \
    | grep -v '/doey-masterplan/SKILL\.md:' \
    | grep -v '/doey-clear/SKILL\.md:' \
    | grep -v '/doey-rd-team/SKILL\.md:' \
    | grep -v '\.md\.tmpl:' \
    || true)
  if [ -n "$_hits" ]; then
    local _count
    _count=$(printf '%s\n' "$_hits" | wc -l | tr -d ' ')
    _doc_check warn "Chain bypass" "$_count non-sanctioned send-keys/helper site(s) targeting Boss (0.1) (task 618)"
    printf '%s\n' "$_hits" | head -5 | while IFS= read -r _line; do
      printf "         ${DIM}WARN: %s${RESET}\n" "$_line"
    done
  else
    _doc_check ok "Chain bypass" "no non-sanctioned send-keys to Boss (0.1)"
  fi
}

# ── Doctor — check installation health ────────────────────────────────
check_doctor() {
  PROJECT_DIR="$(pwd)"
  _DOC_OK=0 _DOC_WARN=0 _DOC_FAIL=0 _DOC_SKIP=0

  # Argument parsing — additive, does not alter any existing check.
  _DOC_STATS_VERBOSE=0
  DOEY_DOCTOR_NETWORK="${DOEY_DOCTOR_NETWORK:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --stats-verbose) _DOC_STATS_VERBOSE=1; shift ;;
      --network)       DOEY_DOCTOR_NETWORK=1; export DOEY_DOCTOR_NETWORK; shift ;;
      *) shift ;;
    esac
  done

  printf '\n'
  _print_doey_banner
  doey_header "System Check"
  doey_divider
  printf '\n'

  doey_step "1/6" "Required tools"
  # Required commands — offer install if missing
  if command -v tmux >/dev/null 2>&1; then
    _doc_check ok "tmux" "$(tmux -V)"
  else
    _doc_check fail "tmux not installed"
    case "$(uname -s)" in
      Darwin) printf "\n         ${DIM}Fix: ${RESET}${BRAND}brew install tmux${RESET}\n" ;;
      Linux)  printf "\n         ${DIM}Fix: ${RESET}${BRAND}sudo apt-get install -y tmux${RESET}\n" ;;
    esac
  fi
  # Auto-repair stale fnm/volta shims before reporting a failure
  _doey_repair_claude_path >/dev/null 2>&1 || true
  if command -v claude >/dev/null 2>&1; then
    local _claude_ver _claude_raw _claude_latest
    _claude_raw=$(claude --version 2>/dev/null || echo "unknown")
    _claude_ver=$(_claude_semver)
    _claude_ver="${_claude_ver:-$_claude_raw}"
    _claude_latest=$(_claude_latest_ver)
    if [ -n "$_claude_latest" ] && [ "$_claude_ver" != "$_claude_latest" ]; then
      _doc_check warn "claude CLI" "$_claude_ver → $_claude_latest available"
      printf "\n         "
      _claude_update_hint "$(_claude_install_method)" "Update"
    else
      _doc_check ok "claude CLI" "$_claude_ver${_claude_latest:+ (latest)}"
    fi
  else
    _doc_check fail "claude CLI not found"
    if command -v node >/dev/null 2>&1; then
      printf "\n         ${DIM}Fix: ${RESET}${BRAND}npm install -g @anthropic-ai/claude-code${RESET}\n"
    else
      printf "\n         ${DIM}Fix: Install Node.js 18+ first, then: ${RESET}${BRAND}npm install -g @anthropic-ai/claude-code${RESET}\n"
    fi
  fi

  # Auth check
  local _auth_result
  if _auth_result=$(_parse_auth_status); then
    local _auth_method _auth_email _auth_sub
    local _old_ifs="$IFS"; IFS='|'
    set -- $_auth_result; IFS="$_old_ifs"
    _auth_method="${2:-}" _auth_email="${3:-}" _auth_sub="${4:-}"
    _doc_check ok "Claude auth" "${_auth_method} · ${_auth_email} · ${_auth_sub}"
  else
    _doc_check fail "Claude auth" "Not logged in — run 'claude' to authenticate"
  fi

  printf '\n'
  doey_step "2/6" "Installation"
  # PATH check
  if echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then _doc_check ok "~/.local/bin in PATH"
  else _doc_check warn "~/.local/bin not in PATH"; fi

  # Installed files
  local _f _label _doey_repo
  _doey_repo="$(resolve_repo_dir)"
  # Agents — check the required set, not just one file.
  local _required_agents="doey-boss doey-taskmaster doey-task-reviewer doey-deployment doey-doey-expert doey-subtaskmaster doey-worker doey-worker-deep doey-worker-quick doey-worker-research doey-freelancer"
  local _agents_total=0 _agents_present=0 _agents_missing="" _a
  for _a in $_required_agents; do
    _agents_total=$((_agents_total + 1))
    if [ -f "$HOME/.claude/agents/${_a}.md" ]; then
      _agents_present=$((_agents_present + 1))
    else
      _agents_missing="${_agents_missing:+${_agents_missing}, }${_a}"
    fi
  done
  if [ "$_agents_present" -eq "$_agents_total" ]; then
    _doc_check ok "Agents installed" "${_agents_present}/${_agents_total} present"
  elif [ "$_agents_present" -eq 0 ]; then
    _doc_check fail "Agents installed" "0/${_agents_total} — run: doey install --agents"
  else
    _doc_check fail "Agents installed" "${_agents_present}/${_agents_total} — missing: ${_agents_missing}"
  fi

  # Skills & CLI (unchanged)
  for _f in "$_doey_repo/.claude/skills/doey-dispatch/SKILL.md:Skills" \
            "$HOME/.local/bin/doey:CLI"; do
    _label="${_f##*:}"; _f="${_f%:*}"
    if [[ -f "$_f" ]]; then _doc_check ok "$_label installed" "${_f/#$HOME/~}"
    else _doc_check fail "$_label missing" "${_f/#$HOME/~}"; fi
  done

  # Agent freshness (manifest hash from install.sh)
  local _af_hash_file="$HOME/.claude/doey/agents.hash"
  if [ -f "$_af_hash_file" ]; then
    local _af_saved _af_current
    _af_saved="$(cat "$_af_hash_file")"
    _af_current="$(bash -c 'cat ~/.claude/agents/doey-*.md 2>/dev/null' | _freshness_hash)"
    if [ "$_af_saved" = "$_af_current" ]; then
      _doc_check ok "Agent freshness" "installed agents match manifest"
    else
      _doc_check warn "Agent freshness" "installed agents differ from manifest — run: doey update"
    fi
  else
    _doc_check skip "Agent freshness" "no manifest hash (pre-manifest install)"
  fi

  # Masterplan spawn helper — wired by install.sh but missing on systems that
  # haven't reinstalled since it was added. Required for /doey-masterplan.
  local _mp_spawn="$HOME/.local/bin/doey-masterplan-spawn.sh"
  if [[ -x "$_mp_spawn" ]]; then
    _doc_check ok "Masterplan spawn" "${_mp_spawn/#$HOME/~}"
  elif [[ -f "$_mp_spawn" ]]; then
    _doc_check fail "Masterplan spawn" "exists but not executable — run: cd ${_doey_repo} && ./install.sh"
  else
    _doc_check fail "Masterplan spawn missing" "run: cd ${_doey_repo} && ./install.sh"
  fi

  # Masterplan ambiguity helper — sourced by the /doey-masterplan skill.
  local _mp_amb="$HOME/.local/bin/doey-masterplan-ambiguity.sh"
  if [[ -f "$_mp_amb" ]]; then
    _doc_check ok "Masterplan ambiguity" "${_mp_amb/#$HOME/~}"
  else
    _doc_check fail "Masterplan ambiguity missing" "run: cd ${_doey_repo} && ./install.sh"
  fi

  # Repo path
  local repo_dir=""
  repo_dir="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || true)"
  if [[ -n "$repo_dir" ]]; then
    if [[ -d "$repo_dir" ]]; then _doc_check ok "Repo registered" "$repo_dir"
    else _doc_check fail "Repo dir missing" "$repo_dir"; fi
  else
    _doc_check fail "Repo not registered" "~/.claude/doey/repo-path missing"
  fi

  printf '\n'
  doey_step "3/6" "Optional tools"
  # Optional: jq
  if command -v jq >/dev/null 2>&1; then _doc_check ok "jq" "$(jq --version 2>/dev/null || echo 'unknown')"
  else _doc_check warn "jq not found — auto-trust skipped"; fi

  # Optional: gh (used by intent-fallback for clone+open actions). Warn-only.
  if command -v gh >/dev/null 2>&1; then
    local _gh_ver
    _gh_ver=$(gh --version 2>/dev/null | head -1 | awk '{print $3}')
    if gh auth status >/dev/null 2>&1; then
      _doc_check ok "gh CLI" "${_gh_ver:-installed} · authed"
    else
      _doc_check warn "gh CLI" "${_gh_ver:-installed} — not authed (run: gh auth login)"
    fi
  else
    _doc_check warn "gh not found" "optional — intent fallback will use 'git clone' as fallback"
  fi

  # gum (optional luxury CLI)
  if command -v gum >/dev/null 2>&1; then
    _doc_check ok "gum" "$(gum --version 2>/dev/null || echo 'unknown')"
  else
    _doc_check fail "Gum missing" "run: go install github.com/charmbracelet/gum@latest"
  fi

  # cloudflared (optional tunnel provider — pure diagnosis, never FAIL)
  if command -v cloudflared >/dev/null 2>&1; then
    _doc_check ok "cloudflared" "$(cloudflared --version 2>/dev/null | head -1 || echo 'installed')"
  elif command -v ngrok >/dev/null 2>&1 || command -v bore >/dev/null 2>&1; then
    local _alt=""
    command -v ngrok >/dev/null 2>&1 && _alt="ngrok"
    command -v bore  >/dev/null 2>&1 && _alt="${_alt:+$_alt/}bore"
    _doc_check skip "cloudflared not installed" "using ${_alt} for tunnels"
  else
    _doc_check warn "cloudflared not installed" "no tunnel provider — run: bash ${_doey_repo}/shell/doey-install-cloudflared.sh"
  fi

  # Version
  local version_file="$HOME/.claude/doey/version"
  if [[ -f "$version_file" ]]; then
    _doc_check ok "Version" "$(_env_val "$version_file" version) ($(_env_val "$version_file" date))"
  else
    _doc_check warn "No version file" "Run 'doey update'"
  fi

  printf '\n'
  doey_step "4/6" "Go binaries"
  # Go presence — hard requirement. doey-tui and the masterplan TUI need it.
  local _go_bin=""
  if type _find_go_bin >/dev/null 2>&1; then
    _go_bin="$(_find_go_bin 2>/dev/null || true)"
  elif command -v go >/dev/null 2>&1; then
    _go_bin="$(command -v go)"
  fi
  if [ -n "$_go_bin" ]; then
    _doc_check ok "go found" "$_go_bin ($("$_go_bin" version 2>/dev/null | awk '{print $3}' || echo 'unknown'))"
  else
    _doc_check fail "go not found" "Go is required to build doey-tui and the masterplan TUI"
    if type _print_go_install_hint >/dev/null 2>&1; then
      _print_go_install_hint
    else
      printf "         ${DIM}Install Go from https://go.dev/dl/${RESET}\n"
    fi
    exit 1
  fi
  # TUI dashboard
  if command -v doey-tui >/dev/null 2>&1; then
    _doc_check ok "doey-tui" "$(doey-tui --version 2>/dev/null || echo 'installed')"
  else
    _doc_check warn "doey-tui not installed" "run: doey build"
  fi

  # Remote setup wizard
  if command -v doey-remote-setup >/dev/null 2>&1; then
    _doc_check ok "doey-remote-setup" "installed"
  else
    _doc_check skip "doey-remote-setup not installed" "optional — run: doey build"
  fi

  # Orchestration CLI (internal doey-ctl binary powers 'doey' subcommands)
  if command -v doey-ctl >/dev/null 2>&1; then
    _doc_check ok "doey CLI tools" "found at $(command -v doey-ctl)"
  else
    _doc_check warn "doey CLI tools not installed" "shell fallbacks will be used — run: doey build"
  fi

  # Scaffy template engine
  if command -v doey-scaffy >/dev/null 2>&1; then
    _doc_check ok "doey-scaffy" "$(doey-scaffy --version 2>/dev/null || echo 'installed')"
  else
    _doc_check skip "doey-scaffy not installed" "optional — run: doey build"
  fi

  # Go binary freshness
  if [[ -n "$repo_dir" ]] && type _go_binary_stale >/dev/null 2>&1; then
    local _stale_bins=""
    if _go_binary_stale "$HOME/.local/bin/doey-tui" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="doey-tui"
    fi
    if _go_binary_stale "$HOME/.local/bin/doey-remote-setup" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="${_stale_bins:+${_stale_bins}, }doey-remote-setup"
    fi
    if _go_binary_stale "$HOME/.local/bin/doey-ctl" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="${_stale_bins:+${_stale_bins}, }doey-ctl"
    fi
    if _go_binary_stale "$HOME/.local/bin/doey-scaffy" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="${_stale_bins:+${_stale_bins}, }doey-scaffy"
    fi
    if [[ -n "$_stale_bins" ]]; then
      _doc_check warn "Go binaries may be stale: ${_stale_bins}" "run: doey build"
    else
      _doc_check ok "Go binaries fresh"
    fi
  fi

  printf '\n'
  doey_step "5/6" "Subsystems"
  # Context audit
  if [[ -n "$repo_dir" ]] && [[ -f "$repo_dir/shell/context-audit.sh" ]]; then
    local audit_output
    if audit_output=$(bash "$repo_dir/shell/context-audit.sh" --installed --no-color 2>&1); then
      _doc_check ok "Context audit clean"
    else
      _doc_check warn "Context audit issues:"
      printf '%s\n' "$audit_output"
    fi
  else
    _doc_check skip "Context audit" "(script not found)"
  fi

  # Plan-pane file contract — hard-fail. Validates the in-repo fixtures
  # (always) plus any live runtime under DOEY_RUNTIME (skipped silently
  # when none exists). See docs/plan-pane-contract.md §5.
  if [[ -n "$repo_dir" ]] && [[ -f "$repo_dir/shell/check-plan-pane-contract.sh" ]] && [[ -d "$repo_dir/tui/internal/planview/testdata/fixtures" ]]; then
    if bash "$repo_dir/shell/check-plan-pane-contract.sh" \
         --fixtures-dir "$repo_dir/tui/internal/planview/testdata/fixtures" \
         --quiet >/dev/null 2>&1; then
      _doc_check ok "Plan-pane contract" "fixtures + runtime conform"
    else
      _doc_check fail "Plan-pane contract drift" "run: bash $repo_dir/shell/check-plan-pane-contract.sh"
    fi
  else
    _doc_check skip "Plan-pane contract" "(validator or fixtures not found)"
  fi

  # Task helpers — verify doey-task-helpers.sh is reachable
  local _task_helpers=""
  if [[ -n "$repo_dir" ]] && [[ -f "$repo_dir/shell/doey-task-helpers.sh" ]]; then
    _task_helpers="$repo_dir/shell/doey-task-helpers.sh"
  else
    # Fall back to location relative to the installed doey script
    local _doey_bin=""
    _doey_bin="$(command -v doey 2>/dev/null || true)"
    if [[ -n "$_doey_bin" ]] && [[ -f "$(dirname "$_doey_bin")/doey-task-helpers.sh" ]]; then
      _task_helpers="$(dirname "$_doey_bin")/doey-task-helpers.sh"
    fi
  fi
  if [[ -n "$_task_helpers" ]]; then
    _doc_check ok "Task helpers" "${_task_helpers/#$HOME/~}"
  else
    _doc_check warn "Task helpers not found" "doey-task-helpers.sh missing from repo and PATH"
  fi

  # Respawn subsystem — skill + hook + syntax
  if [[ -n "$repo_dir" ]]; then
    local _respawn_skill="$repo_dir/.claude/skills/doey-respawn-me/SKILL.md"
    local _respawn_hook="$repo_dir/.claude/hooks/stop-respawn.sh"
    local _respawn_ok=true
    if [[ -f "$_respawn_skill" ]]; then
      _doc_check ok "Respawn skill" "${_respawn_skill/#$HOME/~}"
    else
      _doc_check fail "Respawn skill missing" "${_respawn_skill/#$HOME/~}"
      _respawn_ok=false
    fi
    if [[ -f "$_respawn_hook" ]]; then
      if [[ -x "$_respawn_hook" ]]; then
        if bash -n "$_respawn_hook" 2>/dev/null; then
          _doc_check ok "Respawn hook" "executable, syntax OK"
        else
          _doc_check fail "Respawn hook" "bash -n failed"
          _respawn_ok=false
        fi
      else
        _doc_check fail "Respawn hook" "not executable"
        _respawn_ok=false
      fi
    else
      _doc_check fail "Respawn hook missing" "${_respawn_hook/#$HOME/~}"
      _respawn_ok=false
    fi
  fi

  # Hook-presence check — repo hooks must all exist; project hooks should be in sync.
  # Fallback wrapper in settings.json papers over missing project hooks, but a missing
  # project hook still means self-heal failed and is worth surfacing.
  if [ -n "$repo_dir" ]; then
    local _hooks_required="stop-status stop-results stop-reviewer-metrics stop-recovery stop-notify stop-plan-tracking stop-enforce-ask-user-question on-session-start on-prompt-submit on-pre-tool-use on-pre-compact post-tool-lint post-push-complete on-notification"
    local _hooks_repo="$repo_dir/.claude/hooks"
    local _hooks_proj="$PROJECT_DIR/.claude/hooks"
    local _missing_repo="" _missing_proj="" _h
    for _h in $_hooks_required; do
      [ -x "$_hooks_repo/$_h.sh" ] || _missing_repo="${_missing_repo:+$_missing_repo, }$_h"
      [ -x "$_hooks_proj/$_h.sh" ] || _missing_proj="${_missing_proj:+$_missing_proj, }$_h"
    done
    if [ -z "$_missing_repo" ]; then _doc_check ok "Doey hooks (repo)" "all present"
    else _doc_check fail "Doey hooks (repo)" "missing: $_missing_repo"; fi
    if [ -z "$_missing_proj" ]; then _doc_check ok "Project hooks" "in sync"
    else _doc_check warn "Project hooks" "missing: $_missing_proj — re-launch session or run install"; fi
  fi

  # Task counter — validate .next_id if .doey/tasks/ exists
  local _tasks_dir="${PROJECT_DIR}/.doey/tasks"
  if [[ -d "$_tasks_dir" ]] && [[ -f "${_tasks_dir}/.next_id" ]]; then
    local _nid; _nid="$(cat "${_tasks_dir}/.next_id" 2>/dev/null || true)"
    case "$_nid" in
      ''|*[!0-9]*) _doc_check warn "Task counter" ".next_id is not a positive integer: ${_nid:-empty}" ;;
      0)           _doc_check warn "Task counter" ".next_id=0 — may collide with existing tasks" ;;
      *)           _doc_check ok "Task counter" ".next_id=${_nid}" ;;
    esac
  elif [[ -d "$_tasks_dir" ]]; then
    _doc_check skip "Task counter" ".doey/tasks/ exists but no .next_id yet"
  fi

  # Taskmaster responsiveness — only when a session is running
  local _doc_name _doc_session
  _doc_name="$(find_project "$PROJECT_DIR" 2>/dev/null || true)"
  _doc_session="doey-${_doc_name}"
  if [[ -n "$_doc_name" ]] && session_exists "$_doc_session" 2>/dev/null; then
    local _doc_rt
    _doc_rt="$(tmux show-environment -t "$_doc_session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2- || true)"
    if [[ -z "$_doc_rt" ]]; then _doc_rt="${TMPDIR:-/tmp}/doey/${_doc_name}"; fi
    local _doc_tm_safe
    _doc_tm_safe="$(printf '%s' "${_doc_session}:1.0" | tr ':.-' '___')"
    local _doc_tm_status="${_doc_rt}/status/${_doc_tm_safe}.status"
    if [[ -f "$_doc_tm_status" ]]; then
      local _doc_tm_state
      _doc_tm_state="$(grep '^STATUS' "$_doc_tm_status" 2>/dev/null | head -1 | sed 's/^STATUS[=: ]*//; s/^ *//' || true)"
      case "$_doc_tm_state" in
        BUSY|READY|WORKING)
          # Also check staleness via doey-ctl if available
          if command -v doey-ctl >/dev/null 2>&1; then
            if doey-ctl health check --runtime "$_doc_rt" "$_doc_tm_safe" >/dev/null 2>&1; then
              _doc_check ok "Taskmaster alive" "${_doc_tm_state} (responsive)"
            else
              _doc_check warn "Taskmaster stale" "${_doc_tm_state} but not updated recently"
            fi
          else
            _doc_check ok "Taskmaster alive" "$_doc_tm_state"
          fi
          ;;
        FINISHED|RESERVED)
          _doc_check warn "Taskmaster idle" "$_doc_tm_state"
          ;;
        *)
          _doc_check warn "Taskmaster status" "${_doc_tm_state:-unknown}"
          ;;
      esac
    else
      _doc_check warn "Taskmaster status" "no status file (session running but Taskmaster not reporting)"
    fi
  else
    _doc_check skip "Taskmaster alive" "no running session for $(pwd)"
  fi

  printf '\n'
  doey_step "6/6" "Stats"
  # ── Stats subsystem (Phase 3, task #521) ──
  check_stats

  # ── Stats allowlist sync (shell ↔ Go embed) ──
  check_stats_allowlist "$_doey_repo"

  # ── Discord integration (task 612) ──
  check_discord

  # ── Launch-bypass probe (task 617) — Claude launches must use doey_send_launch ──
  _check_launch_bypass "$_doey_repo"

  # ── Chain-bypass probe (task 618) — non-Boss roles must not send-keys to 0.1 ──
  _check_chain_bypass "$_doey_repo"

  # ── Summary footer ──
  printf '\n'
  doey_divider
  printf '\n'
  if [ "$_DOC_FAIL" -gt 0 ]; then
    doey_error "Doctor found ${_DOC_FAIL} issue(s) — run 'doey update' or check fixes above"
  elif [ "$_DOC_WARN" -gt 0 ]; then
    doey_warn "All checks passed with ${_DOC_WARN} warning(s)"
  else
    doey_success "All systems operational"
  fi
  printf '\n'
  if [ "$HAS_GUM" = true ]; then
    local _doc_summary=""
    _doc_summary="$(gum style --foreground 2 "${_DOC_OK} passed")"
    [ "$_DOC_WARN" -gt 0 ] && _doc_summary="${_doc_summary}  $(gum style --foreground 3 "${_DOC_WARN} warnings")"
    [ "$_DOC_FAIL" -gt 0 ] && _doc_summary="${_doc_summary}  $(gum style --foreground 1 --bold "${_DOC_FAIL} failed")"
    [ "$_DOC_SKIP" -gt 0 ] && _doc_summary="${_doc_summary}  $(gum style --foreground 240 "${_DOC_SKIP} skipped")"
    gum style --border rounded --border-foreground 6 --padding "0 2" --margin "0 1" "$_doc_summary"
  else
    printf "  ${SUCCESS}%d passed${RESET}" "$_DOC_OK"
    [ "$_DOC_WARN" -gt 0 ] && printf "  ${WARN}%d warnings${RESET}" "$_DOC_WARN"
    [ "$_DOC_FAIL" -gt 0 ] && printf "  ${ERROR}%d failed${RESET}" "$_DOC_FAIL"
    [ "$_DOC_SKIP" -gt 0 ] && printf "  ${DIM}%d skipped${RESET}" "$_DOC_SKIP"
    printf '\n'
  fi
  printf '\n'
}
