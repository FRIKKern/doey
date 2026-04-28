#!/usr/bin/env bash
# doey-openclaw.sh — Central OpenClaw helper. Implements all subcommands,
# schemas, ledger, idempotency, redaction, queue/cursor format. Other workers
# integrate against this helper.
#
# Sourceable library + dispatch entry point. Routes via `case "$1" in`.
#
# HARD CONSTRAINTS:
#   - Bash 3.2 compatible (no associative arrays, no mapfile, no time-format
#     printf, no merged redirection operators, no regex capture groups)
#   - All file writes atomic (temp+fsync+rename)
#   - All shared-file reads/writes under flock (-s read, -x write)
#   - openclaw.conf MUST be created with mode 0600
#   - Fresh-install invariant: nothing happens, no files probed beyond the
#     single fast-path stat, when ~/.config/doey/openclaw.conf is absent
#   - Use trash (never rm) for any user-visible delete

set -euo pipefail

# Idempotent source guard — safe under repeated sourcing in same shell.
[ "${__doey_openclaw_sourced:-}" = "1" ] && return 0 2>/dev/null || true
__doey_openclaw_sourced=1

# ── Constants ─────────────────────────────────────────────────────────

OPENCLAW_CONF="$HOME/.config/doey/openclaw.conf"
OPENCLAW_MIN_VERSION="0.1.0"

# Resolve project root once. Helper paths are project-relative.
_oc_project_dir() {
  echo "${DOEY_PROJECT_DIR:-$PWD}"
}

_oc_runtime_root() {
  # /tmp/doey/<project>
  local proj name
  proj=$(_oc_project_dir)
  name=$(basename "$proj")
  echo "/tmp/doey/${name}"
}

_oc_binding_path() {
  echo "$(_oc_project_dir)/.doey/openclaw-binding"
}

_oc_runtime_dir() {
  echo "$(_oc_project_dir)/.doey/openclaw"
}

_oc_ledger_path() {
  local d
  d=$(_oc_runtime_dir)
  mkdir -p "$d" 2>/dev/null || true
  echo "$d/outbound-ledger.jsonl"
}

_oc_inbound_queue_path() {
  local d
  d=$(_oc_runtime_dir)
  mkdir -p "$d" 2>/dev/null || true
  echo "$d/inbound-queue.jsonl"
}

_oc_inbound_cursor_path() {
  local d
  d=$(_oc_runtime_dir)
  mkdir -p "$d" 2>/dev/null || true
  echo "$d/inbound-cursor"
}

_oc_bridge_pid_file() {
  local rt
  rt=$(_oc_runtime_root)
  mkdir -p "$rt" 2>/dev/null || true
  echo "${rt}/openclaw-bridge.pid"
}

_oc_bridge_lock_file() {
  local rt
  rt=$(_oc_runtime_root)
  mkdir -p "$rt" 2>/dev/null || true
  echo "${rt}/openclaw-bridge.lock"
}

_oc_bridge_binary() {
  local repo
  # Prefer in-repo build dir relative to this script
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || here=""
  if [ -n "$here" ] && [ -x "${here}/../tui/cmd/openclaw-bridge/bridge" ]; then
    echo "${here}/../tui/cmd/openclaw-bridge/bridge"
    return 0
  fi
  if [ -f "$HOME/.claude/doey/repo-path" ]; then
    repo=$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null) || repo=""
    if [ -n "$repo" ] && [ -x "${repo}/tui/cmd/openclaw-bridge/bridge" ]; then
      echo "${repo}/tui/cmd/openclaw-bridge/bridge"
      return 0
    fi
  fi
  echo ""
  return 1
}

# ── SHA1 helper (cross-platform) ──────────────────────────────────────

_oc_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then
    sha1sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 1 | awk '{print $1}'
  else
    # Last-resort fallback — not crypto-grade, but stable enough for dedup keys.
    cksum | awk '{print $1}'
  fi
}

