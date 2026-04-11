package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/store"
)

// --- plan subcommand ---

func runPlanCmd(args []string) {
	if len(args) < 1 {
		printPlanHelp()
		fatal("plan: missing subcommand: list, get, create, update, delete\nRun 'doey-ctl plan --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printPlanHelp()
		return
	}
	switch args[0] {
	case "list":
		planList(args[1:])
	case "get":
		planGet(args[1:])
	case "create":
		planCreate(args[1:])
	case "update":
		planUpdate(args[1:])
	case "delete":
		planDelete(args[1:])
	default:
		fatal("plan: unknown subcommand: %q. Valid: list, get, create, update, delete\n", args[0])
	}
}

func printPlanHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl plan <subcommand> [flags]

Subcommands:
  list      List plans
  get       Show plan details
  create    Create a new plan
  update    Update plan fields
  delete    Delete a plan

Run 'doey-ctl plan <subcommand> -h' for help.
`)
}

func planList(args []string) {
	fs := flag.NewFlagSet("plan list", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s := openStore(*dir)
	defer s.Close()

	plans, err := s.ListPlans()
	if err != nil {
		fatal("plan list: %v\n", err)
	}
	if jsonOutput {
		printJSON(plans)
		return
	}
	for _, p := range plans {
		taskCol := "-"
		if p.TaskID != nil {
			taskCol = fmt.Sprintf("#%d", *p.TaskID)
		}
		fmt.Printf("%-4d %-6s %-10s %s\n", p.ID, taskCol, p.Status, p.Title)
	}
}

func planGet(args []string) {
	fs := flag.NewFlagSet("plan get", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("plan get: <id> argument required\nRun 'doey-ctl plan get -h' for usage.\n")
	}
	id := int64(atoiOrFatal(fs.Arg(0), "plan get"))

	s := openStore(*dir)
	defer s.Close()

	p, err := s.GetPlan(id)
	if err != nil {
		fatal("plan get: %v\n", err)
	}
	if jsonOutput {
		printJSON(p)
		return
	}
	fmt.Printf("id=%d title=%s status=%s\n%s\n", p.ID, p.Title, p.Status, p.Body)
}

func planCreate(args []string) {
	fs := flag.NewFlagSet("plan create", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	title := fs.String("title", "", "Plan title")
	status := fs.String("status", "draft", "Plan status")
	body := fs.String("body", "", "Plan body")
	taskID := fs.Int64("task-id", 0, "Associated task ID (required)")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *title == "" {
		fatal("plan create: --title is required\nRun 'doey-ctl plan create -h' for usage.\n")
	}
	if *taskID == 0 {
		fatal("plan create: --task-id is required\nRun 'doey-ctl plan create -h' for usage.\n")
	}

	s := openStore(*dir)
	defer s.Close()

	p := &store.Plan{TaskID: taskID, Title: *title, Status: *status, Body: *body}
	id, err := s.CreatePlan(p)
	if err != nil {
		fatal("plan create: %v\n", err)
	}

	// Link task back to this plan
	task, err := s.GetTask(*taskID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "plan create: warning: could not fetch task %d to set plan_id: %v\n", *taskID, err)
	} else {
		task.PlanID = &id
		if err := s.UpdateTask(task); err != nil {
			fmt.Fprintf(os.Stderr, "plan create: warning: could not update task %d plan_id: %v\n", *taskID, err)
		}
	}

	if jsonOutput {
		printJSON(p)
		return
	}
	fmt.Printf("created plan %d\n", id)
}

func planUpdate(args []string) {
	fs := flag.NewFlagSet("plan update", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	title := fs.String("title", "", "Plan title")
	status := fs.String("status", "", "Plan status")
	body := fs.String("body", "", "Plan body")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("plan update: <id> argument required\nRun 'doey-ctl plan update -h' for usage.\n")
	}
	id := int64(atoiOrFatal(fs.Arg(0), "plan update"))

	s := openStore(*dir)
	defer s.Close()

	p, err := s.GetPlan(id)
	if err != nil {
		fatal("plan update: %v\n", err)
	}
	if *title != "" {
		p.Title = *title
	}
	if *status != "" {
		p.Status = *status
	}
	if *body != "" {
		p.Body = *body
	}
	if err := s.UpdatePlan(p); err != nil {
		fatal("plan update: %v\n", err)
	}
	if jsonOutput {
		printJSON(p)
		return
	}
	fmt.Printf("updated plan %d\n", id)
}

func planDelete(args []string) {
	fs := flag.NewFlagSet("plan delete", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("plan delete: <id> argument required\nRun 'doey-ctl plan delete -h' for usage.\n")
	}
	id := int64(atoiOrFatal(fs.Arg(0), "plan delete"))

	s := openStore(*dir)
	defer s.Close()

	if err := s.DeletePlan(id); err != nil {
		fatal("plan delete: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]any{"status": "deleted", "id": id})
		return
	}
	fmt.Printf("deleted plan %d\n", id)
}

// --- team subcommand ---

func runTeamCmd(args []string) {
	if len(args) < 1 {
		printTeamHelp()
		fatal("team: missing subcommand: list, get, set, delete\nRun 'doey-ctl team --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printTeamHelp()
		return
	}
	switch args[0] {
	case "list":
		teamList(args[1:])
	case "get":
		teamGet(args[1:])
	case "set":
		teamSet(args[1:])
	case "delete":
		teamDelete(args[1:])
	default:
		fatal("team: unknown subcommand: %q. Valid: list, get, set, delete\n", args[0])
	}
}

func printTeamHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl team <subcommand> [flags]

Subcommands:
  list      List teams
  get       Show team details
  set       Create or update a team
  delete    Delete a team record

Run 'doey-ctl team <subcommand> -h' for help.
`)
}

