package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/doey-cli/doey/tui/internal/search"
	"github.com/doey-cli/doey/tui/internal/store"
)

func runSearchCmd(args []string) {
	if len(args) > 0 && isHelp(args[0]) {
		printSearchHelp()
		return
	}

	fs := flag.NewFlagSet("search", flag.ExitOnError)
	url := fs.String("url", "", "Search task_urls by host substring (enables URL mode)")
	typ := fs.String("type", "", "Text-search scope: task|message|decision|log (default: task)")
	since := fs.String("since", "", "Only results since the given duration (30d, 2w, 6h) or YYYY-MM-DD")
	limit := fs.Int("limit", 20, "Maximum results (1-100)")
	kind := fs.String("kind", "", "(--url only) Filter by URL kind: figma|github|slack|linear|sanity|loom|notion|generic")
	field := fs.String("field", "", "(--url only) Filter by source field (e.g. title, description, log:42:body)")
	verbose := fs.Bool("verbose", false, "Show BM25 scores in human output")
	dir := fs.String("project-dir", "", "Project directory")
	backfill := fs.Bool("backfill-urls", false, "Re-extract URLs over every task/subtask/log row (idempotent)")
	fs.BoolVar(&jsonOutput, "json", false, "Emit JSON list of SearchResult records")
	fs.Parse(args)

	s := tryOpenStore(projectDir(*dir))
	if s == nil {
		fatalCode(ExitNotFound, "search: requires DB (.doey/doey.db)\n")
	}
	defer s.Close()

	if *backfill {
		runBackfillURLs(s)
		return
	}

	sinceT, err := search.ParseSince(*since)
	if err != nil {
		fatalCode(ExitUsage, "search: %v\n", err)
	}

	var results []search.SearchResult

	if *url != "" {
		results, err = search.URLSearch(s.DB(), search.URLSearchOpts{
			Pattern: *url,
			Kind:    *kind,
			Field:   *field,
			Since:   sinceT,
			Limit:   *limit,
		})
		if err != nil {
			fatal("search: url: %v\n", err)
		}
	} else {
		query := strings.TrimSpace(strings.Join(fs.Args(), " "))
		if query == "" {
			fatalCode(ExitUsage, "search: <query> required (or use --url <pattern>)\nRun 'doey-ctl search -h' for usage.\n")
		}
		results, err = search.TextSearch(s.DB(), search.TextSearchOpts{
			Query: query,
			Type:  *typ,
			Since: sinceT,
			Limit: *limit,
		})
		if err != nil {
			fatal("search: text: %v\n", err)
		}
	}

	if jsonOutput {
		printJSON(results)
	} else {
		printSearchResultsHuman(results, *verbose, *url != "")
	}

	if len(results) == 0 {
		os.Exit(ExitGeneral)
	}
}

func printSearchResultsHuman(results []search.SearchResult, verbose, urlMode bool) {
	if len(results) == 0 {
		fmt.Fprintln(os.Stderr, "(no results)")
		return
	}
	for _, r := range results {
		short := r.Shortname
		if short == "" {
			short = "-"
		}
		title := r.Title
		if title == "" {
			title = "(no title)"
		}
		if urlMode {
			line := fmt.Sprintf("[task#%d] [%s] %s — %s [%s]", r.TaskID, short, title, r.MatchedURL, r.MatchedField)
			fmt.Println(line)
			continue
		}
		snippet := strings.TrimSpace(r.Snippet)
		if snippet == "" {
			snippet = "(no snippet)"
		}
		line := fmt.Sprintf("[task#%d] [%s] %s — %s", r.TaskID, short, title, snippet)
		if verbose {
			line += fmt.Sprintf("  (score=%.3f)", r.Score)
		}
		fmt.Println(line)
	}
}