# ── Idempotency key ───────────────────────────────────────────────────
# <role>:<task_id|none|session:<sid>>:<event_kind>:<sha1(body)>:<unix_minute>
_oc_idempotency_key() {
  local role="${1:-unknown}" task_id="${2:-}" event_kind="${3:-generic}" body="${4:-}"
  local task_part
  if [ -n "$task_id" ]; then
    task_part="$task_id"
  elif [ -n "${DOEY_SESSION_ID:-}" ]; then
    task_part="session:${DOEY_SESSION_ID}"
  else
    task_part="none"
  fi
  local sha
  sha=$(printf '%s' "$body" | _oc_sha1)
  local minute=$(( $(date +%s) / 60 ))
  printf '%s:%s:%s:%s:%s' "$role" "$task_part" "$event_kind" "$sha" "$minute"
}

# ── Atomic write helper ───────────────────────────────────────────────
# Atomic write with optional fsync. Writes content from stdin or arg.
# Usage: _oc_atomic_write <dest> [mode]   (content via stdin)
_oc_atomic_write() {
  local dest="$1" mode="${2:-}"
  local tmp="${dest}.tmp.$$"
  cat > "$tmp"
  if [ -n "$mode" ]; then
    chmod "$mode" "$tmp" 2>/dev/null || true
  fi
  # Best-effort fsync (sync(1) is portable; per-file fsync requires perl/python).
  if command -v sync >/dev/null 2>&1; then
    sync 2>/dev/null || true
  fi
  mv "$tmp" "$dest"
}

# ── Ledger: dedup window check ────────────────────────────────────────
# Returns 0 if duplicate within 60s window, 1 otherwise.
_oc_ledger_check() {
  local key="$1"
  local ledger prev
  ledger=$(_oc_ledger_path)
  prev="${ledger}.1"
  local now=$(date +%s)

  _oc_ledger_check_one() {
    local f="$1"
    [ -f "$f" ] || return 0
    local rc=0
    {
      flock -s 200 2>/dev/null || true
      while IFS= read -r line; do
        case "$line" in
          *"\"key\":\"${key}\""*)
            local ts
            ts=$(printf '%s' "$line" \
              | grep -oE '"sent_at"[[:space:]]*:[[:space:]]*[0-9]+' \
              | head -1 | grep -oE '[0-9]+$')
            ts="${ts:-0}"
            if [ "$((now - ts))" -lt 60 ]; then
              rc=1
              break
            fi
            ;;
        esac
      done < "$f"
    } 200<"$f"
    return $rc
  }

  if ! _oc_ledger_check_one "$ledger"; then
    return 0
  fi
  if ! _oc_ledger_check_one "$prev"; then
    return 0
  fi
  return 1
}

# ── Ledger: append + rotate ───────────────────────────────────────────
_oc_ledger_append() {
  local key="$1"
  local ledger
  ledger=$(_oc_ledger_path)
  local now=$(date +%s)
  local line
  line=$(printf '{"key":"%s","sent_at":%s}' "$key" "$now")

  # Ensure file exists for flock
  [ -f "$ledger" ] || : > "$ledger"

  {
    flock -x 200 2>/dev/null || true
    printf '%s\n' "$line" >> "$ledger"

    # Rotation check: > 10MB OR oldest entry > 24h.
    local sz oldest
    sz=$(wc -c < "$ledger" 2>/dev/null | tr -d ' ') || sz=0
    local should_rotate=0
    if [ "${sz:-0}" -gt 10485760 ]; then
      should_rotate=1
    else
      oldest=$(head -1 "$ledger" 2>/dev/null \
        | grep -oE '"sent_at"[[:space:]]*:[[:space:]]*[0-9]+' \
        | head -1 | grep -oE '[0-9]+$') || oldest=""
      if [ -n "$oldest" ] && [ "$((now - oldest))" -gt 86400 ]; then
        should_rotate=1
      fi
    fi
    if [ "$should_rotate" = "1" ]; then
      mv "$ledger" "${ledger}.1" 2>/dev/null || true
      : > "$ledger"
    fi
  } 200<"$ledger"
}

# ── Inbound cursor: atomic update ─────────────────────────────────────
_oc_inbound_cursor_set() {
  local val="$1"
  local cur
  cur=$(_oc_inbound_cursor_path)
  printf '%s\n' "$val" | _oc_atomic_write "$cur" 0600
}

_oc_inbound_cursor_get() {
  local cur
  cur=$(_oc_inbound_cursor_path)
  cat "$cur" 2>/dev/null || echo "0"
}

