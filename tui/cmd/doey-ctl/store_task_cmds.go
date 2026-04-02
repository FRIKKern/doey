package main

import (
	"flag"
	"fmt"
	"strconv"
	"time"

	"github.com/doey-cli/doey/tui/internal/store"
)

// --- db-task ---

func runDBTaskCmd(args []string) {
	if len(args) == 0 {
		fatal("db-task: missing subcommand (list, get, create, update, delete)\n")
	}
	switch args[0] {
	case "list":
		dbTaskList(args[1:])
	case "get":
		dbTaskGet(args[1:])
	case "create":
		dbTaskCreate(args[1:])
	case "update":
		dbTaskUpdate(args[1:])
	case "delete":
		dbTaskDelete(args[1:])
	default:
		fatal("db-task: unknown subcommand %q\n", args[0])
	}
}

func dbTaskList(args []string) {
	fs := flag.NewFlagSet("db-task list", flag.ExitOnError)
	status := fs.String("status", "", "filter by status")
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s := openStore(*dir)
	defer s.Close()

	tasks, err := s.ListTasks(*status)
	if err != nil {
		fatal("db-task list: %v\n", err)
	}

	if jsonOutput {
		printJSON(tasks)
		return
	}
	fmt.Printf("%-6s %-14s %-12s %s\n", "ID", "STATUS", "TEAM", "TITLE")
	for _, t := range tasks {
		fmt.Printf("%-6d %-14s %-12s %s\n", t.ID, t.Status, t.Team, t.Title)
	}
}

func dbTaskGet(args []string) {
	if len(args) < 1 {
		fatal("db-task get: missing task ID\n")
	}
	idStr := args[0]

	fs := flag.NewFlagSet("db-task get", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args[1:])

	id := int64(atoiOrFatal(idStr, "db-task get"))

	s := openStore(*dir)
	defer s.Close()

	t, err := s.GetTask(id)
	if err != nil {
		fatal("db-task get: %v\n", err)
	}
	subtasks, err := s.ListSubtasks(id)
	if err != nil {
		fatal("db-task get: subtasks: %v\n", err)
	}
	logEntries, err := s.ListTaskLog(id)
	if err != nil {
		fatal("db-task get: log: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]any{
			"task":     t,
			"subtasks": subtasks,
			"log":      logEntries,
		})
		return
	}

	fmt.Printf("ID:          %d\n", t.ID)
	fmt.Printf("Title:       %s\n", t.Title)
	fmt.Printf("Status:      %s\n", t.Status)
	fmt.Printf("Type:        %s\n", t.Type)
	fmt.Printf("CreatedBy:   %s\n", t.CreatedBy)
	fmt.Printf("AssignedTo:  %s\n", t.AssignedTo)
	fmt.Printf("Team:        %s\n", t.Team)
	if t.PlanID != nil {
		fmt.Printf("PlanID:      %d\n", *t.PlanID)
	}
	if t.Description != "" {
		fmt.Printf("Description: %s\n", t.Description)
	}
	fmt.Printf("Phase:       %d/%d\n", t.CurrentPhase, t.TotalPhases)
	fmt.Printf("Created:     %s\n", time.Unix(t.CreatedAt, 0).Format(time.RFC3339))

	if len(subtasks) > 0 {
		fmt.Println("\nSubtasks:")
		for _, st := range subtasks {
			fmt.Printf("  %d. [%s] %s\n", st.Seq, st.Status, st.Title)
		}
	}
	if len(logEntries) > 0 {
		fmt.Println("\nLog:")
		for _, e := range logEntries {
			ts := time.Unix(e.CreatedAt, 0).Format("15:04:05")
			fmt.Printf("  %s %s (%s): %s\n", ts, e.Author, e.Type, e.Title)
		}
	}
}

