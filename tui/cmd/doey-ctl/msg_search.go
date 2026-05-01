package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/search"
)

func msgSearch(args []string) {
	if len(args) > 0 && isHelp(args[0]) {
		printMsgSearchHelp()
		return
	}

	fs := flag.NewFlagSet("msg search", flag.ExitOnError)
	limit := fs.Int("limit", 20, "Maximum results (1-100)")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "Emit JSON list of MessageSearchResult records")
	fs.Parse(args)

	query := strings.TrimSpace(strings.Join(fs.Args(), " "))
	if query == "" {
		fatalCode(ExitUsage, "msg search: <query> required\nRun 'doey-ctl msg search -h' for usage.\n")
	}

	s := tryOpenStore(projectDir(*dir))
	if s == nil {
		fatalCode(ExitNotFound, "msg search: requires DB (.doey/doey.db)\n")
	}
	defer s.Close()

	results, err := search.MessageSearch(s.DB(), query, *limit)
	if err != nil {
		fatal("msg search: %v\n", err)
	}

	if jsonOutput {
		printJSON(results)
	} else {
		printMsgSearchResultsHuman(results)
	}

	if len(results) == 0 {
		os.Exit(ExitGeneral)
	}
}

func printMsgSearchResultsHuman(results []search.MessageSearchResult) {
	if len(results) == 0 {
		fmt.Fprintln(os.Stderr, "(no results)")
		return
	}
	for _, r := range results {
		subject := r.Subject
		if subject == "" {
			subject = "(no subject)"
		}
		snippet := strings.TrimSpace(r.Snippet)
		if snippet == "" {
			snippet = "(no snippet)"
		}
		ts := ""
		if !r.CreatedAt.IsZero() {
			ts = r.CreatedAt.Format(time.RFC3339)
		}
		fmt.Printf("[msg#%d] %s → %s  %s\n  %s — %s\n",
			r.ID, r.FromPane, r.ToPane, ts, subject, snippet)
	}
}

func printMsgSearchHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl msg search [flags] <query>

Full-text search across the messages table (subject + body via messages_fts).
Reuses the same FTS5 sanitizer as 'doey-ctl search' — special characters and
operator words become literal phrase content.

Flags:
  --limit <int>       Result cap (default 20, max 100)
  --json              Emit JSON list of MessageSearchResult
  --project-dir <p>   Override project directory (default: nearest .doey/ ancestor)

Examples:
  doey-ctl msg search 'auth flow'
  doey-ctl msg search --limit 5 --json error

Exits 1 if no results.
`)
}