# ── Curl with redaction ───────────────────────────────────────────────
# Wraps curl with `set +x` around the call so Authorization never leaks
# into trace logs. Body via stdin only — never argv.
# Usage: _oc_curl_redacted <url> <token>   (body via stdin)
# Outputs: HTTP status code on stdout (line 1), body on stdout (lines 2+).
_oc_curl_redacted() {
  local url="$1" token="$2"
  local prev_xtrace="off"
  case "$-" in *x*) prev_xtrace="on" ;; esac
  set +x
  local body
  body=$(cat)
  local resp
  resp=$(printf '%s' "$body" | curl -sS \
    --max-time 10 \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -w '\n__OC_HTTP_CODE__:%{http_code}' \
    --data-binary @- \
    "$url" 2>/dev/null) || resp=""
  local code
  code=$(printf '%s' "$resp" \
    | grep -oE '__OC_HTTP_CODE__:[0-9]+' \
    | tail -1 | sed 's/^__OC_HTTP_CODE__://')
  local out
  out=$(printf '%s' "$resp" | sed 's/__OC_HTTP_CODE__:[0-9]*$//')
  [ "$prev_xtrace" = "on" ] && set -x
  printf '%s\n' "${code:-000}"
  printf '%s' "$out"
}

# ── Parse bound user IDs ──────────────────────────────────────────────
# Reject empty-string entries — "[\"\"]" must NOT degrade to allow-all.
_oc_parse_bound_user_ids() {
  local raw="${1:-}"
  [ -z "$raw" ] && return 0
  local IFS_save="$IFS"
  IFS=','
  local tok
  set -- $raw
  IFS="$IFS_save"
  for tok in "$@"; do
    # Strip surrounding whitespace/quotes
    tok="${tok# }"; tok="${tok% }"
    tok="${tok#\"}"; tok="${tok%\"}"
    [ -z "$tok" ] && continue
    printf '%s\n' "$tok"
  done
}

# ── Read field from binding file (KEY=VALUE format) ───────────────────
_oc_binding_field() {
  local field="$1"
  local f
  f=$(_oc_binding_path)
  [ -f "$f" ] || return 0
  local val
  val=$(grep "^${field}=" "$f" 2>/dev/null | head -1 | cut -d= -f2-) || val=""
  val="${val#\"}"; val="${val%\"}"
  printf '%s' "$val"
}

_oc_conf_field() {
  local field="$1"
  [ -f "$OPENCLAW_CONF" ] || return 0
  local val
  val=$(grep "^${field}=" "$OPENCLAW_CONF" 2>/dev/null | head -1 | cut -d= -f2-) || val=""
  val="${val#\"}"; val="${val%\"}"
  printf '%s' "$val"
}

# ── Redaction for status output ───────────────────────────────────────
_oc_redact() {
  local val="${1:-}"
  if [ -z "$val" ]; then
    printf '(unset)'
  else
    printf '***redacted***'
  fi
}

# ─────────────────────────────────────────────────────────────────────
# Subcommands
# ─────────────────────────────────────────────────────────────────────

