#!/usr/bin/env bash
# doey-lifecycle.sh — Shell wrapper for lifecycle event queries.
# Forwards to doey-ctl lifecycle subcommands.
set -euo pipefail

# Source guard
[ "${__doey_lifecycle_sourced:-}" = "1" ] && return 0
__doey_lifecycle_sourced=1

doey_lifecycle() {
  if command -v doey-ctl >/dev/null 2>&1; then
    doey-ctl lifecycle "$@"
  else
    printf 'Error: doey-ctl not installed. Run "doey doctor" or reinstall.\n' >&2
    return 1
  fi
}
