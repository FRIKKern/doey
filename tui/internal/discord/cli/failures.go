package cli

import (
	"flag"
	"fmt"
	"io"

	"github.com/doey-cli/doey/tui/internal/discord"
	"github.com/doey-cli/doey/tui/internal/discord/redact"
)

// runFailures inspects and manages the Discord failure log.
//
//	--tail N       print the last N entries (default 10)
//	--prune        keep only FailedLogMaxEntries newest lines
//	--retry ID     print the matching entry with a "may duplicate" note
func runFailures(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("failures", flag.ContinueOnError)
	fs.SetOutput(stderr)
	tail := fs.Int("tail", 10, "number of recent entries to print")
	prune := fs.Bool("prune", false, "prune log to FailedLogMaxEntries newest lines")
	retry := fs.String("retry", "", "find entry by id and print retry guidance")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	projDir := projectDir()

	if *prune {
		removed, err := discord.PruneFailures(projDir, discord.FailedLogMaxEntries)
		if err != nil {
			fmt.Fprintf(stderr, "discord failures: %s\n", redact.Redact(err.Error()))
			return 1
		}
		fmt.Fprintf(stdout, "pruned %d entries\n", removed)
		return 0
	}

	if *retry != "" {
		entries, err := discord.TailFailures(projDir, 10000)
		if err != nil {
			fmt.Fprintf(stderr, "discord failures: %s\n", redact.Redact(err.Error()))
			return 1
		}
		for _, e := range entries {
			if e.ID == *retry {
				fmt.Fprintf(stdout, "%s %s [%s] %s — %s\n",
					e.ID, e.Ts, e.Event,
					redact.Redact(e.Title), redact.Redact(e.Error))
				fmt.Fprintln(stdout, "retry: re-run the original send invocation (manual; full replay lands in Phase 4)")
				fmt.Fprintln(stderr, "note: retry may duplicate — Discord has no idempotency key")
				return 0
			}
		}
		fmt.Fprintf(stderr, "discord failures: no entry with id %q\n", *retry)
		return 1
	}

	n := *tail
	if n <= 0 {
		n = 10
	}
	entries, err := discord.TailFailures(projDir, n)
	if err != nil {
		fmt.Fprintf(stderr, "discord failures: %s\n", redact.Redact(err.Error()))
		return 1
	}
	for _, e := range entries {
		fmt.Fprintf(stdout, "%s %s [%s] %s — %s\n",
			e.ID, e.Ts, e.Event,
			redact.Redact(e.Title), redact.Redact(e.Error))
	}
	return 0
}
