package cli

import (
	"flag"
	"fmt"
	"io"

	"github.com/doey-cli/doey/tui/internal/discord/binding"
	"github.com/doey-cli/doey/tui/internal/discord/redact"
)

// runUnbind deletes the per-project binding pointer, leaving creds intact.
// Exit 0 on success or when the file was already absent; exit 1 on I/O error.
func runUnbind(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("unbind", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if err := binding.Delete(projectDir()); err != nil {
		fmt.Fprintf(stderr, "discord unbind: %s\n", redact.Redact(err.Error()))
		return 1
	}
	fmt.Fprintln(stdout, "Discord binding removed — creds preserved")
	return 0
}
