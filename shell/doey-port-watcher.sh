#!/usr/bin/env bash
# doey-port-watcher.sh — Long-running daemon that polls listening TCP ports
# every TUNNEL_WATCHER_INTERVAL seconds (default 2), applies dev-server
# heuristics, and writes the result as a single-line
#   TUNNEL_PORTS_LIST=port:proc,port:proc,...
# entry inside ${RUNTIME_DIR}/tunnel.env (preserving any other keys).
#
# Spawned as a background daemon by `doey tunnel up`. Honors
# DOEY_TUNNEL_ENABLED — exits silently when unset/0/false.
#
# Bash 3.2 compatible. Pure bash + ss + sort + date + mv. No awk in the
# parse hot path; no assoc arrays; no regex capture groups; no array reads.
set -euo pipefail

# ── Required environment ─────────────────────────────────────────────
: "${PROJECT_NAME:?PROJECT_NAME must be set in environment}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
RUNTIME_DIR="/tmp/doey/${PROJECT_NAME}"
TUNNEL_ENV="${RUNTIME_DIR}/tunnel.env"
PID_FILE="${RUNTIME_DIR}/port-watcher.pid"
LOG_FILE="${RUNTIME_DIR}/port-watcher.log"

mkdir -p "$RUNTIME_DIR"

# ── Logging ──────────────────────────────────────────────────────────
_log() {
  local ts
  ts=$(date +'%Y-%m-%d %H:%M:%S')
  printf '[%s] %s\n' "$ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# ── Opt-in guard ─────────────────────────────────────────────────────
case "${DOEY_TUNNEL_ENABLED:-}" in
  ""|0|false|FALSE|False|no|NO)
    _log "disabled (DOEY_TUNNEL_ENABLED=${DOEY_TUNNEL_ENABLED:-unset}); exiting"
    exit 0
    ;;
esac

# ── Tunables ─────────────────────────────────────────────────────────
INTERVAL="${TUNNEL_WATCHER_INTERVAL:-2}"
MIN_PORT="${TUNNEL_MIN_PORT:-1024}"
MAX_PORT="${TUNNEL_MAX_PORT:-65535}"

# Built-in dev-server allowlist (whole-word match, space-delimited)
DEFAULT_ALLOW="vite next remix webpack esbuild parcel astro nuxt rollup turbo pnpm npm node bun deno rails django flask uvicorn gunicorn rackup puma jekyll hugo"
DEFAULT_BLOCK="sshd systemd-resolved systemd-resolve dnsmasq postgres postgresql mysql mysqld redis-server redis docker-proxy containerd dockerd cupsd avahi-daemon chronyd ntpd"

ALLOW_PROCS="${TUNNEL_PORT_ALLOWLIST:-$DEFAULT_ALLOW}"
BLOCK_PROCS="${TUNNEL_PORT_BLOCKLIST:-$DEFAULT_BLOCK}"

# Generous fallback: any node-family runtime listening on a common dev-port
# range counts even when missing from the curated allowlist.
GENEROUS_PROCS="node bun deno"
GENEROUS_MIN=3000
GENEROUS_MAX=9999

# ── PID file + signal handling ───────────────────────────────────────
echo "$$" > "$PID_FILE"

_cleanup() {
  rm -f "$PID_FILE" 2>/dev/null || true
}
trap '_cleanup' EXIT
trap 'exit 0' TERM INT HUP

_log "starting (interval=${INTERVAL}s, range=${MIN_PORT}-${MAX_PORT}, pid=$$)"

# ── Membership test (whole-word against space-delimited list) ────────
_in_list() {
  local needle="$1" haystack="$2"
  case " $haystack " in
    *" $needle "*) return 0 ;;
  esac
  return 1
}