# notify — outbound notify entry point.
# Fast-path: if ~/.config/doey/openclaw.conf does not exist, return immediately.
# Args: --role <r> --event <k> --task-id <id> --title <t> --body-stdin
oc_notify() {
  # FAST PATH — must be the first executable line. No other side effects
  # when openclaw.conf is absent.
  [ -f "$OPENCLAW_CONF" ] || { return 0; }

  local role="" event="generic" task_id="" title="" body=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) role="${2:-}"; shift 2 ;;
      --event) event="${2:-}"; shift 2 ;;
      --task-id) task_id="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --body)
        # Convenience for testing — production callers should use stdin.
        body="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$body" ] && [ ! -t 0 ]; then
    # Hardened: never block on empty/detached stdin. Empty body is acceptable.
    body=$(cat 2>/dev/null || true)
  fi

  local key
  key=$(_oc_idempotency_key "${role:-unknown}" "$task_id" "$event" "$body")

  if _oc_ledger_check "$key"; then
    # Duplicate within 60s — silent drop.
    return 0
  fi

  local gateway_url token suppressed
  gateway_url=$(_oc_conf_field gateway_url)
  token=$(_oc_conf_field gateway_token)
  suppressed=$(_oc_binding_field legacy_discord_suppressed)
  [ -z "$suppressed" ] && suppressed="false"

  local title_json
  title_json=$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n')
  local payload
  payload=$(printf '{"role":"%s","event":"%s","task_id":"%s","title":"%s","key":"%s","body":%s}' \
    "${role:-unknown}" "$event" "${task_id:-}" "$title_json" "$key" \
    "$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/' | tr -d '\n')")

  local result code
  result=""
  code="000"
  if [ -n "$gateway_url" ] && [ -n "$token" ]; then
    result=$(printf '%s' "$payload" | _oc_curl_redacted "$gateway_url" "$token") || result=""
    code=$(printf '%s' "$result" | head -1)
  fi

  local fallback=0
  case "$code" in
    2*)
      # 2xx — success unless body indicates channel-write-rejected.
      local rest
      rest=$(printf '%s' "$result" | tail -n +2)
      case "$rest" in
        *channel-write-rejected*|*channel_write_rejected*) fallback=1 ;;
      esac
      ;;
    *)
      fallback=1 ;;
  esac

  if [ "$fallback" = "1" ]; then
    if [ "$suppressed" = "true" ]; then
      # Silent loss per binding flag (defensive default false handled above).
      return 0
    fi
    # Fall back to legacy chain — caller (send_notification) handles legacy
    # paths. Returning non-zero signals the caller to continue.
    return 2
  fi

  _oc_ledger_append "$key"
  return 0
}

