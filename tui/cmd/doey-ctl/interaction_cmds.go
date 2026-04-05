package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/doey-cli/doey/tui/internal/store"
)

func runInteractionCmd(args []string) {
	if len(args) < 1 {
		printInteractionHelp()
		fatal("interaction: missing subcommand: log, list, search, stats\nRun 'doey-ctl interaction --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printInteractionHelp()
		return
	}
	switch args[0] {
	case "log":
		runInteractionLog(args[1:])
	case "list":
		runInteractionList(args[1:])
	case "search":
		runInteractionSearch(args[1:])
	case "stats":
		runInteractionStats(args[1:])
	default:
		fatal("interaction: unknown subcommand: %q. Valid: log, list, search, stats\n", args[0])
	}
}

func printInteractionHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl interaction <subcommand> [flags]

Subcommands:
  log       Log an interaction
  list      List interactions
  search    Search interaction text
  stats     Show interaction stats by type

Run 'doey-ctl interaction <subcommand> -h' for help.
`)
}

func runInteractionLog(args []string) {
	fs := flag.NewFlagSet("interaction log", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	session := fs.String("session", "", "Session name")
	taskID := fs.Int64("task-id", 0, "Associated task ID")
	message := fs.String("message", "", "Message text (required)")
	msgType := fs.String("type", "other", "Message type (command, question, feedback, status, other)")
	source := fs.String("source", "user", "Source (user, taskmaster, worker)")
	context := fs.String("context", "", "Context description")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *message == "" {
		fatal("interaction log: --message is required\nRun 'doey-ctl interaction log -h' for usage.\n")
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)
	if s == nil {
		if jsonOutput {
			printJSON(map[string]string{"status": "skipped", "reason": "no database"})
		}
		return
	}
	defer s.Close()

	i := store.Interaction{
		SessionName: *session,
		MessageText: *message,
		MessageType: *msgType,
		Source:      *source,
		Context:     *context,
	}
	if *taskID != 0 {
		i.TaskID = taskID
	}

	id, err := s.LogInteraction(i)
	if err != nil {
		fatal("interaction log: %v\n", err)
	}
	if jsonOutput {
		i.ID = id
		printJSON(i)
		return
	}
	fmt.Printf("logged interaction %d\n", id)
}

func runInteractionList(args []string) {
	fs := flag.NewFlagSet("interaction list", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	limit := fs.Int("limit", 50, "Max interactions to return")
	taskID := fs.Int64("task-id", 0, "Filter by task ID")
	msgType := fs.String("type", "", "Filter by message type")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s := openStore(*dir)
	defer s.Close()

	var interactions []store.Interaction
	var err error

	switch {
	case *taskID != 0:
		interactions, err = s.ListInteractionsByTask(*taskID)
	case *msgType != "":
		interactions, err = s.ListInteractionsByType(*msgType, *limit)
	default:
		interactions, err = s.ListInteractions(*limit)
	}
	if err != nil {
		fatal("interaction list: %v\n", err)
	}
	if jsonOutput {
		printJSON(interactions)
		return
	}
	for _, i := range interactions {
		ts := time.Unix(i.CreatedAt, 0).Format("2006-01-02 15:04")
		taskRef := "-"
		if i.TaskID != nil {
			taskRef = fmt.Sprintf("#%d", *i.TaskID)
		}
		text := i.MessageText
		if len(text) > 60 {
			text = text[:57] + "..."
		}
		fmt.Printf("%-6d %s  %-8s %-10s %-10s %s\n", i.ID, ts, taskRef, i.MessageType, i.Source, text)
	}
}

func runInteractionSearch(args []string) {
	fs := flag.NewFlagSet("interaction search", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	query := fs.String("query", "", "Search query (required)")
	limit := fs.Int("limit", 50, "Max results")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *query == "" {
		fatal("interaction search: --query is required\nRun 'doey-ctl interaction search -h' for usage.\n")
	}

	s := openStore(*dir)
	defer s.Close()

	interactions, err := s.SearchInteractions(*query, *limit)
	if err != nil {
		fatal("interaction search: %v\n", err)
	}
	if jsonOutput {
		printJSON(interactions)
		return
	}
	for _, i := range interactions {
		ts := time.Unix(i.CreatedAt, 0).Format("2006-01-02 15:04")
		text := i.MessageText
		if len(text) > 60 {
			text = text[:57] + "..."
		}
		fmt.Printf("%-6d %s  %-10s %s\n", i.ID, ts, i.MessageType, text)
	}
}

func runInteractionStats(args []string) {
	fs := flag.NewFlagSet("interaction stats", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s := openStore(*dir)
	defer s.Close()

	stats, err := s.InteractionStats()
	if err != nil {
		fatal("interaction stats: %v\n", err)
	}
	if jsonOutput {
		printJSON(stats)
		return
	}
	for typ, count := range stats {
		fmt.Printf("%-15s %d\n", typ, count)
	}
}
