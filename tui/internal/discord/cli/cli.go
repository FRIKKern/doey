// Package cli implements the `doey-tui discord` subcommand surface.
//
// Phase-1 scope (task 612 subtask 4):
//   - status [--json]        — fully functional
//   - send                   — Phase-1 refusal; two disjoint error branches
//   - bind, unbind, send-test, failures, reset-breaker — Phase-1 stubs
//
// This package must NOT import bubbletea/sqlite/lipgloss or any
// tui/internal/model/* package: it sits on the cold-start path and keeps
// the binary's discord subcommand cheap. Allowed deps: stdlib,
// tui/internal/discord/config, tui/internal/discord/binding.
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
		fmt.Fprintln(stderr, "doey-tui discord: missing subcommand (try: status, send, bind, unbind, send-test, failures, reset-breaker)")
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
		return runStub("unbind", 2, stderr)
	case "send-test":
		return runStub("send-test", 2, stderr)
	case "failures":
		return runStub("failures", 2, stderr)
	case "reset-breaker":
		return runStub("reset-breaker", 2, stderr)
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
  status [--json]   Show binding + creds state (exit 0)
  send              Send a notification (Phase 1: refusal)
  bind              Bind a destination (Phase 3)
  unbind            Remove binding (Phase 2)
  send-test         Send a test message (Phase 2)
  failures          Failure log management (Phase 2)
  reset-breaker     Clear the circuit breaker (Phase 2)`

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
