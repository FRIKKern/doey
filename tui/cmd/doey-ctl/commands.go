package main

import (
	"flag"
	"fmt"
	"strconv"
	"strings"

	"github.com/doey-cli/doey/tui/internal/ctl"
)

// runTaskCmd dispatches task sub-subcommands.
func runTaskCmd(args []string) {
	if len(args) == 0 {
		fatal("task: missing subcommand (create, update, list, get, subtask, decision)")
	}
	switch args[0] {
	case "create":
		runTaskCreate(args[1:])
	case "update":
		runTaskUpdate(args[1:])
	case "list":
		runTaskList(args[1:])
	case "get":
		runTaskGet(args[1:])
	case "subtask":
		runTaskSubtask(args[1:])
	case "decision":
		runTaskDecision(args[1:])
	default:
		fatal("task: unknown subcommand %q", args[0])
	}
}

func runTaskCreate(args []string) {
	fs := flag.NewFlagSet("task create", flag.ExitOnError)
	title := fs.String("title", "", "task title (required)")
	typ := fs.String("type", "task", "task type")
	createdBy := fs.String("created-by", "", "creator name")
	desc := fs.String("description", "", "task description")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if *title == "" {
		fatal("task create: --title is required")
	}

	pd := projectDir(*dir)
	id, err := ctl.CreateTask(pd, *title, *typ, *createdBy, *desc)
	if err != nil {
		fatal("task create: %v", err)
	}

	if jsonOutput {
		printJSON(map[string]string{"id": id})
	} else {
		fmt.Println(id)
	}
}

func runTaskUpdate(args []string) {
	fs := flag.NewFlagSet("task update", flag.ExitOnError)
	field := fs.String("field", "", "field name (required)")
	value := fs.String("value", "", "field value (required)")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("task update: missing task ID")
	}
	if *field == "" {
		fatal("task update: --field is required")
	}

	pd := projectDir(*dir)
	if err := ctl.UpdateTaskField(pd, fs.Arg(0), *field, *value); err != nil {
		fatal("task update: %v", err)
	}
}

func runTaskList(args []string) {
	fs := flag.NewFlagSet("task list", flag.ExitOnError)
	status := fs.String("status", "", "filter by status")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	pd := projectDir(*dir)
	tasks, err := ctl.ListTasks(pd)
	if err != nil {
		fatal("task list: %v", err)
	}

	if *status != "" {
		var filtered []ctl.TaskEntry
		for _, t := range tasks {
			if t.Status == *status {
				filtered = append(filtered, t)
			}
		}
		tasks = filtered
	}

	if jsonOutput {
		printJSON(tasks)
		return
	}

	fmt.Printf("%-6s %-14s %s\n", "ID", "STATUS", "TITLE")
	for _, t := range tasks {
		fmt.Printf("%-6s %-14s %s\n", t.ID, t.Status, t.Title)
	}
}

func runTaskGet(args []string) {
	fs := flag.NewFlagSet("task get", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("task get: missing task ID")
	}

	pd := projectDir(*dir)
	t, err := ctl.ReadTask(pd, fs.Arg(0))
	if err != nil {
		fatal("task get: %v", err)
	}

	if jsonOutput {
		printJSON(t)
		return
	}

	fmt.Printf("ID:            %s\n", t.ID)
	fmt.Printf("Title:         %s\n", t.Title)
	fmt.Printf("Status:        %s\n", t.Status)
	fmt.Printf("Type:          %s\n", t.Type)
	fmt.Printf("Schema:        %d\n", t.SchemaVersion)
	fmt.Printf("CreatedBy:     %s\n", t.CreatedBy)
	fmt.Printf("AssignedTo:    %s\n", t.AssignedTo)
	fmt.Printf("Team:          %s\n", t.Team)
	if t.Description != "" {
		fmt.Printf("Description:   %s\n", t.Description)
	}
	if len(t.Subtasks) > 0 {
		fmt.Println("Subtasks:")
		for _, s := range t.Subtasks {
			fmt.Printf("  %d: [%s] %s\n", s.Index, s.Status, s.Description)
		}
	}
	if t.DecisionLog != "" {
		fmt.Printf("DecisionLog:   %s\n", t.DecisionLog)
	}
	if t.Notes != "" {
		fmt.Printf("Notes:         %s\n", t.Notes)
	}
}

func runTaskSubtask(args []string) {
	if len(args) == 0 {
		fatal("task subtask: missing subcommand (add, update)")
	}
	switch args[0] {
	case "add":
		runSubtaskAdd(args[1:])
	case "update":
		runSubtaskUpdate(args[1:])
	default:
		fatal("task subtask: unknown subcommand %q", args[0])
	}
}

