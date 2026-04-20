package cli

import (
	"fmt"
	"io"
)

// runStub implements the remaining placeholder subcommands. In Phase 2
// only `bind` is still a stub (the interactive wizard lands in Phase 3).
// The literal wording is a contract for integration tests.
func runStub(name string, phase int, stderr io.Writer) int {
	fmt.Fprintf(stderr, "%s: lands in Phase %d — see docs/discord.md\n", name, phase)
	return 1
}
