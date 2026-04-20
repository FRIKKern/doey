// Package cli implements the `doey-tui discord` subcommand surface.
//
// Phase-2 scope:
//   - status [--json]        — fully functional
//   - send                   — real delivery pipeline (ADR-4)
//   - unbind                 — delete binding pointer, preserve creds
//   - send-test              — bypass-coalesce probe send
//   - failures               — tail / prune / retry the failure log
//   - reset-breaker          — clear circuit breaker under flock
//   - doctor-network         — 60s cached webhook probe
//   - bind                   — Phase-3 stub
//
// This package must NOT import bubbletea/sqlite/lipgloss or any
// tui/internal/model/* package. Allowed deps: stdlib,
// tui/internal/discord/{config,binding,redact,sender}, tui/internal/discord.
package cli

import (
	"fmt"
	"io"
	"os"
)

// Run dispatches the discord subcommand. args is the tail after "discord"
// (i.e., args[0] is the sub-subcommand like "status"). Returns a process
// exit code; does NOT call os.Exit so callers can test it.
func Run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "doey-tui discord: missing subcommand (try: status, send, bind, unbind, send-test, failures, reset-breaker, doctor-network)")
		return 2
	}
	sub := args[0]
	rest := args[1:]
	switch sub {
	case "status":
		return runStatus(rest, stdout, stderr)
	case "send":
		return runSend(rest, stdout, stderr)
	case "bind":
		return runStub("bind", 3, stderr)
	case "unbind":
		return runUnbind(rest, stdout, stderr)
	case "send-test":
		return runSendTest(rest, stdout, stderr)
	case "failures":
		return runFailures(rest, stdout, stderr)
	case "reset-breaker":
		return runResetBreaker(rest, stdout, stderr)
	case "doctor-network":
		return runDoctorNetwork(rest, stdout, stderr)
	case "-h", "--help", "help":
		fmt.Fprintln(stdout, usage)
		return 0
	default:
		fmt.Fprintf(stderr, "doey-tui discord: unknown subcommand %q\n", sub)
		return 2
	}
}

const usage = `Usage: doey-tui discord <subcommand> [args]

Subcommands:
  status [--json]   Show binding + creds state
  send              Send a notification (body on stdin)
  bind              Bind a destination (Phase 3)
  unbind            Remove binding (creds preserved)
  send-test         Send a fixed probe message (bypasses coalesce)
  failures          Tail / prune / retry the failure log
  reset-breaker     Clear the circuit breaker
  doctor-network    Probe the bound webhook (60s cached)`

// projectDir resolves the project directory, preferring $PROJECT_DIR env
// over os.Getwd() so callers (shell wrapper, tests) can override.
func projectDir() string {
	if p := os.Getenv("PROJECT_DIR"); p != "" {
		return p
	}
	wd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return wd
}
