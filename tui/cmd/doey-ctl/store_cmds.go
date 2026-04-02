package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/doey-cli/doey/tui/internal/store"
)

// --- plan subcommand ---

func runPlanCmd(args []string) {
	if len(args) < 1 {
		fatal("plan: expected sub-command: list, get, create, update, delete\n")
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
		fatal("plan: unknown sub-command: %s\n", args[0])
	}
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
		fmt.Printf("%-4d %-10s %s\n", p.ID, p.Status, p.Title)
	}
}

func planGet(args []string) {
	fs := flag.NewFlagSet("plan get", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("plan get: <id> argument required\n")
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
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *title == "" {
		fatal("plan create: --title is required\n")
	}

	s := openStore(*dir)
	defer s.Close()

	p := &store.Plan{Title: *title, Status: *status, Body: *body}
	id, err := s.CreatePlan(p)
	if err != nil {
		fatal("plan create: %v\n", err)
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
		fatal("plan update: <id> argument required\n")
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
		fatal("plan delete: <id> argument required\n")
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
		fatal("team: expected sub-command: list, get, set\n")
	}
	switch args[0] {
	case "list":
		teamList(args[1:])
	case "get":
		teamGet(args[1:])
	case "set":
		teamSet(args[1:])
	default:
		fatal("team: unknown sub-command: %s\n", args[0])
	}
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
		fatal("team get: <window-id> argument required\n")
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
		fatal("team set: --window-id is required\n")
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

// --- config subcommand ---

func runConfigCmd(args []string) {
	if len(args) < 1 {
		fatal("config: expected sub-command: get, set, list, delete\n")
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
		fatal("config: unknown sub-command: %s\n", args[0])
	}
}

func configGet(args []string) {
	fs := flag.NewFlagSet("config get", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("config get: <key> argument required\n")
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
		fatal("config set: <key> <value> arguments required\n")
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
		fatal("config delete: <key> argument required\n")
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
		fatal("agent: expected sub-command: list, get, set, delete\n")
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
		fatal("agent: unknown sub-command: %s\n", args[0])
	}
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
		fatal("agent get: <name> argument required\n")
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
	filePath := fs.String("file-path", "", "File path")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *name == "" {
		fatal("agent set: --name is required\n")
	}

	s := openStore(*dir)
	defer s.Close()

	a := &store.Agent{
		Name:        *name,
		DisplayName: *displayName,
		Model:       *model,
		Description: *description,
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
		fatal("agent delete: <name> argument required\n")
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
		fatal("event: expected sub-command: log, list\n")
	}
	switch args[0] {
	case "log":
		eventLog(args[1:])
	case "list":
		eventList(args[1:])
	default:
		fatal("event: unknown sub-command: %s\n", args[0])
	}
}

func eventLog(args []string) {
	fs := flag.NewFlagSet("event log", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	typ := fs.String("type", "", "Event type")
	source := fs.String("source", "", "Event source")
	target := fs.String("target", "", "Event target")
	taskID := fs.Int64("task-id", 0, "Associated task ID")
	data := fs.String("data", "", "Event data (JSON)")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *typ == "" {
		fatal("event log: --type is required\n")
	}

	s := openStore(*dir)
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