# ── Parse a single ss -tlnp line ─────────────────────────────────────
# Echoes "port:proc" on a match, nothing otherwise. Hardened so any
# malformed line returns 0 instead of killing the daemon under set -e.
_parse_ss_line() {
  local line="$1"
  local state recvq sendq local_addr peer users_field
  local port proc tmp

  # ss -tlnpH columns: State Recv-Q Send-Q Local-Addr Peer-Addr Process
  # Default IFS splits on whitespace.
  # shellcheck disable=SC2086
  set -- $line
  [ "$#" -ge 6 ] || return 0
  state="$1"; shift
  recvq="$1"; shift
  sendq="$1"; shift
  local_addr="$1"; shift
  peer="$1"; shift
  users_field="$*"

  # Defensive: silence "unused" complaints from set -u (these are parsed
  # so the columns line up; we don't actually use them downstream).
  : "$recvq" "$sendq" "$peer"

  # Skip the header line if it slipped through (when -H is unsupported)
  case "$state" in
    State|state|"") return 0 ;;
  esac

  # Extract port: everything after the last ":". Handles 0.0.0.0:5173,
  # 127.0.0.1:5173, [::1]:3000, *:9000, 127.0.0.53%lo:53.
  port="${local_addr##*:}"
  case "$port" in
    ""|*[!0-9]*) return 0 ;;
  esac

  # Range filter
  if [ "$port" -lt "$MIN_PORT" ] || [ "$port" -gt "$MAX_PORT" ]; then
    return 0
  fi

  # Extract process name from users:(("name",pid=N,fd=M))
  # Pure parameter expansion — no awk, no regex capture groups.
  proc=""
  case "$users_field" in
    *'users:(("'*)
      tmp="${users_field#*users:((\"}"
      proc="${tmp%%\"*}"
      ;;
  esac
  [ -n "$proc" ] || return 0

  # Block list takes precedence over allowlist
  if _in_list "$proc" "$BLOCK_PROCS"; then
    return 0
  fi

  # Curated allowlist
  if _in_list "$proc" "$ALLOW_PROCS"; then
    printf '%s:%s\n' "$port" "$proc"
    return 0
  fi

  # Generous fallback: node-family runtime in common dev-server range
  if [ "$port" -ge "$GENEROUS_MIN" ] && [ "$port" -le "$GENEROUS_MAX" ]; then
    if _in_list "$proc" "$GENEROUS_PROCS"; then
      printf '%s:%s\n' "$port" "$proc"
      return 0
    fi
  fi

  return 0
}

# ── Snapshot all matching ports as a sorted, deduped CSV ─────────────
_collect_snapshot() {
  local raw collected="" sorted result="" prev="" line entry port

  # Try -H (no header) first; fall back to manual header skip if absent.
  raw=$(ss -tlnpH 2>/dev/null || true)
  if [ -z "$raw" ]; then
    raw=$(ss -tlnp 2>/dev/null | tail -n +2 || true)
  fi
  if [ -z "$raw" ]; then
    printf ''
    return 0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    entry=$(_parse_ss_line "$line" || true)
    [ -n "$entry" ] || continue
    if [ -z "$collected" ]; then
      collected="$entry"
    else
      collected="${collected}
${entry}"
    fi
  done <<EOF
$raw
EOF

  if [ -z "$collected" ]; then
    printf ''
    return 0
  fi

  # Sort numerically by port, then dedupe (a process listening on both
  # IPv4 and IPv6 emits two lines for the same port).
  sorted=$(printf '%s\n' "$collected" | LC_ALL=C sort -t: -k1,1n)

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    port="${line%%:*}"
    [ "$port" = "$prev" ] && continue
    prev="$port"
    if [ -z "$result" ]; then
      result="$line"
    else
      result="${result},${line}"
    fi
  done <<EOF
$sorted
EOF

  printf '%s' "$result"
}

# ── Atomic update of TUNNEL_PORTS_LIST in tunnel.env ─────────────────
# Preserves every other line; replaces (or appends) the single
# TUNNEL_PORTS_LIST=... entry. Atomic via temp-file + mv on same FS.
_write_tunnel_env() {
  local value="$1"
  local tmp="${TUNNEL_ENV}.tmp"
  local line

  : > "$tmp"
  if [ -f "$TUNNEL_ENV" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        TUNNEL_PORTS_LIST=*) ;;
        *) printf '%s\n' "$line" >> "$tmp" ;;
      esac
    done < "$TUNNEL_ENV"
  fi
  printf 'TUNNEL_PORTS_LIST=%s\n' "$value" >> "$tmp"
  mv -f "$tmp" "$TUNNEL_ENV"
}

# ── Main loop ────────────────────────────────────────────────────────
last_value=""
first=1

while :; do
  current=$(_collect_snapshot || true)

  if [ "$first" -eq 1 ] || [ "$current" != "$last_value" ]; then
    if _write_tunnel_env "$current"; then
      _log "ports: ${current:-<none>}"
    else
      _log "write failed for tunnel.env"
    fi
    last_value="$current"
    first=0
  fi

  sleep "$INTERVAL"
done