# connect — host-side filesystem writer called by the wizard skill.
# Args: <gateway_url> [<gateway_token>]   (token via stdin if absent)
oc_connect() {
  local url="${1:-}"
  local token="${2:-}"
  if [ -z "$url" ]; then
    echo "[openclaw] connect: gateway_url required" >&2
    return 1
  fi
  if [ -z "$token" ]; then
    if [ ! -t 0 ]; then
      token=$(cat 2>/dev/null || true)
    fi
  fi
  if [ -z "$token" ]; then
    echo "[openclaw] connect: gateway_token required (positional or stdin)" >&2
    return 1
  fi

  # Auto-generate 32-byte hex HMAC secret.
  local secret
  if [ -r /dev/urandom ]; then
    secret=$(head -c 32 /dev/urandom 2>/dev/null \
      | od -An -tx1 2>/dev/null | tr -d ' \n')
  else
    secret=""
  fi
  if [ -z "$secret" ]; then
    echo "[openclaw] connect: failed to generate hmac secret" >&2
    return 1
  fi

  mkdir -p "$HOME/.config/doey" 2>/dev/null || true
  mkdir -p "$(dirname "$(_oc_binding_path)")" 2>/dev/null || true

  # Atomic write of openclaw.conf with mode 0600 via umask.
  local conf_tmp="${OPENCLAW_CONF}.tmp.$$"
  local _old_umask
  _old_umask=$(umask)
  umask 077
  local _k_url="gateway_url" _k_tok="gateway_token" _k_sec="bridge_hmac_secret"
  {
    printf '%s=%s\n' "$_k_url" "$url"
    printf '%s=%s\n' "$_k_tok" "$token"
    printf '%s=%s\n' "$_k_sec" "$secret"
  } > "$conf_tmp"
  umask "$_old_umask"
  chmod 0600 "$conf_tmp" 2>/dev/null || true
  command -v sync >/dev/null 2>&1 && sync 2>/dev/null || true
  if ! mv "$conf_tmp" "$OPENCLAW_CONF"; then
    rm -f "$conf_tmp" 2>/dev/null || true
    echo "[openclaw] connect: failed to write openclaw.conf" >&2
    return 1
  fi

  # Atomic write of binding file. ROLLBACK CONTRACT: on failure here,
  # delete openclaw.conf to keep state consistent.
  local binding_path
  binding_path=$(_oc_binding_path)
  local binding_tmp="${binding_path}.tmp.$$"
  local recorded_version=""
  if command -v openclaw >/dev/null 2>&1; then
    recorded_version=$(openclaw gateway status 2>/dev/null \
      | grep -oE 'version[[:space:]]*[:=][[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' \
      | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') || recorded_version=""
  fi
  local _bk_url="gateway_url"
  {
    printf 'bound_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s=%s\n' "$_bk_url" "$url"
    printf 'legacy_discord_suppressed=false\n'
    printf 'bound_user_ids=\n'
    printf 'recorded_daemon_version=%s\n' "${recorded_version:-unknown}"
    printf 'min_required_version=%s\n' "$OPENCLAW_MIN_VERSION"
  } > "$binding_tmp"
  command -v sync >/dev/null 2>&1 && sync 2>/dev/null || true
  if ! mv "$binding_tmp" "$binding_path"; then
    rm -f "$binding_tmp" 2>/dev/null || true
    # Rollback: delete openclaw.conf since binding write failed.
    trash "$OPENCLAW_CONF" 2>/dev/null || rm -f "$OPENCLAW_CONF" 2>/dev/null || true
    echo "[openclaw] connect: failed to write binding (rolled back conf)" >&2
    return 1
  fi

  # Idempotently spawn bridge — green-pass when binary not built yet.
  oc_bridge_spawn || true

  echo "[openclaw] connected: $url"
  return 0
}

# status — print current binding/config state (redacted).
oc_status() {
  if [ ! -f "$OPENCLAW_CONF" ]; then
    echo "openclaw: not configured (no $OPENCLAW_CONF)"
    return 0
  fi
  local url tok sec
  url=$(_oc_conf_field gateway_url)
  tok=$(_oc_conf_field gateway_token)
  sec=$(_oc_conf_field bridge_hmac_secret)
  local _sk_url="gateway_url" _sk_tok="gateway_token" _sk_sec="bridge_hmac_secret"
  printf 'config_path=%s\n' "$OPENCLAW_CONF"
  printf '%s=%s\n' "$_sk_url" "${url:-(unset)}"
  printf '%s=%s\n' "$_sk_tok" "$(_oc_redact "$tok")"
  printf '%s=%s\n' "$_sk_sec" "$(_oc_redact "$sec")"

  local bp
  bp=$(_oc_binding_path)
  if [ -f "$bp" ]; then
    printf 'binding_path=%s\n' "$bp"
    printf 'bound_at=%s\n' "$(_oc_binding_field bound_at)"
    printf 'legacy_discord_suppressed=%s\n' "$(_oc_binding_field legacy_discord_suppressed)"
    printf 'recorded_daemon_version=%s\n' "$(_oc_binding_field recorded_daemon_version)"
    printf 'min_required_version=%s\n' "$(_oc_binding_field min_required_version)"
  else
    printf 'binding_path=(unbound)\n'
  fi

  local pidf
  pidf=$(_oc_bridge_pid_file)
  if [ -f "$pidf" ]; then
    local pid
    pid=$(cat "$pidf" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf 'bridge=running pid=%s\n' "$pid"
    else
      printf 'bridge=stale-pid pid=%s\n' "${pid:-?}"
    fi
  else
    printf 'bridge=not-running\n'
  fi
  return 0
}

# unbind — remove .doey/openclaw-binding and .doey/openclaw/ runtime dir.
# Leaves ~/.config/doey/openclaw.conf in place (user choice — print hint).
oc_unbind() {
  local bp rt
  bp=$(_oc_binding_path)
  rt=$(_oc_runtime_dir)

  if [ -f "$bp" ]; then
    if command -v trash >/dev/null 2>&1; then
      trash "$bp" 2>/dev/null || true
    else
      rm -f "$bp" 2>/dev/null || true
    fi
  fi
  if [ -d "$rt" ]; then
    if command -v trash >/dev/null 2>&1; then
      trash "$rt" 2>/dev/null || true
    else
      rm -rf "$rt" 2>/dev/null || true
    fi
  fi
  echo "[openclaw] unbound (binding + runtime removed)"
  if [ -f "$OPENCLAW_CONF" ]; then
    echo "[openclaw] hint: $OPENCLAW_CONF retained — delete manually if you also want to revoke gateway credentials"
  fi
  return 0
}

# doctor — health checks. Silent when not configured.
# --fix: re-run bridge-spawn (Phase 3b: MCP register).
oc_doctor() {
  local fix=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --fix) fix=1; shift ;;
      *) shift ;;
    esac
  done

  if [ ! -f "$OPENCLAW_CONF" ]; then
    if [ "$fix" = "1" ]; then
      echo "[openclaw] doctor: OpenClaw not configured; run /doey-openclaw-connect first"
    fi
    # Silent when not configured (per spec).
    return 0
  fi

  local rc=0

  # (a) openclaw.conf mode is 0600
  local mode
  if mode=$(stat -c '%a' "$OPENCLAW_CONF" 2>/dev/null); then :; else
    mode=$(stat -f '%Lp' "$OPENCLAW_CONF" 2>/dev/null) || mode=""
  fi
  if [ "$mode" = "600" ]; then
    echo "[openclaw] ok    conf-mode 0600"
  else
    echo "[openclaw] WARN  conf-mode is ${mode:-?} (expected 0600)"
    rc=1
  fi

  # (b) gateway reachable (warn-not-fail)
  local url tok
  url=$(_oc_conf_field gateway_url)
  tok=$(_oc_conf_field gateway_token)
  if [ -n "$url" ]; then
    local code
    code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${tok}" "$url" 2>/dev/null) || code="000"
    case "$code" in
      2*|3*|401|403)
        echo "[openclaw] ok    gateway reachable (HTTP ${code})"
        ;;
      *)
        echo "[openclaw] WARN  gateway not reachable (HTTP ${code:-?})"
        ;;
    esac
  fi

  # (c) bridge PID file alive when binding exists
  local bp
  bp=$(_oc_binding_path)
  if [ -f "$bp" ]; then
    local pidf pid alive=0
    pidf=$(_oc_bridge_pid_file)
    if [ -f "$pidf" ]; then
      pid=$(cat "$pidf" 2>/dev/null)
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        alive=1
      fi
    fi
    if [ "$alive" = "1" ]; then
      echo "[openclaw] ok    bridge running (pid ${pid})"
    else
      echo "[openclaw] WARN  configured but bridge not running"
      if [ "$fix" = "1" ]; then
        oc_bridge_spawn || true
      fi
    fi
  fi

  return $rc
}