// runBackfillURLs walks every text-bearing row in tasks/subtasks/task_log and
// re-runs StoreURLs for each labeled field. The DELETE-then-INSERT pattern
// inside StoreURLs makes the operation rerunnable without duplicates.
func runBackfillURLs(s *store.Store) {
	db := s.DB()

	taskFields := []string{"title", "description", "notes", "acceptance_criteria"}

	type taskRow struct {
		id      int64
		fields  map[string]string
	}

	var totalURLs, processed int

	rows, err := db.Query(`SELECT id, COALESCE(title,''), COALESCE(description,''), COALESCE(notes,''), COALESCE(acceptance_criteria,'') FROM tasks`)
	if err != nil {
		fatal("backfill: tasks query: %v\n", err)
	}
	var taskRows []taskRow
	for rows.Next() {
		var id int64
		var title, desc, notes, ac string
		if err := rows.Scan(&id, &title, &desc, &notes, &ac); err != nil {
			rows.Close()
			fatal("backfill: scan task: %v\n", err)
		}
		taskRows = append(taskRows, taskRow{
			id: id,
			fields: map[string]string{
				"title":               title,
				"description":         desc,
				"notes":               notes,
				"acceptance_criteria": ac,
			},
		})
	}
	rows.Close()

	for _, tr := range taskRows {
		for _, f := range taskFields {
			if err := search.StoreURLs(db, tr.id, f, tr.fields[f]); err != nil {
				fmt.Fprintf(os.Stderr, "backfill: task %d/%s: %v\n", tr.id, f, err)
				continue
			}
			totalURLs += len(search.ExtractURLs(tr.fields[f]))
		}
		processed++
	}

	subRows, err := db.Query(`SELECT task_id, seq, COALESCE(title,'') FROM subtasks`)
	if err != nil {
		fatal("backfill: subtasks query: %v\n", err)
	}
	defer subRows.Close()
	for subRows.Next() {
		var taskID int64
		var seq int
		var title string
		if err := subRows.Scan(&taskID, &seq, &title); err != nil {
			fatal("backfill: scan subtask: %v\n", err)
		}
		field := fmt.Sprintf("subtask:%d:title", seq)
		if err := search.StoreURLs(db, taskID, field, title); err != nil {
			fmt.Fprintf(os.Stderr, "backfill: subtask %d/%d: %v\n", taskID, seq, err)
			continue
		}
		totalURLs += len(search.ExtractURLs(title))
	}

	logRows, err := db.Query(`SELECT id, task_id, COALESCE(title,''), COALESCE(body,'') FROM task_log`)
	if err != nil {
		fatal("backfill: task_log query: %v\n", err)
	}
	defer logRows.Close()
	for logRows.Next() {
		var id, taskID int64
		var title, body string
		if err := logRows.Scan(&id, &taskID, &title, &body); err != nil {
			fatal("backfill: scan log: %v\n", err)
		}
		_ = search.StoreURLs(db, taskID, fmt.Sprintf("log:%d:title", id), title)
		_ = search.StoreURLs(db, taskID, fmt.Sprintf("log:%d:body", id), body)
		totalURLs += len(search.ExtractURLs(title)) + len(search.ExtractURLs(body))
	}

	if jsonOutput {
		printJSON(map[string]int{"tasks_processed": processed, "urls_indexed": totalURLs})
	} else {
		fmt.Printf("backfill: processed %d tasks, indexed %d URLs\n", processed, totalURLs)
	}
}

func printSearchHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl search [flags] <query>

Modes:
  doey-ctl search "auth flow"            FTS5 search across tasks (title, desc, shortname)
  doey-ctl search --type message "auth"  FTS5 search across messages
  doey-ctl search --url figma            URL host search (LIKE %%pattern%%)
  doey-ctl search --backfill-urls        Re-extract URLs from every existing row

Flags:
  --url <pattern>      Match URL host substring (enables URL mode)
  --type <task|message|decision|log>
                       Scope text search (default: task)
  --since <30d|2w|6h|YYYY-MM-DD>
                       Filter by recency
  --limit <int>        Result cap (default 20, max 100)
  --kind <figma|github|slack|...>
                       (--url only) filter by classified URL kind
  --field <name>       (--url only) restrict to a labeled source field
  --json               Emit JSON
  --verbose            Show BM25 scores in human output
  --backfill-urls      Re-extract URLs over every task/subtask/log row

Exits 1 if no results.
`)
}
