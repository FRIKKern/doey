#!/usr/bin/env bash
# doey-discord.sh — Discord integration CLI wrapper.
# Sourceable library; thin pass-through to `doey-tui discord <sub>`.
# Real work lives in Go (tui/internal/discord). This wrapper owns only
# the local usage block and the subcommand allowlist.
set -euo pipefail

[ "${__doey_discord_sourced:-}" = "1" ] && return 0
__doey_discord_sourced=1

doey_discord_usage() {
  cat <<'EOF'
Usage: doey discord <subcommand> [args]

Subcommands:
  status [--json]         Show binding state and creds validity
  bind [--kind KIND]      Bind a destination (webhook | bot_dm)
  unbind                  Remove the binding pointer
  send                    Send a notification — body on stdin
  send-test               Send a test message (bypasses coalesce)
  failures [--tail N] [--prune] [--retry ID]
                          Failure log management
  reset-breaker           Clear the circuit breaker
  doctor-network          Opt-in network probe (GET webhook URL, 60s cached)
  help                    Show this message

See docs/discord.md for setup.
EOF
}

doey_discord() {
  local sub="${1:-help}"
  if [ "$#" -gt 0 ]; then shift; fi

  case "$sub" in
    help|-h|--help|"")
      doey_discord_usage
      return 0
      ;;
    status|bind|unbind|send|send-test|failures|reset-breaker|doctor-network)
      if ! command -v doey-tui >/dev/null 2>&1; then
        printf 'doey-tui not found on PATH — run "doey update" to build/install\n' >&2
        return 1
      fi
      exec doey-tui discord "$sub" "$@"
      ;;
    *)
      printf "doey discord: unknown subcommand '%s'\n" "$sub" >&2
      doey_discord_usage >&2
      return 2
      ;;
  esac
}
