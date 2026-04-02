package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/ctl"
	"github.com/doey-cli/doey/tui/internal/store"
)

// tryOpenStore opens the project's SQLite store if .doey/doey.db exists.
// Returns nil if the DB file is absent (file-only mode).
func tryOpenStore(dir string) *store.Store {
	dbPath := filepath.Join(dir, ".doey", "doey.db")
	if _, err := os.Stat(dbPath); err != nil {
		return nil
	}
	s, err := store.Open(dbPath)
	if err != nil {
		return nil
	}
	return s
}

// runTaskCmd dispatches task sub-subcommands.
func runTaskCmd(args []string) {
	if len(args) == 0 {
		fatal("task: missing subcommand (create, update, list, get, delete, subtask, log, decision)")
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
	case "delete":
		runTaskDelete(args[1:])
	case "subtask":
		runTaskSubtask(args[1:])
	case "log":
		runTaskLog(args[1:])
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
	team := fs.String("team", "", "team name (DB mode)")
	planID := fs.Int64("plan-id", 0, "plan ID (DB mode)")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if *title == "" {
		fatal("task create: --title is required")
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
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

		dbID, err := s.CreateTask(t)
		if err != nil {
			fatal("task create: %v", err)
		}

		// Write-through: also create .task file for hook compatibility.
		fileID, _ := ctl.CreateTask(pd, *title, *typ, *createdBy, *desc)
		// Best-effort: if file write fails, DB is still authoritative.
		_ = fileID

		if jsonOutput {
			printJSON(map[string]int64{"id": dbID})
		} else {
			fmt.Println(dbID)
		}
		return
	}

	// File-only fallback.
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
	taskIDStr := fs.Arg(0)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		id, err := strconv.ParseInt(taskIDStr, 10, 64)
		if err == nil {
			t, err := s.GetTask(id)
			if err == nil {
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
						fatal("task update: invalid integer for current_phase: %q", *value)
					}
					t.CurrentPhase = n
				case "total_phases":
					n, err := strconv.Atoi(*value)
					if err != nil {
						fatal("task update: invalid integer for total_phases: %q", *value)
					}
					t.TotalPhases = n
				default:
					fatal("task update: unknown DB field %q", *field)
				}

				if err := s.UpdateTask(t); err != nil {
					fatal("task update: %v", err)
				}

				// Write-through to .task file (best-effort).
				_ = ctl.UpdateTaskField(pd, taskIDStr, *field, *value)
				return
			}
		}
	}

	// File-only fallback.
	if err := ctl.UpdateTaskField(pd, taskIDStr, *field, *value); err != nil {
		fatal("task update: %v", err)
	}
}

func runTaskList(args []string) {
	fs := flag.NewFlagSet("task list", flag.ExitOnError)
	status := fs.String("status", "", "filter by status")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		tasks, err := s.ListTasks(*status)
		if err != nil {
			fatal("task list: %v", err)
		}

		if jsonOutput {
			printJSON(tasks)
			return
		}

		fmt.Printf("%-6s %-14s %-12s %s\n", "ID", "STATUS", "TEAM", "TITLE")
		for _, t := range tasks {
			fmt.Printf("%-6d %-14s %-12s %s\n", t.ID, t.Status, t.Team, t.Title)
		}
		return
	}

	// File-only fallback.
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
	taskIDStr := fs.Arg(0)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		id, err := strconv.ParseInt(taskIDStr, 10, 64)
		if err == nil {
			t, err := s.GetTask(id)
			if err == nil {
				subtasks, _ := s.ListSubtasks(id)
				logEntries, _ := s.ListTaskLog(id)

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
				return
			}
		}
	}

	// File-only fallback.
	t, err := ctl.ReadTask(pd, taskIDStr)
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

func runTaskDelete(args []string) {
	fs := flag.NewFlagSet("task delete", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("task delete: missing task ID")
	}

	pd := projectDir(*dir)
	taskIDStr := fs.Arg(0)
	s := tryOpenStore(pd)

	if s == nil {
		fatal("task delete: requires SQLite store (.doey/doey.db)")
	}
	defer s.Close()

	id, err := strconv.ParseInt(taskIDStr, 10, 64)
	if err != nil {
		fatal("task delete: invalid task ID %q", taskIDStr)
	}

	if err := s.DeleteTask(id); err != nil {
		fatal("task delete: %v", err)
	}

	if jsonOutput {
		printJSON(map[string]string{"status": "deleted"})
	} else {
		fmt.Println("deleted")
	}
}