func teamList(args []string) {
	fs := flag.NewFlagSet("team list", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s := openStore(*dir)
	defer s.Close()

	teams, err := s.ListTeams()
	if err != nil {
		fatal("team list: %v\n", err)
	}
	if jsonOutput {
		printJSON(teams)
		return
	}
	for _, t := range teams {
		fmt.Printf("%-8s %-15s %-10s panes=%d\n", t.WindowID, t.Name, t.Type, t.PaneCount)
	}
}

func teamGet(args []string) {
	fs := flag.NewFlagSet("team get", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("team get: <window-id> argument required\nRun 'doey-ctl team get -h' for usage.\n")
	}
	windowID := fs.Arg(0)

	s := openStore(*dir)
	defer s.Close()

	t, err := s.GetTeam(windowID)
	if err != nil {
		fatal("team get: %v\n", err)
	}
	if jsonOutput {
		printJSON(t)
		return
	}
	fmt.Printf("window_id=%s name=%s type=%s panes=%d\n", t.WindowID, t.Name, t.Type, t.PaneCount)
}

func teamSet(args []string) {
	fs := flag.NewFlagSet("team set", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	windowID := fs.String("window-id", "", "Window ID")
	name := fs.String("name", "", "Team name")
	typ := fs.String("type", "", "Team type")
	worktree := fs.String("worktree-path", "", "Worktree path")
	paneCount := fs.Int("pane-count", 0, "Pane count")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *windowID == "" {
		fatal("team set: --window-id is required\nRun 'doey-ctl team set -h' for usage.\n")
	}

	s := openStore(*dir)
	defer s.Close()

	t := &store.Team{
		WindowID:     *windowID,
		Name:         *name,
		Type:         *typ,
		WorktreePath: *worktree,
		PaneCount:    *paneCount,
	}
	if err := s.UpsertTeam(t); err != nil {
		fatal("team set: %v\n", err)
	}
	if jsonOutput {
		printJSON(t)
		return
	}
	fmt.Printf("set team %s\n", *windowID)
}

func teamDelete(args []string) {
	fs := flag.NewFlagSet("team delete", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("team delete: <window-id> argument required\nRun 'doey-ctl team delete -h' for usage.\n")
	}
	windowID := fs.Arg(0)

	s := openStore(*dir)
	defer s.Close()

	if err := s.DeleteTeam(windowID); err != nil {
		fatal("team delete: %v\n", err)
	}
	fmt.Printf("deleted team %s\n", windowID)
}

// --- config subcommand ---

func runConfigCmd(args []string) {
	if len(args) < 1 {
		printConfigHelp()
		fatal("config: missing subcommand: get, set, list, delete\nRun 'doey-ctl config --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printConfigHelp()
		return
	}
	switch args[0] {
	case "get":
		configGet(args[1:])
	case "set":
		configSet(args[1:])
	case "list":
		configList(args[1:])
	case "delete":
		configDelete(args[1:])
	default:
		fatal("config: unknown subcommand: %q. Valid: get, set, list, delete\n", args[0])
	}
}

func printConfigHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl config <subcommand> [flags]

Subcommands:
  get       Get a config value
  set       Set a config value
  list      List all config entries
  delete    Delete a config key

Run 'doey-ctl config <subcommand> -h' for help.
`)
}

func configGet(args []string) {
	fs := flag.NewFlagSet("config get", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("config get: <key> argument required\nRun 'doey-ctl config get -h' for usage.\n")
	}
	key := fs.Arg(0)

	s := openStore(*dir)
	defer s.Close()

	val, err := s.GetConfig(key)
	if err != nil {
		fatal("config get: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"key": key, "value": val})
		return
	}
	fmt.Println(val)
}

func configSet(args []string) {
	fs := flag.NewFlagSet("config set", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	source := fs.String("source", "", "Config source")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 2 {
		fatal("config set: <key> <value> arguments required\nRun 'doey-ctl config set -h' for usage.\n")
	}
	key := fs.Arg(0)
	val := fs.Arg(1)

	s := openStore(*dir)
	defer s.Close()

	if err := s.SetConfig(key, val, *source); err != nil {
		fatal("config set: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "set", "key": key, "value": val})
		return
	}
	fmt.Println("set")
}

func configList(args []string) {
	fs := flag.NewFlagSet("config list", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s := openStore(*dir)
	defer s.Close()

	entries, err := s.ListConfig()
	if err != nil {
		fatal("config list: %v\n", err)
	}
	if jsonOutput {
		printJSON(entries)
		return
	}
	for _, e := range entries {
		fmt.Printf("%-30s %s\n", e.Key, e.Value)
	}
}

func configDelete(args []string) {
	fs := flag.NewFlagSet("config delete", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("config delete: <key> argument required\nRun 'doey-ctl config delete -h' for usage.\n")
	}
	key := fs.Arg(0)

	s := openStore(*dir)
	defer s.Close()

	if err := s.DeleteConfig(key); err != nil {
		fatal("config delete: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "deleted", "key": key})
		return
	}
	fmt.Printf("deleted %s\n", key)
}

// --- agent subcommand ---

func runAgentCmd(args []string) {
	if len(args) < 1 {
		printAgentHelp()
		fatal("agent: missing subcommand: list, get, set, delete\nRun 'doey-ctl agent --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printAgentHelp()
		return
	}
	switch args[0] {
	case "list":
		agentList(args[1:])
	case "get":
		agentGet(args[1:])
	case "set":
		agentSet(args[1:])
	case "delete":
		agentDelete(args[1:])
	default:
		fatal("agent: unknown subcommand: %q. Valid: list, get, set, delete\n", args[0])
	}
}

func printAgentHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl agent <subcommand> [flags]

Subcommands:
  list      List agents
  get       Show agent details
  set       Create or update an agent
  delete    Delete an agent

Run 'doey-ctl agent <subcommand> -h' for help.
`)
}

func agentList(args []string) {
	fs := flag.NewFlagSet("agent list", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s := openStore(*dir)
	defer s.Close()

	agents, err := s.ListAgents()
	if err != nil {
		fatal("agent list: %v\n", err)
	}
	if jsonOutput {
		printJSON(agents)
		return
	}
	for _, a := range agents {
		fmt.Printf("%-20s %-20s %s\n", a.Name, a.DisplayName, a.Model)
	}
}

func agentGet(args []string) {
	fs := flag.NewFlagSet("agent get", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("agent get: <name> argument required\nRun 'doey-ctl agent get -h' for usage.\n")
	}
	name := fs.Arg(0)

	s := openStore(*dir)
	defer s.Close()

	a, err := s.GetAgent(name)
	if err != nil {
		fatal("agent get: %v\n", err)
	}
	if jsonOutput {
		printJSON(a)
		return
	}
	fmt.Printf("name=%s display=%s model=%s\n%s\n", a.Name, a.DisplayName, a.Model, a.Description)
}

func agentSet(args []string) {
	fs := flag.NewFlagSet("agent set", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	name := fs.String("name", "", "Agent name")
	displayName := fs.String("display-name", "", "Display name")
	model := fs.String("model", "", "Model")
	description := fs.String("description", "", "Description")
	color := fs.String("color", "", "Color")
	memory := fs.String("memory", "", "Memory")
	filePath := fs.String("file-path", "", "File path")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *name == "" {
		fatal("agent set: --name is required\nRun 'doey-ctl agent set -h' for usage.\n")
	}

	s := openStore(*dir)
	defer s.Close()

	a := &store.Agent{
		Name:        *name,
		DisplayName: *displayName,
		Model:       *model,
		Description: *description,
		Color:       *color,
		Memory:      *memory,
		FilePath:    *filePath,
	}
	if err := s.UpsertAgent(a); err != nil {
		fatal("agent set: %v\n", err)
	}
	if jsonOutput {
		printJSON(a)
		return
	}
	fmt.Printf("set agent %s\n", *name)
}

func agentDelete(args []string) {
	fs := flag.NewFlagSet("agent delete", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("agent delete: <name> argument required\nRun 'doey-ctl agent delete -h' for usage.\n")
	}
	name := fs.Arg(0)

	s := openStore(*dir)
	defer s.Close()

	if err := s.DeleteAgent(name); err != nil {
		fatal("agent delete: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "deleted", "name": name})
		return
	}
	fmt.Printf("deleted agent %s\n", name)
}

// --- event subcommand ---

func runEventCmd(args []string) {
	if len(args) < 1 {
		printEventHelp()
		fatal("event: missing subcommand: log, list\nRun 'doey-ctl event --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printEventHelp()
		return
	}
	switch args[0] {
	case "log":
		eventLog(args[1:])
	case "list":
		eventList(args[1:])
	default:
		fatal("event: unknown subcommand: %q. Valid: log, list\n", args[0])
	}
}

func printEventHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl event <subcommand> [flags]

Subcommands:
  log       Log an event
  list      List events

Run 'doey-ctl event <subcommand> -h' for help.
`)
}

func eventLog(args []string) {
	fs := flag.NewFlagSet("event log", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	typ := fs.String("type", "", "Event type")
	source := fs.String("source", "", "Event source")
	target := fs.String("target", "", "Event target")
	taskID := fs.Int64("task-id", 0, "Associated task ID")
	data := fs.String("data", "", "Event data (JSON)")
	message := fs.String("message", "", "Event message (alias for --data)")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *typ == "" {
		fatal("event log: --type is required\nRun 'doey-ctl event log -h' for usage.\n")
	}

	// --message is an alias for --data
	if *data == "" && *message != "" {
		*data = *message
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)
	if s == nil {
		// No DB yet (fresh install) — silently succeed
		if jsonOutput {
			printJSON(map[string]string{"status": "skipped", "reason": "no database"})
		}
		return
	}
	defer s.Close()

	e := &store.Event{
		Type:   *typ,
		Source: *source,
		Target: *target,
		Data:   *data,
	}
	if *taskID != 0 {
		e.TaskID = taskID
	}
	id, err := s.LogEvent(e)
	if err != nil {
		fatal("event log: %v\n", err)
	}
	if jsonOutput {
		printJSON(e)
		return
	}
	fmt.Printf("logged event %d\n", id)
}

func eventList(args []string) {
	fs := flag.NewFlagSet("event list", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	typ := fs.String("type", "", "Filter by event type")
	limit := fs.Int("limit", 50, "Max events to return")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s := openStore(*dir)
	defer s.Close()

	events, err := s.ListEvents(*typ, *limit)
	if err != nil {
		fatal("event list: %v\n", err)
	}
	if jsonOutput {
		printJSON(events)
		return
	}
	for _, e := range events {
		fmt.Printf("%-6d %-15s %-10s → %-10s %s\n", e.ID, e.Type, e.Source, e.Target, e.Data)
	}
}

// --- error subcommand ---

func runErrorCmd(args []string) {
	// Default to "list" when no subcommand given
	if len(args) < 1 || args[0] == "list" {
		if len(args) > 0 {
			args = args[1:]
		}
		errorList(args)
		return
	}
	if isHelp(args[0]) {
		printErrorHelp()
		return
	}
	fatal("error: unknown subcommand: %q. Valid: list\n", args[0])
}

func printErrorHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl error [list] [flags]

Subcommands:
  list      List error events (default)

Flags:
  --type      Filter by error subtype (e.g. "hook_block" queries "error_hook_block")
  --source    Filter by source pane
  --task-id   Filter by task ID
  --limit     Max results (default 50)
  --json      JSON output

Run 'doey-ctl error list -h' for help.
`)
}

func errorList(args []string) {
	fs := flag.NewFlagSet("error list", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	typ := fs.String("type", "", "Filter by error subtype (e.g. hook_block)")
	source := fs.String("source", "", "Filter by source pane")
	taskID := fs.Int64("task-id", 0, "Filter by task ID")
	limit := fs.Int("limit", 50, "Max errors to return")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s := openStore(*dir)
	defer s.Close()

	// Prepend "error_" prefix if user supplied a subtype
	errorType := ""
	if *typ != "" {
		errorType = "error_" + *typ
	}

	events, err := s.ListErrorEvents(errorType, *source, *taskID, *limit)
	if err != nil {
		fatal("error list: %v\n", err)
	}
	if jsonOutput {
		printJSON(events)
		return
	}
	if len(events) == 0 {
		fmt.Println("No errors found.")
		return
	}
	for _, e := range events {
		ts := time.Unix(e.CreatedAt, 0).Format("15:04:05")
		taskStr := ""
		if e.TaskID != nil {
			taskStr = fmt.Sprintf("%d", *e.TaskID)
		}
		fmt.Printf("%-6d %-20s %-14s %-6s %-8s %s\n", e.ID, e.Type, e.Source, taskStr, ts, e.Data)
	}
}

// --- migrate subcommand ---

func runMigrateCmd(args []string) {
	fs := flag.NewFlagSet("migrate", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	rt := fs.String("runtime", "", "Runtime directory (optional)")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	pd := projectDir(*dir)
	s := openStore(*dir)
	defer s.Close()

	rtDir := ""
	if *rt != "" {
		rtDir = *rt
	} else if v := os.Getenv("DOEY_RUNTIME"); v != "" {
		rtDir = v
	}

	result, err := s.Migrate(pd, rtDir)
	if err != nil {
		fatal("migrate: %v\n", err)
	}

	if jsonOutput {
		printJSON(result)
		return
	}

	fmt.Printf("Migrated: %d tasks, %d plans, %d agents, %d statuses, %d messages, %d config\n",
		result.Tasks, result.Plans, result.Agents, result.Statuses, result.Messages, result.Config)
	if len(result.Errors) > 0 {
		fmt.Printf("Errors (%d):\n", len(result.Errors))
		for _, e := range result.Errors {
			fmt.Printf("  - %s\n", e)
		}
	}
}

// --- briefing subcommand ---

func runBriefingCmd(args []string) {
	fs := flag.NewFlagSet("briefing", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	pd := projectDir(*dir)
	s := tryOpenStore(pd)
	if s == nil {
		fmt.Fprintln(os.Stderr, "briefing: no database found")
		return
	}
	defer s.Close()

	briefingActiveTasks(s)
	fmt.Println()
	briefingWorkerGrid()
	fmt.Println()
	briefingRecentActivity(s)
}

func briefingActiveTasks(s *store.Store) {
	fmt.Println("=== Active Tasks ===")

	tasks, err := s.ListTasks("")
	if err != nil {
		fmt.Fprintf(os.Stderr, "  error: %v\n", err)
		return
	}

	count := 0
	for _, t := range tasks {
		if t.Status != "active" && t.Status != "in_progress" {
			continue
		}
		subs, _ := s.ListSubtasks(t.ID)
		done := 0
		for _, st := range subs {
			if st.Status == "done" {
				done++
			}
		}
		team := ""
		if t.Team != "" {
			team = fmt.Sprintf(" (team:%s)", t.Team)
		}
		subtaskInfo := ""
		if len(subs) > 0 {
			subtaskInfo = fmt.Sprintf(" — %d/%d subtasks done", done, len(subs))
		}
		fmt.Printf("#%d [%s] %s%s%s\n", t.ID, t.Status, t.Title, team, subtaskInfo)
		count++
	}
	if count == 0 {
		fmt.Println("  (none)")
	}
}

func briefingWorkerGrid() {
	fmt.Println("=== Worker Grid ===")

	runtimeDir := os.Getenv("DOEY_RUNTIME")
	if runtimeDir == "" {
		fmt.Println("  (DOEY_RUNTIME not set)")
		return
	}
	statusDir := filepath.Join(runtimeDir, "status")
	entries, err := os.ReadDir(statusDir)
	if err != nil {
		fmt.Println("  (no status directory)")
		return
	}

	// Parse status files: filename is {session}_{W}_{P}.status
	type paneInfo struct {
		window int
		pane   int
		status string
	}
	var panes []paneInfo
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".status") {
			continue
		}
		name := strings.TrimSuffix(e.Name(), ".status")
		// Extract last two underscore-separated parts as window and pane
		parts := strings.Split(name, "_")
		if len(parts) < 2 {
			continue
		}
		wStr := parts[len(parts)-2]
		pStr := parts[len(parts)-1]
		var w, p int
		if _, err := fmt.Sscanf(wStr, "%d", &w); err != nil {
			continue
		}
		if _, err := fmt.Sscanf(pStr, "%d", &p); err != nil {
			continue
		}
		// Skip window 0 (dashboard) and window 1 (core team) and pane 0 (managers)
		if w <= 1 || p == 0 {
			continue
		}

		status := readStatusFromFile(filepath.Join(statusDir, e.Name()))
		panes = append(panes, paneInfo{window: w, pane: p, status: status})
	}

	// Group by window
	windows := make(map[int][]paneInfo)
	for _, pi := range panes {
		windows[pi.window] = append(windows[pi.window], pi)
	}
	winKeys := make([]int, 0, len(windows))
	for k := range windows {
		winKeys = append(winKeys, k)
	}
	sort.Ints(winKeys)

	if len(winKeys) == 0 {
		fmt.Println("  (no workers)")
		return
	}

	for _, w := range winKeys {
		wPanes := windows[w]
		sort.Slice(wPanes, func(i, j int) bool { return wPanes[i].pane < wPanes[j].pane })

		// Count statuses
		counts := make(map[string]int)
		for _, pi := range wPanes {
			counts[pi.status]++
		}
		var summary []string
		for _, s := range []string{"BUSY", "READY", "FINISHED", "ERROR", "RESERVED"} {
			if c := counts[s]; c > 0 {
				summary = append(summary, fmt.Sprintf("%s:%d", s, c))
			}
		}
		fmt.Printf("Window %d: %s\n", w, strings.Join(summary, " "))

		// Pane detail line
		var paneStrs []string
		for _, pi := range wPanes {
			paneStrs = append(paneStrs, fmt.Sprintf("%d.%d %s", pi.window, pi.pane, pi.status))
		}
		fmt.Printf("  %s\n", strings.Join(paneStrs, "  "))
	}
}

func readStatusFromFile(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return "UNKNOWN"
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "STATUS: ") {
			return strings.TrimPrefix(line, "STATUS: ")
		}
	}
	return "UNKNOWN"
}

func briefingRecentActivity(s *store.Store) {
	fmt.Println("=== Recent Activity (last 10) ===")

	events, err := s.ListEvents("", 10)
	if err != nil {
		fmt.Fprintf(os.Stderr, "  error: %v\n", err)
		return
	}
	if len(events) == 0 {
		fmt.Println("  (none)")
		return
	}

	for _, ev := range events {
		ts := time.Unix(ev.CreatedAt, 0).Format("2006-01-02 15:04")
		taskRef := ""
		if ev.TaskID != nil {
			taskRef = fmt.Sprintf("Task #%d", *ev.TaskID)
		}
		source := ev.Source
		data := ev.Data
		if len(data) > 60 {
			data = data[:57] + "..."
		}
		fmt.Printf("%s  %-10s  %-12s  %s: %s\n", ts, taskRef, ev.Type, source, data)
	}
}
