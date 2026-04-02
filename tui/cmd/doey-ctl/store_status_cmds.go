package main

import (
	"flag"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/doey-cli/doey/tui/internal/store"
)

// windowFromPaneID extracts the window index from a pane ID string.
// Examples: "1.3" → "1", "doey-doey:2.4" → "2", "0.0" → "0".
// Returns empty string if the format is unrecognized.
func windowFromPaneID(paneID string) string {
	s := paneID
	// Strip session prefix (e.g. "doey-doey:2.4" → "2.4")
	if idx := strings.LastIndex(s, ":"); idx >= 0 {
		s = s[idx+1:]
	}
	// Split on "." and take the window part
	if dot := strings.Index(s, "."); dot > 0 {
		return s[:dot]
	}
	return ""
}

// --- db-status subcommand ---

func runDBStatusCmd(args []string) {
	if len(args) < 1 {
		fatal("db-status: expected sub-command: get, set, list\n")
	}
	switch args[0] {
	case "get":
		dbStatusGet(args[1:])
	case "set":
		dbStatusSet(args[1:])
	case "list":
		dbStatusList(args[1:])
	default:
		fatal("db-status: unknown sub-command: %s\n", args[0])
	}
}

func dbStatusGet(args []string) {
	if len(args) < 1 {
		fatal("db-status get: <pane-id> argument required\n")
	}
	paneID := args[0]

	fs := flag.NewFlagSet("db-status get", flag.ExitOnError)
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args[1:])

	s := openStore(*dir)
	defer s.Close()

	ps, err := s.GetPaneStatus(paneID)
	if err != nil {
		fatal("db-status get: %v\n", err)
	}
	if jsonOutput {
		printJSON(ps)
		return
	}
	fmt.Printf("pane_id=%s window_id=%s role=%s status=%s agent=%s updated_at=%d\n",
		ps.PaneID, ps.WindowID, ps.Role, ps.Status, ps.Agent, ps.UpdatedAt)
}

func dbStatusSet(args []string) {
	fs := flag.NewFlagSet("db-status set", flag.ExitOnError)
	paneID := fs.String("pane-id", "", "Pane ID")
	windowID := fs.String("window-id", "", "Window ID")
	role := fs.String("role", "", "Pane role")
	status := fs.String("status", "", "Pane status")
	taskID := fs.Int64("task-id", 0, "Task ID (0 = none)")
	taskTitle := fs.String("task-title", "", "Task title")
	agent := fs.String("agent", "", "Agent name")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *paneID == "" || *status == "" {
		fatal("db-status set: -pane-id and -status are required\n")
	}

	// Derive window-id from pane-id if not explicitly provided
	if *windowID == "" {
		*windowID = windowFromPaneID(*paneID)
	}

	ps := &store.PaneStatus{
		PaneID:    *paneID,
		WindowID:  *windowID,
		Role:      *role,
		Status:    *status,
		TaskTitle: *taskTitle,
		Agent:     *agent,
	}
	if *taskID != 0 {
		ps.TaskID = taskID
	}

	s := openStore(*dir)
	defer s.Close()

	if err := s.UpsertPaneStatus(ps); err != nil {
		fatal("db-status set: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "written", "pane_id": *paneID})
	} else {
		fmt.Println("written")
	}
}

func dbStatusList(args []string) {
	fs := flag.NewFlagSet("db-status list", flag.ExitOnError)
	windowID := fs.String("window-id", "", "Window ID")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s := openStore(*dir)
	defer s.Close()

	statuses, err := s.ListPaneStatuses(*windowID)
	if err != nil {
		fatal("db-status list: %v\n", err)
	}
	if jsonOutput {
		printJSON(statuses)
		return
	}
	for _, ps := range statuses {
		fmt.Printf("%-12s %-10s %-10s %-30s %d\n",
			ps.PaneID, ps.Role, ps.Status, ps.TaskTitle, ps.UpdatedAt)
	}
}

// --- db-log subcommand ---

func runDBLogCmd(args []string) {
	if len(args) < 1 {
		fatal("db-log: expected sub-command: add, list\n")
	}
	switch args[0] {
	case "add":
		dbLogAdd(args[1:])
	case "list":
		dbLogList(args[1:])
	default:
		fatal("db-log: unknown sub-command: %s\n", args[0])
	}
}

func dbLogAdd(args []string) {
	fs := flag.NewFlagSet("db-log add", flag.ExitOnError)
	taskID := fs.Int64("task-id", 0, "Task ID")
	logType := fs.String("type", "", "Log entry type")
	author := fs.String("author", "", "Author")
	title := fs.String("title", "", "Log title")
	body := fs.String("body", "", "Log body")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *taskID == 0 || *logType == "" {
		fatal("db-log add: --task-id and --type are required\n")
	}

	entry := &store.TaskLogEntry{
		TaskID: *taskID,
		Type:   *logType,
		Author: *author,
		Title:  *title,
		Body:   *body,
	}

	s := openStore(*dir)
	defer s.Close()

	id, err := s.AddTaskLog(entry)
	if err != nil {
		fatal("db-log add: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]any{"id": id, "task_id": *taskID})
	} else {
		fmt.Println(strconv.FormatInt(id, 10))
	}
}

func dbLogList(args []string) {
	fs := flag.NewFlagSet("db-log list", flag.ExitOnError)
	taskID := fs.Int64("task-id", 0, "Task ID")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *taskID == 0 {
		fatal("db-log list: --task-id is required\n")
	}

	s := openStore(*dir)
	defer s.Close()

	entries, err := s.ListTaskLog(*taskID)
	if err != nil {
		fatal("db-log list: %v\n", err)
	}
	if jsonOutput {
		printJSON(entries)
		return
	}
	for _, e := range entries {
		fmt.Printf("[%d] %s by %s: %s\n", e.ID, e.Type, e.Author, e.Title)
		if e.Body != "" {
			fmt.Printf("    %s\n", e.Body)
		}
	}
}

// --- shared store helper ---

func openStore(dir string) *store.Store {
	dbPath := filepath.Join(projectDir(dir), ".doey", "doey.db")
	s, err := store.Open(dbPath)
	if err != nil {
		fatal("open store: %v\n", err)
	}
	return s
}
