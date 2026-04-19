package cli

import (
	"fmt"
	"io"
)

// runStub implements the Phase-1 placeholder subcommands. Each prints a
// deterministic message to stderr naming the phase that lands the real
// implementation, then exits 1. The literal wording is a contract for
// future workers and integration tests.
func runStub(name string, phase int, stderr io.Writer) int {
	fmt.Fprintf(stderr, "%s: lands in Phase %d — see docs/discord.md\n", name, phase)
	if name == "unbind" {
		fmt.Fprintln(stderr, "  for now: rm <project>/.doey/discord-binding")
	}
	return 1
}
