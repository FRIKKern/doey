package cli

import (
	"flag"
	"fmt"
	"io"

	"github.com/doey-cli/doey/tui/internal/discord"
	"github.com/doey-cli/doey/tui/internal/discord/redact"
)

// runResetBreaker clears the circuit breaker fields in discord-rl.state.
// Runs under the state flock so it cannot race a live sender.
func runResetBreaker(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("reset-breaker", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	projDir := projectDir()
	err := discord.WithFlock(projDir, func(_ int) error {
		st, err := discord.Load(projDir)
		if err != nil || st == nil {
			st = &discord.RLState{V: discord.RLStateVersion}
		}
		ns := discord.ResetBreaker(st)
		return discord.SaveAtomic(projDir, ns)
	})
	if err != nil {
		fmt.Fprintf(stderr, "discord reset-breaker: %s\n", redact.Redact(err.Error()))
		return 1
	}
	fmt.Fprintln(stdout, "circuit breaker reset")
	return 0
}
