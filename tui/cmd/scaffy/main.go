// Command scaffy is the entry point for the Scaffy template engine.
//
// All command wiring, flag parsing, and exit-code logic lives in
// internal/scaffy/cli — this binary is intentionally a thin shim so the
// CLI surface can be tested as a library and reused from other entry
// points (e.g. an MCP serve subcommand or a Doey-embedded skill).
package main

import (
	"os"

	"github.com/doey-cli/doey/tui/internal/scaffy/cli"
)

func main() {
	if err := cli.Execute(); err != nil {
		os.Exit(cli.ExitCodeFromError(err))
	}
}