func runSubtaskAdd(args []string) {
	fs := flag.NewFlagSet("task subtask add", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 2 {
		fatal("task subtask add: usage: <task-id> <description>")
	}

	pd := projectDir(*dir)
	taskID := fs.Arg(0)
	desc := strings.Join(fs.Args()[1:], " ")

	idx, err := ctl.AddSubtask(pd, taskID, desc)
	if err != nil {
		fatal("task subtask add: %v", err)
	}

	if jsonOutput {
		printJSON(map[string]int{"index": idx})
	} else {
		fmt.Println(idx)
	}
}

func runSubtaskUpdate(args []string) {
	fs := flag.NewFlagSet("task subtask update", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 3 {
		fatal("task subtask update: usage: <task-id> <index> <status>")
	}

	pd := projectDir(*dir)
	taskID := fs.Arg(0)
	idx, err := strconv.Atoi(fs.Arg(1))
	if err != nil {
		fatal("task subtask update: invalid index %q", fs.Arg(1))
	}
	status := fs.Arg(2)

	if err := ctl.UpdateSubtaskStatus(pd, taskID, idx, status); err != nil {
		fatal("task subtask update: %v", err)
	}
}

func runTaskDecision(args []string) {
	fs := flag.NewFlagSet("task decision", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 2 {
		fatal("task decision: usage: <task-id> <text>")
	}

	pd := projectDir(*dir)
	taskID := fs.Arg(0)
	text := strings.Join(fs.Args()[1:], " ")

	if err := ctl.AddDecision(pd, taskID, text); err != nil {
		fatal("task decision: %v", err)
	}
}

// runTmuxCmd dispatches tmux sub-subcommands.
func runTmuxCmd(args []string) {
	if len(args) == 0 {
		fatal("tmux: missing subcommand (panes, send, capture, env)")
	}
	switch args[0] {
	case "panes":
		runTmuxPanes(args[1:])
	case "send":
		runTmuxSend(args[1:])
	case "capture":
		runTmuxCapture(args[1:])
	case "env":
		runTmuxEnv(args[1:])
	default:
		fatal("tmux: unknown subcommand %q", args[0])
	}
}

func runTmuxPanes(args []string) {
	fs := flag.NewFlagSet("tmux panes", flag.ExitOnError)
	session := fs.String("session", "", "tmux session name")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("tmux panes: missing window index")
	}
	winIdx, err := strconv.Atoi(fs.Arg(0))
	if err != nil {
		fatal("tmux panes: invalid window index %q", fs.Arg(0))
	}

	client := ctl.NewTmuxClient(sessionName(*session))
	panes, err := client.ListPanes(winIdx)
	if err != nil {
		fatal("tmux panes: %v", err)
	}

	if jsonOutput {
		printJSON(panes)
		return
	}

	fmt.Printf("%-8s %-6s %-24s %s\n", "ID", "PID", "TITLE", "PANE")
	for _, p := range panes {
		fmt.Printf("%-8s %-6d %-24s %d.%d\n", p.ID, p.PID, p.Title, p.WindowIdx, p.PaneIdx)
	}
}

func runTmuxSend(args []string) {
	fs := flag.NewFlagSet("tmux send", flag.ExitOnError)
	session := fs.String("session", "", "tmux session name")
	fs.Parse(args)

	if fs.NArg() < 2 {
		fatal("tmux send: usage: <pane> <text>")
	}

	pane := fs.Arg(0)
	text := strings.Join(fs.Args()[1:], " ")

	client := ctl.NewTmuxClient(sessionName(*session))
	if err := client.SendKeys(pane, text, "Enter"); err != nil {
		fatal("tmux send: %v", err)
	}
}

func runTmuxCapture(args []string) {
	fs := flag.NewFlagSet("tmux capture", flag.ExitOnError)
	session := fs.String("session", "", "tmux session name")
	lines := fs.Int("lines", 50, "number of lines to capture")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("tmux capture: missing pane ID")
	}

	client := ctl.NewTmuxClient(sessionName(*session))
	out, err := client.CapturePane(fs.Arg(0), *lines)
	if err != nil {
		fatal("tmux capture: %v", err)
	}

	if jsonOutput {
		printJSON(map[string]string{"output": out})
	} else {
		fmt.Println(out)
	}
}

func runTmuxEnv(args []string) {
	fs := flag.NewFlagSet("tmux env", flag.ExitOnError)
	session := fs.String("session", "", "tmux session name")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("tmux env: missing variable name")
	}

	client := ctl.NewTmuxClient(sessionName(*session))
	val, err := client.ShowEnv(fs.Arg(0))
	if err != nil {
		fatal("tmux env: %v", err)
	}

	if jsonOutput {
		printJSON(map[string]string{"name": fs.Arg(0), "value": val})
	} else {
		fmt.Println(val)
	}
}