func dbTaskCreate(args []string) {
	fs := flag.NewFlagSet("db-task create", flag.ExitOnError)
	title := fs.String("title", "", "task title (required)")
	typ := fs.String("type", "task", "task type")
	createdBy := fs.String("created-by", "", "creator name")
	desc := fs.String("description", "", "task description")
	team := fs.String("team", "", "team name")
	planID := fs.Int64("plan-id", 0, "plan ID")
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *title == "" {
		fatal("db-task create: --title is required\n")
	}

	t := &store.Task{
		Title:       *title,
		Status:      "pending",
		Type:        *typ,
		CreatedBy:   *createdBy,
		Description: *desc,
		Team:        *team,
	}
	if *planID != 0 {
		t.PlanID = planID
	}

	s := openStore(*dir)
	defer s.Close()

	id, err := s.CreateTask(t)
	if err != nil {
		fatal("db-task create: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]int64{"id": id})
	} else {
		fmt.Println(id)
	}
}

func dbTaskUpdate(args []string) {
	if len(args) < 1 {
		fatal("db-task update: missing task ID\n")
	}
	idStr := args[0]

	fs := flag.NewFlagSet("db-task update", flag.ExitOnError)
	field := fs.String("field", "", "field to update (required)")
	value := fs.String("value", "", "new value (required)")
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args[1:])

	if *field == "" {
		fatal("db-task update: --field is required\n")
	}

	id := int64(atoiOrFatal(idStr, "db-task update"))

	s := openStore(*dir)
	defer s.Close()

	t, err := s.GetTask(id)
	if err != nil {
		fatal("db-task update: %v\n", err)
	}

	switch *field {
	case "title":
		t.Title = *value
	case "status":
		t.Status = *value
	case "type":
		t.Type = *value
	case "description":
		t.Description = *value
	case "assigned_to":
		t.AssignedTo = *value
	case "team":
		t.Team = *value
	case "tags":
		t.Tags = *value
	case "acceptance_criteria":
		t.AcceptanceCriteria = *value
	case "current_phase":
		n, err := strconv.Atoi(*value)
		if err != nil {
			fatal("db-task update: invalid integer for current_phase: %q\n", *value)
		}
		t.CurrentPhase = n
	case "total_phases":
		n, err := strconv.Atoi(*value)
		if err != nil {
			fatal("db-task update: invalid integer for total_phases: %q\n", *value)
		}
		t.TotalPhases = n
	default:
		fatal("db-task update: unknown field %q\n", *field)
	}

	if err := s.UpdateTask(t); err != nil {
		fatal("db-task update: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]string{"status": "updated"})
	} else {
		fmt.Println("updated")
	}
}

func dbTaskDelete(args []string) {
	if len(args) < 1 {
		fatal("db-task delete: missing task ID\n")
	}
	idStr := args[0]

	fs := flag.NewFlagSet("db-task delete", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args[1:])

	id := int64(atoiOrFatal(idStr, "db-task delete"))

	s := openStore(*dir)
	defer s.Close()

	if err := s.DeleteTask(id); err != nil {
		fatal("db-task delete: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]string{"status": "deleted"})
	} else {
		fmt.Println("deleted")
	}
}

// --- db-subtask ---

func runDBSubtaskCmd(args []string) {
	if len(args) == 0 {
		fatal("db-subtask: missing subcommand (list, add, update)\n")
	}
	switch args[0] {
	case "list":
		dbSubtaskList(args[1:])
	case "add":
		dbSubtaskAdd(args[1:])
	case "update":
		dbSubtaskUpdate(args[1:])
	default:
		fatal("db-subtask: unknown subcommand %q\n", args[0])
	}
}

func dbSubtaskList(args []string) {
	if len(args) < 1 {
		fatal("db-subtask list: missing task ID\n")
	}
	idStr := args[0]

	fs := flag.NewFlagSet("db-subtask list", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args[1:])

	taskID := int64(atoiOrFatal(idStr, "db-subtask list"))

	s := openStore(*dir)
	defer s.Close()

	subtasks, err := s.ListSubtasks(taskID)
	if err != nil {
		fatal("db-subtask list: %v\n", err)
	}

	if jsonOutput {
		printJSON(subtasks)
		return
	}
	fmt.Printf("%-6s %-4s %-12s %s\n", "ID", "SEQ", "STATUS", "TITLE")
	for _, st := range subtasks {
		fmt.Printf("%-6d %-4d %-12s %s\n", st.ID, st.Seq, st.Status, st.Title)
	}
}

func dbSubtaskAdd(args []string) {
	if len(args) < 1 {
		fatal("db-subtask add: missing task ID\n")
	}
	idStr := args[0]

	fs := flag.NewFlagSet("db-subtask add", flag.ExitOnError)
	title := fs.String("title", "", "subtask title (required)")
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args[1:])

	if *title == "" {
		fatal("db-subtask add: --title is required\n")
	}
	taskID := int64(atoiOrFatal(idStr, "db-subtask add"))

	st := &store.Subtask{
		TaskID: taskID,
		Title:  *title,
		Status: "pending",
	}

	s := openStore(*dir)
	defer s.Close()

	id, err := s.CreateSubtask(st)
	if err != nil {
		fatal("db-subtask add: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]int64{"id": id})
	} else {
		fmt.Println(id)
	}
}

func dbSubtaskUpdate(args []string) {
	if len(args) < 1 {
		fatal("db-subtask update: missing subtask ID\n")
	}
	idStr := args[0]

	fs := flag.NewFlagSet("db-subtask update", flag.ExitOnError)
	status := fs.String("status", "", "new status (required)")
	title := fs.String("title", "", "new title")
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args[1:])

	if *status == "" {
		fatal("db-subtask update: --status is required\n")
	}
	id := int64(atoiOrFatal(idStr, "db-subtask update"))

	st := &store.Subtask{
		ID:     id,
		Status: *status,
	}
	if *title != "" {
		st.Title = *title
	}

	s := openStore(*dir)
	defer s.Close()

	if err := s.UpdateSubtask(st); err != nil {
		fatal("db-subtask update: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]string{"status": "updated"})
	} else {
		fmt.Println("updated")
	}
}

// --- db-msg ---

func runDBMsgCmd(args []string) {
	if len(args) == 0 {
		fatal("db-msg: missing subcommand (send, list, read, read-all, count)\n")
	}
	switch args[0] {
	case "send":
		dbMsgSend(args[1:])
	case "list":
		dbMsgList(args[1:])
	case "read":
		dbMsgRead(args[1:])
	case "read-all":
		dbMsgReadAll(args[1:])
	case "count":
		dbMsgCount(args[1:])
	default:
		fatal("db-msg: unknown subcommand %q\n", args[0])
	}
}

func dbMsgSend(args []string) {
	fs := flag.NewFlagSet("db-msg send", flag.ExitOnError)
	from := fs.String("from", "", "sender pane (required)")
	to := fs.String("to", "", "recipient pane (required)")
	subject := fs.String("subject", "", "message subject (required)")
	body := fs.String("body", "", "message body")
	taskID := fs.Int64("task-id", 0, "associated task ID")
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *from == "" || *to == "" || *subject == "" {
		fatal("db-msg send: --from, --to, and --subject are required\n")
	}

	m := &store.Message{
		FromPane: *from,
		ToPane:   *to,
		Subject:  *subject,
		Body:     *body,
	}
	if *taskID != 0 {
		m.TaskID = taskID
	}

	s := openStore(*dir)
	defer s.Close()

	id, err := s.SendMessage(m)
	if err != nil {
		fatal("db-msg send: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]int64{"id": id})
	} else {
		fmt.Println(id)
	}
}

func dbMsgList(args []string) {
	fs := flag.NewFlagSet("db-msg list", flag.ExitOnError)
	to := fs.String("to", "", "recipient pane (required)")
	unread := fs.Bool("unread", false, "only unread messages")
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *to == "" {
		fatal("db-msg list: --to is required\n")
	}

	s := openStore(*dir)
	defer s.Close()

	msgs, err := s.ListMessages(*to, *unread)
	if err != nil {
		fatal("db-msg list: %v\n", err)
	}

	if jsonOutput {
		printJSON(msgs)
		return
	}
	fmt.Printf("%-6s %-12s %-12s %-5s %s\n", "ID", "FROM", "TO", "READ", "SUBJECT")
	for _, m := range msgs {
		read := " "
		if m.Read {
			read = "*"
		}
		fmt.Printf("%-6d %-12s %-12s %-5s %s\n", m.ID, m.FromPane, m.ToPane, read, m.Subject)
	}
}

func dbMsgRead(args []string) {
	if len(args) < 1 {
		fatal("db-msg read: missing message ID\n")
	}
	idStr := args[0]

	fs := flag.NewFlagSet("db-msg read", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args[1:])

	id := int64(atoiOrFatal(idStr, "db-msg read"))

	s := openStore(*dir)
	defer s.Close()

	if err := s.MarkRead(id); err != nil {
		fatal("db-msg read: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]string{"status": "read"})
	} else {
		fmt.Println("read")
	}
}

func dbMsgReadAll(args []string) {
	fs := flag.NewFlagSet("db-msg read-all", flag.ExitOnError)
	to := fs.String("to", "", "recipient pane (required)")
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *to == "" {
		fatal("db-msg read-all: --to is required\n")
	}

	s := openStore(*dir)
	defer s.Close()

	if err := s.MarkAllRead(*to); err != nil {
		fatal("db-msg read-all: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]string{"status": "read-all", "to": *to})
	} else {
		fmt.Println("read-all")
	}
}

func dbMsgCount(args []string) {
	fs := flag.NewFlagSet("db-msg count", flag.ExitOnError)
	to := fs.String("to", "", "recipient pane (required)")
	dir := fs.String("project-dir", "", "project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *to == "" {
		fatal("db-msg count: --to is required\n")
	}

	s := openStore(*dir)
	defer s.Close()

	count, err := s.CountUnread(*to)
	if err != nil {
		fatal("db-msg count: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]int{"unread": count})
	} else {
		fmt.Println(count)
	}
}