func runTaskSubtask(args []string) {
	if len(args) == 0 {
		fatal("task subtask: missing subcommand (add, update, list)")
	}
	switch args[0] {
	case "add":
		runSubtaskAdd(args[1:])
	case "update":
		runSubtaskUpdate(args[1:])
	case "list":
		runSubtaskList(args[1:])
	default:
		fatal("task subtask: unknown subcommand %q", args[0])
	}
}

func runSubtaskAdd(args []string) {
	fs := flag.NewFlagSet("task subtask add", flag.ExitOnError)
	title := fs.String("title", "", "subtask title (DB mode; positional desc used for file mode)")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("task subtask add: missing task ID")
	}

	pd := projectDir(*dir)
	taskIDStr := fs.Arg(0)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		taskID, err := strconv.ParseInt(taskIDStr, 10, 64)
		if err == nil {
			subtaskTitle := *title
			if subtaskTitle == "" && fs.NArg() >= 2 {
				subtaskTitle = strings.Join(fs.Args()[1:], " ")
			}
			if subtaskTitle == "" {
				fatal("task subtask add: --title or positional description required")
			}

			st := &store.Subtask{
				TaskID: taskID,
				Title:  subtaskTitle,
				Status: "pending",
			}
			id, err := s.CreateSubtask(st)
			if err != nil {
				fatal("task subtask add: %v", err)
			}

			// Write-through to .task file (best-effort).
			_, _ = ctl.AddSubtask(pd, taskIDStr, subtaskTitle)

			if jsonOutput {
				printJSON(map[string]int64{"id": id})
			} else {
				fmt.Println(id)
			}
			return
		}
	}

	// File-only fallback.
	if fs.NArg() < 2 {
		fatal("task subtask add: usage: <task-id> <description>")
	}
	desc := strings.Join(fs.Args()[1:], " ")

	idx, err := ctl.AddSubtask(pd, taskIDStr, desc)
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
	status := fs.String("status", "", "new status (required for DB mode)")
	stTitle := fs.String("title", "", "new title (DB mode)")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("task subtask update: missing ID")
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		// DB mode: first arg is subtask ID.
		subtaskIDStr := fs.Arg(0)
		id, err := strconv.ParseInt(subtaskIDStr, 10, 64)
		if err == nil && *status != "" {
			st := &store.Subtask{
				ID:     id,
				Status: *status,
			}
			if *stTitle != "" {
				st.Title = *stTitle
			}
			if err := s.UpdateSubtask(st); err != nil {
				fatal("task subtask update: %v", err)
			}

			if jsonOutput {
				printJSON(map[string]string{"status": "updated"})
			} else {
				fmt.Println("updated")
			}
			return
		}
	}

	// File-only fallback: <task-id> <index> <status>.
	if fs.NArg() < 3 {
		fatal("task subtask update: usage: <task-id> <index> <status>")
	}

	taskID := fs.Arg(0)
	idx, err := strconv.Atoi(fs.Arg(1))
	if err != nil {
		fatal("task subtask update: invalid index %q", fs.Arg(1))
	}
	fileStatus := fs.Arg(2)

	if err := ctl.UpdateSubtaskStatus(pd, taskID, idx, fileStatus); err != nil {
		fatal("task subtask update: %v", err)
	}
}

func runSubtaskList(args []string) {
	fs := flag.NewFlagSet("task subtask list", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("task subtask list: missing task ID")
	}

	pd := projectDir(*dir)
	taskIDStr := fs.Arg(0)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		taskID, err := strconv.ParseInt(taskIDStr, 10, 64)
		if err == nil {
			subtasks, err := s.ListSubtasks(taskID)
			if err != nil {
				fatal("task subtask list: %v", err)
			}

			if jsonOutput {
				printJSON(subtasks)
				return
			}
			fmt.Printf("%-6s %-4s %-12s %s\n", "ID", "SEQ", "STATUS", "TITLE")
			for _, st := range subtasks {
				fmt.Printf("%-6d %-4d %-12s %s\n", st.ID, st.Seq, st.Status, st.Title)
			}
			return
		}
	}

	// File-only fallback: parse subtasks from .task file.
	t, err := ctl.ReadTask(pd, taskIDStr)
	if err != nil {
		fatal("task subtask list: %v", err)
	}

	if jsonOutput {
		printJSON(t.Subtasks)
		return
	}

	fmt.Printf("%-6s %-12s %s\n", "INDEX", "STATUS", "DESCRIPTION")
	for _, st := range t.Subtasks {
		fmt.Printf("%-6d %-12s %s\n", st.Index, st.Status, st.Description)
	}
}