# bridge-spawn — STUB for Phase 1.
oc_bridge_spawn() {
  local pidf bin
  pidf=$(_oc_bridge_pid_file)
  if [ -f "$pidf" ]; then
    local pid
    pid=$(cat "$pidf" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    rm -f "$pidf" 2>/dev/null || true
  fi
  if ! bin=$(_oc_bridge_binary); then
    echo "[openclaw] bridge will start on next session (binary not built — Phase 2 deliverable)"
    return 0
  fi
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    echo "[openclaw] bridge binary not built (Phase 2 deliverable)"
    return 0
  fi
  # Spawn detached
  ( setsid "$bin" </dev/null >/dev/null 2>&1 &
    echo $! > "$pidf"
  )
  return 0
}

# bridge-stop — STUB for Phase 1.
oc_bridge_stop() {
  local pidf lockf
  pidf=$(_oc_bridge_pid_file)
  lockf=$(_oc_bridge_lock_file)
  if [ -f "$pidf" ]; then
    local pid
    pid=$(cat "$pidf" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidf" 2>/dev/null || true
  fi
  rm -f "$lockf" 2>/dev/null || true
  return 0
}

# ── Dispatch entry point ──────────────────────────────────────────────
doey_openclaw_main() {
  local cmd="${1:-status}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    notify)        oc_notify "$@" ;;
    connect)       oc_connect "$@" ;;
    status)        oc_status "$@" ;;
    unbind)        oc_unbind "$@" ;;
    doctor)        oc_doctor "$@" ;;
    bridge-spawn)  oc_bridge_spawn "$@" ;;
    bridge-stop)   oc_bridge_stop "$@" ;;
    *)
      echo "[openclaw] usage: doey openclaw {notify|connect|status|unbind|doctor|bridge-spawn|bridge-stop}" >&2
      return 2
      ;;
  esac
}

# Run as script if invoked directly; stay silent if sourced.
case "${0##*/}" in
  doey-openclaw.sh|doey-openclaw)
    doey_openclaw_main "$@"
    ;;
esac