// runTaskLog dispatches task log sub-subcommands.
func runTaskLog(args []string) {
	if len(args) == 0 {
		fatal("task log: missing subcommand (add, list)")
	}
	switch args[0] {
	case "add":
		runTaskLogAdd(args[1:])
	case "list":
		runTaskLogList(args[1:])
	default:
		fatal("task log: unknown subcommand %q", args[0])
	}
}

func runTaskLogAdd(args []string) {
	fs := flag.NewFlagSet("task log add", flag.ExitOnError)
	logType := fs.String("type", "note", "log entry type")
	author := fs.String("author", "", "author name")
	title := fs.String("title", "", "log entry title")
	body := fs.String("body", "", "log entry body")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("task log add: missing task ID")
	}

	pd := projectDir(*dir)
	taskIDStr := fs.Arg(0)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		taskID, err := strconv.ParseInt(taskIDStr, 10, 64)
		if err == nil {
			entryTitle := *title
			if entryTitle == "" && fs.NArg() >= 2 {
				entryTitle = strings.Join(fs.Args()[1:], " ")
			}
			entry := &store.TaskLogEntry{
				TaskID: taskID,
				Type:   *logType,
				Author: *author,
				Title:  entryTitle,
				Body:   *body,
			}
			id, err := s.AddTaskLog(entry)
			if err != nil {
				fatal("task log add: %v", err)
			}

			// Write-through: append to decision log in .task file (best-effort).
			_ = ctl.AddDecision(pd, taskIDStr, entryTitle)

			if jsonOutput {
				printJSON(map[string]int64{"id": id})
			} else {
				fmt.Println(id)
			}
			return
		}
	}

	// File-only fallback: append to DECISION_LOG.
	text := *title
	if text == "" && fs.NArg() >= 2 {
		text = strings.Join(fs.Args()[1:], " ")
	}
	if text == "" {
		fatal("task log add: --title or positional text required")
	}

	if err := ctl.AddDecision(pd, taskIDStr, text); err != nil {
		fatal("task log add: %v", err)
	}
}

func runTaskLogList(args []string) {
	fs := flag.NewFlagSet("task log list", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("task log list: missing task ID")
	}

	pd := projectDir(*dir)
	taskIDStr := fs.Arg(0)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		taskID, err := strconv.ParseInt(taskIDStr, 10, 64)
		if err == nil {
			entries, err := s.ListTaskLog(taskID)
			if err != nil {
				fatal("task log list: %v", err)
			}

			if jsonOutput {
				printJSON(entries)
				return
			}
			for _, e := range entries {
				ts := time.Unix(e.CreatedAt, 0).Format("15:04:05")
				fmt.Printf("[%d] %s %s (%s): %s\n", e.ID, ts, e.Author, e.Type, e.Title)
				if e.Body != "" {
					fmt.Printf("    %s\n", e.Body)
				}
			}
			return
		}
	}

	// File-only fallback: parse DECISION_LOG from .task file.
	t, err := ctl.ReadTask(pd, taskIDStr)
	if err != nil {
		fatal("task log list: %v", err)
	}

	if jsonOutput {
		printJSON(map[string]string{"decision_log": t.DecisionLog})
		return
	}

	if t.DecisionLog == "" {
		fmt.Println("(no log entries)")
		return
	}
	// Decision log uses literal \n as separator.
	entries := strings.Split(t.DecisionLog, `\n`)
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		if entry != "" {
			fmt.Println(entry)
		}
	}
}

func runTaskDecision(args []string) {
	// Alias for: task log add --type=decision <task-id> <text>
	fs := flag.NewFlagSet("task decision", flag.ExitOnError)
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if fs.NArg() < 2 {
		fatal("task decision: usage: <task-id> <text>")
	}

	taskIDStr := fs.Arg(0)
	text := strings.Join(fs.Args()[1:], " ")

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		taskID, err := strconv.ParseInt(taskIDStr, 10, 64)
		if err == nil {
			entry := &store.TaskLogEntry{
				TaskID: taskID,
				Type:   "decision",
				Title:  text,
			}
			_, err := s.AddTaskLog(entry)
			if err != nil {
				fatal("task decision: %v", err)
			}
			// Write-through to .task file.
			_ = ctl.AddDecision(pd, taskIDStr, text)
			return
		}
	}

	// File-only fallback.
	if err := ctl.AddDecision(pd, taskIDStr, text); err != nil {
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
