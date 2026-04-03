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

// eventSource returns the pane identifier from env, or "cli" as fallback.
func eventSource() string {
	if p := os.Getenv("DOEY_PANE"); p != "" {
		return p
	}
	return "cli"
}

// runTaskCmd dispatches task sub-subcommands.
func runTaskCmd(args []string) {
	if len(args) == 0 {
		fatal("task: missing subcommand: create, update, list, get, delete, subtask, log, decision\nRun 'doey-ctl task -h' for usage.\n")
	}
	if isHelp(args[0]) {
		printTaskHelp()
		return
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
		validTaskSubs := []string{"create", "update", "list", "get", "delete", "subtask", "log", "decision"}
		if suggestion := suggestSubcommand(args[0], validTaskSubs); suggestion != "" {
			fatal("task: unknown subcommand: %s. Did you mean '%s'?\nRun 'doey-ctl task -h' for usage.\n", args[0], suggestion)
		}
		fatal("task: unknown subcommand: %s. Valid: create, update, list, get, delete, subtask, log, decision\nRun 'doey-ctl task -h' for usage.\n", args[0])
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
		s.LogEvent(&store.Event{Type: "task_created", Source: eventSource(), TaskID: &dbID, Data: *title})

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
	fs := flag.NewFlagSet("task update", flag.ContinueOnError)
	field := fs.String("field", "", "field name")
	value := fs.String("value", "", "field value")
	idFlag := fs.String("id", "", "task ID (convenience)")
	statusFlag := fs.String("status", "", "set status (convenience shorthand)")
	dir := fs.String("project-dir", "", "project directory")

	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: doey-ctl task update [flags] [task-id]\n\n")
		fmt.Fprintf(os.Stderr, "Examples:\n")
		fmt.Fprintf(os.Stderr, "  doey-ctl task update -field status -value done 142\n")
		fmt.Fprintf(os.Stderr, "  doey-ctl task update --id 142 --status done    (convenience shorthand)\n\n")
		fmt.Fprintf(os.Stderr, "Flags:\n")
		fs.PrintDefaults()
	}

	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			os.Exit(0)
		}
		suggestTaskUpdateFlag(args)
		os.Exit(1)
	}

	// Resolve task ID: --id flag takes priority over positional arg.
	taskIDStr := *idFlag
	if taskIDStr == "" && fs.NArg() >= 1 {
		taskIDStr = fs.Arg(0)
	}
	if taskIDStr == "" {
		fatal("task update: missing task ID\nTry: doey-ctl task update --id <ID> --status <value>\n")
	}

	// Convenience: --status maps to field=status, value=<status>.
	if *statusFlag != "" {
		if *field != "" && *field != "status" {
			fatal("task update: cannot use --status with -field %q (conflicting)\n", *field)
		}
		*field = "status"
		*value = *statusFlag
	}

	if *field == "" {
		fatal("task update: --field or --status is required\nTry: doey-ctl task update -field status -value done <ID>\n")
	}

	// Auto-strip TASK_ prefix (e.g. TASK_STATUS → status).
	*field = normalizeFieldName(*field)

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		t, resolveErr := resolveTask(s, taskIDStr)
		if resolveErr != nil {
			// Non-numeric input can't fall through to file mode.
			if _, numErr := strconv.ParseInt(taskIDStr, 10, 64); numErr != nil {
				fatal("task update: %v\n", resolveErr)
			}
		}
		if t != nil {
			id := t.ID
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
			case "notes":
				t.Notes = *value
			case "blockers":
				t.Blockers = *value
			case "related_files":
				t.RelatedFiles = *value
			case "hypotheses":
				t.Hypotheses = *value
			case "decision_log":
				t.DecisionLog = *value
			case "result":
				t.Result = *value
			case "files":
				t.Files = *value
			case "commits":
				t.Commits = *value
			case "schema_version":
				n, err := strconv.Atoi(*value)
				if err != nil {
					fatal("task update: invalid integer for schema_version: %q", *value)
				}
				t.SchemaVersion = n
			case "created_by":
				t.CreatedBy = *value
			case "plan_id":
				n, err := strconv.ParseInt(*value, 10, 64)
				if err != nil {
					fatal("task update: invalid integer for plan_id: %q", *value)
				}
				v := int64(n)
				t.PlanID = &v
			case "review_verdict":
				t.ReviewVerdict = *value
			case "review_findings":
				t.ReviewFindings = *value
			case "review_timestamp":
				t.ReviewTimestamp = *value
			default:
				fatal("task update: unknown DB field %q\nValid fields: title, status, type, description, assigned_to, team, tags, acceptance_criteria, current_phase, total_phases, notes, blockers, related_files, hypotheses, decision_log, result, files, commits, schema_version, created_by, plan_id, review_verdict, review_findings, review_timestamp\n", *field)
			}

			if err := s.UpdateTask(t); err != nil {
				fatal("task update: %v", err)
			}
			s.LogEvent(&store.Event{Type: "task_updated", Source: eventSource(), TaskID: &id, Data: *field + "=" + *value})

			// Write-through to .task file (best-effort).
			_ = ctl.UpdateTaskField(pd, strconv.FormatInt(id, 10), *field, *value)
			return
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
	idFlag := fs.String("id", "", "task ID")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	taskIDStr := *idFlag
	if taskIDStr == "" && fs.NArg() > 0 {
		taskIDStr = fs.Arg(0)
	}
	if taskIDStr == "" {
		fatal("task get: missing task ID\nRun 'doey-ctl task get -h' for usage.\n")
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		t, err := resolveTask(s, taskIDStr)
		if err != nil {
			// Fall through to file-only if DB lookup fails for numeric IDs.
			if _, numErr := strconv.ParseInt(taskIDStr, 10, 64); numErr != nil {
				// Non-numeric input: no file fallback possible.
				fatal("task get: %v\n", err)
			}
		}
		if t != nil {
			id := t.ID
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
	idFlag := fs.String("id", "", "task ID")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	taskIDStr := *idFlag
	if taskIDStr == "" && fs.NArg() > 0 {
		taskIDStr = fs.Arg(0)
	}
	if taskIDStr == "" {
		fatal("task delete: missing task ID\nRun 'doey-ctl task delete -h' for usage.\n")
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s == nil {
		fatal("task delete: requires SQLite store (.doey/doey.db)")
	}
	defer s.Close()

	id := resolveTaskID(s, taskIDStr, "task delete")

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
		fatal("task subtask: missing subcommand: add, update, list\nRun 'doey-ctl task subtask -h' for usage.\n")
	}
	if isHelp(args[0]) {
		printTaskSubtaskHelp()
		return
	}
	switch args[0] {
	case "add":
		runSubtaskAdd(args[1:])
	case "update":
		runSubtaskUpdate(args[1:])
	case "list":
		runSubtaskList(args[1:])
	default:
		validSubs := []string{"add", "update", "list"}
		if suggestion := suggestSubcommand(args[0], validSubs); suggestion != "" {
			fatal("task subtask: unknown subcommand: %s. Did you mean '%s'?\nRun 'doey-ctl task subtask -h' for usage.\n", args[0], suggestion)
		}
		fatal("task subtask: unknown subcommand: %s. Valid: add, update, list\nRun 'doey-ctl task subtask -h' for usage.\n", args[0])
	}
}

func runSubtaskAdd(args []string) {
	fs := flag.NewFlagSet("task subtask add", flag.ExitOnError)
	taskIDFlag := fs.String("task-id", "", "task ID")
	title := fs.String("title", "", "subtask title (DB mode; positional desc used for file mode)")
	desc := fs.String("description", "", "description (alias for --title)")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	if *title == "" && *desc != "" {
		*title = *desc
	}

	taskIDStr := *taskIDFlag
	if taskIDStr == "" && fs.NArg() > 0 {
		taskIDStr = fs.Arg(0)
	}
	if taskIDStr == "" {
		fatal("task subtask add: task ID required (positional or --task-id)\nRun 'doey-ctl task subtask add -h' for usage.\n")
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		taskID := resolveTaskID(s, taskIDStr, "task subtask add")

		subtaskTitle := *title
		if subtaskTitle == "" {
			// Positional args: if --task-id was used, all positional args are the description.
			// Otherwise, args after the first (task ID) are the description.
			descStart := 1
			if *taskIDFlag != "" {
				descStart = 0
			}
			if fs.NArg() > descStart {
				subtaskTitle = strings.Join(fs.Args()[descStart:], " ")
			}
		}
		if subtaskTitle == "" {
			fatal("task subtask add: --title or positional description required\nRun 'doey-ctl task subtask add -h' for usage.\n")
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
		s.LogEvent(&store.Event{Type: "subtask_added", Source: eventSource(), TaskID: &taskID, Data: subtaskTitle})

		taskIDNumStr := strconv.FormatInt(taskID, 10)
		// Write-through to .task file (best-effort).
		_, _ = ctl.AddSubtask(pd, taskIDNumStr, subtaskTitle)

		if jsonOutput {
			printJSON(map[string]int64{"id": id})
		} else {
			fmt.Println(id)
		}
		return
	}

	// File-only fallback.
	descStart := 1
	if *taskIDFlag != "" {
		descStart = 0
	}
	fallbackDesc := *title
	if fallbackDesc == "" && fs.NArg() > descStart {
		fallbackDesc = strings.Join(fs.Args()[descStart:], " ")
	}
	if fallbackDesc == "" {
		fatal("task subtask add: usage: <task-id> <description>\nRun 'doey-ctl task subtask add -h' for usage.\n")
	}

	idx, err := ctl.AddSubtask(pd, taskIDStr, fallbackDesc)
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
	statusFlag := fs.String("status", "", "new status")
	stTitle := fs.String("title", "", "new title (DB mode)")
	taskIDFlag := fs.String("task-id", "", "parent task ID")
	subtaskIDFlag := fs.String("subtask-id", "", "subtask seq number or DB ID")
	dir := fs.String("project-dir", "", "project directory")

	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: doey-ctl task subtask update [flags] [task-id] [seq] [status]\n\n")
		fmt.Fprintf(os.Stderr, "Examples:\n")
		fmt.Fprintf(os.Stderr, "  doey-ctl task subtask update --task-id 142 --subtask-id 1 --status done\n")
		fmt.Fprintf(os.Stderr, "  doey-ctl task subtask update 142 1 done    (positional shorthand)\n\n")
		fmt.Fprintf(os.Stderr, "Flags:\n")
		fs.PrintDefaults()
	}

	fs.Parse(args)

	// Resolve task ID and subtask ID from flags or positional args.
	taskIDStr := *taskIDFlag
	subtaskIDStr := *subtaskIDFlag
	statusVal := *statusFlag

	// Positional fallback: <task-id> <seq> [status]
	if taskIDStr == "" && fs.NArg() >= 1 {
		taskIDStr = fs.Arg(0)
	}
	if subtaskIDStr == "" && fs.NArg() >= 2 {
		subtaskIDStr = fs.Arg(1)
	}
	if statusVal == "" && fs.NArg() >= 3 {
		statusVal = fs.Arg(2)
	}

	if taskIDStr == "" {
		fatal("task subtask update: missing task ID\nTry: doey-ctl task subtask update --task-id <TASK> --subtask-id <SEQ> --status <STATUS>\n")
	}
	if subtaskIDStr == "" {
		fatal("task subtask update: missing subtask ID\nTry: doey-ctl task subtask update --task-id %s --subtask-id <SEQ> --status <STATUS>\n", taskIDStr)
	}
	if statusVal == "" && *stTitle == "" {
		fatal("task subtask update: --status or --title is required\nTry: doey-ctl task subtask update --task-id %s --subtask-id %s --status <STATUS>\n", taskIDStr, subtaskIDStr)
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		taskID := resolveTaskID(s, taskIDStr, "task subtask update")

		resolved, err := resolveSubtask(s, taskID, subtaskIDStr)
		if err != nil {
			fatal("task subtask update: %v\n", err)
		}

		if statusVal != "" {
			resolved.Status = statusVal
		}
		if *stTitle != "" {
			resolved.Title = *stTitle
		}
		if err := s.UpdateSubtask(resolved); err != nil {
			fatal("task subtask update: %v", err)
		}
		evData := "seq=" + strconv.Itoa(resolved.Seq)
		if statusVal != "" {
			evData += ",status=" + statusVal
		}
		if *stTitle != "" {
			evData += ",title=" + *stTitle
		}
		s.LogEvent(&store.Event{Type: "subtask_updated", Source: eventSource(), TaskID: &taskID, Data: evData})

		// Write-through to .task file (best-effort).
		if statusVal != "" {
			_ = ctl.UpdateSubtaskStatus(pd, taskIDStr, resolved.Seq, statusVal)
		}

		if jsonOutput {
			printJSON(map[string]string{"status": "updated", "seq": strconv.Itoa(resolved.Seq)})
		} else {
			fmt.Println("updated")
		}
		return
	}

	// File-only fallback: uses seq number (index).
	idx, err := strconv.Atoi(subtaskIDStr)
	if err != nil {
		fatal("task subtask update: invalid seq number %q\n", subtaskIDStr)
	}
	if statusVal == "" {
		fatal("task subtask update: status is required in file mode\n")
	}

	if err := ctl.UpdateSubtaskStatus(pd, taskIDStr, idx, statusVal); err != nil {
		fatal("task subtask update: %v", err)
	}
}

func runSubtaskList(args []string) {
	fs := flag.NewFlagSet("task subtask list", flag.ExitOnError)
	taskIDFlag := fs.String("task-id", "", "task ID")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	taskIDStr := *taskIDFlag
	if taskIDStr == "" && fs.NArg() > 0 {
		taskIDStr = fs.Arg(0)
	}
	if taskIDStr == "" {
		fatal("task subtask list: task ID required (positional or --task-id)\nRun 'doey-ctl task subtask list -h' for usage.\n")
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		resolved, resolveErr := resolveTask(s, taskIDStr)
		if resolveErr != nil {
			if _, numErr := strconv.ParseInt(taskIDStr, 10, 64); numErr != nil {
				fatal("task subtask list: %v\n", resolveErr)
			}
		}
		if resolved != nil {
			taskID := resolved.ID
			subtasks, err := s.ListSubtasks(taskID)
			if err != nil {
				fatal("task subtask list: %v", err)
			}

			if jsonOutput {
				printJSON(subtasks)
				return
			}
			fmt.Printf("%-4s %-12s %-6s %s\n", "SEQ", "STATUS", "DB_ID", "TITLE")
			for _, st := range subtasks {
				fmt.Printf("%-4d %-12s %-6d %s\n", st.Seq, st.Status, st.ID, st.Title)
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
		fatal("task log: missing subcommand: add, list\nRun 'doey-ctl task log -h' for usage.\n")
	}
	if isHelp(args[0]) {
		printTaskLogHelp()
		return
	}
	switch args[0] {
	case "add":
		runTaskLogAdd(args[1:])
	case "list":
		runTaskLogList(args[1:])
	default:
		validSubs := []string{"add", "list"}
		if suggestion := suggestSubcommand(args[0], validSubs); suggestion != "" {
			fatal("task log: unknown subcommand: %s. Did you mean '%s'?\nRun 'doey-ctl task log -h' for usage.\n", args[0], suggestion)
		}
		fatal("task log: unknown subcommand: %s. Valid: add, list\nRun 'doey-ctl task log -h' for usage.\n", args[0])
	}
}

func runTaskLogAdd(args []string) {
	fs := flag.NewFlagSet("task log add", flag.ExitOnError)
	taskIDFlag := fs.String("task-id", "", "task ID")
	logType := fs.String("type", "note", "log entry type")
	author := fs.String("author", "", "author name")
	title := fs.String("title", "", "log entry title")
	body := fs.String("body", "", "log entry body")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	taskIDStr := *taskIDFlag
	if taskIDStr == "" && fs.NArg() > 0 {
		taskIDStr = fs.Arg(0)
	}
	if taskIDStr == "" {
		fatal("task log add: task ID required (positional or --task-id)\nRun 'doey-ctl task log add -h' for usage.\n")
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		resolved, resolveErr := resolveTask(s, taskIDStr)
		if resolveErr != nil {
			if _, numErr := strconv.ParseInt(taskIDStr, 10, 64); numErr != nil {
				fatal("task log add: %v\n", resolveErr)
			}
		}
		if resolved != nil {
			taskID := resolved.ID
			entryTitle := *title
			titleStart := 1
			if *taskIDFlag != "" {
				titleStart = 0
			}
			if entryTitle == "" && fs.NArg() > titleStart {
				entryTitle = strings.Join(fs.Args()[titleStart:], " ")
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

			taskIDNumStr := strconv.FormatInt(taskID, 10)
			// Write-through: append to decision log in .task file (best-effort).
			_ = ctl.AddDecision(pd, taskIDNumStr, entryTitle)

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
	textStart := 1
	if *taskIDFlag != "" {
		textStart = 0
	}
	if text == "" && fs.NArg() > textStart {
		text = strings.Join(fs.Args()[textStart:], " ")
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
	taskIDFlag := fs.String("task-id", "", "task ID")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	taskIDStr := *taskIDFlag
	if taskIDStr == "" && fs.NArg() > 0 {
		taskIDStr = fs.Arg(0)
	}
	if taskIDStr == "" {
		fatal("task log list: task ID required (positional or --task-id)\nRun 'doey-ctl task log list -h' for usage.\n")
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		resolved, resolveErr := resolveTask(s, taskIDStr)
		if resolveErr != nil {
			if _, numErr := strconv.ParseInt(taskIDStr, 10, 64); numErr != nil {
				fatal("task log list: %v\n", resolveErr)
			}
		}
		if resolved != nil {
			taskID := resolved.ID
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
	taskIDFlag := fs.String("task-id", "", "task ID")
	titleFlag := fs.String("title", "", "decision title")
	bodyFlag := fs.String("body", "", "decision body")
	dir := fs.String("project-dir", "", "project directory")
	fs.Parse(args)

	taskIDStr := *taskIDFlag
	if taskIDStr == "" && fs.NArg() > 0 {
		taskIDStr = fs.Arg(0)
	}
	if taskIDStr == "" {
		fatal("task decision: task ID required (positional or --task-id)\nRun 'doey-ctl task decision -h' for usage.\n")
	}

	// Build decision text from --title/--body flags or positional args.
	text := *titleFlag
	if *bodyFlag != "" {
		if text != "" {
			text = text + ": " + *bodyFlag
		} else {
			text = *bodyFlag
		}
	}
	if text == "" {
		textStart := 1
		if *taskIDFlag != "" {
			textStart = 0
		}
		if fs.NArg() > textStart {
			text = strings.Join(fs.Args()[textStart:], " ")
		}
	}
	if text == "" {
		fatal("task decision: decision text required (--title/--body or positional)\nRun 'doey-ctl task decision -h' for usage.\n")
	}

	pd := projectDir(*dir)
	s := tryOpenStore(pd)

	if s != nil {
		defer s.Close()
		resolved, resolveErr := resolveTask(s, taskIDStr)
		if resolveErr != nil {
			if _, numErr := strconv.ParseInt(taskIDStr, 10, 64); numErr != nil {
				fatal("task decision: %v\n", resolveErr)
			}
		}
		if resolved != nil {
			taskID := resolved.ID
			entry := &store.TaskLogEntry{
				TaskID: taskID,
				Type:   "decision",
				Title:  text,
			}
			_, err := s.AddTaskLog(entry)
			if err != nil {
				fatal("task decision: %v", err)
			}
			taskIDNumStr := strconv.FormatInt(taskID, 10)
			// Write-through to .task file.
			_ = ctl.AddDecision(pd, taskIDNumStr, text)
			return
		}
	}

	// File-only fallback.
	if err := ctl.AddDecision(pd, taskIDStr, text); err != nil {
		fatal("task decision: %v", err)
	}
}

// suggestSubcommand returns the closest valid subcommand if within edit distance 3.
func suggestSubcommand(input string, valid []string) string {
	best, bestDist := "", 999
	for _, v := range valid {
		if d := editDistance(input, v); d < bestDist {
			bestDist = d
			best = v
		}
	}
	if bestDist <= 3 {
		return best
	}
	return ""
}

// normalizeFieldName strips TASK_ prefix and lowercases the field name.
func normalizeFieldName(field string) string {
	upper := strings.ToUpper(field)
	if strings.HasPrefix(upper, "TASK_") {
		field = field[5:]
	}
	return strings.ToLower(field)
}

// suggestTaskUpdateFlag scans raw args for unknown flags and suggests corrections.
func suggestTaskUpdateFlag(args []string) {
	known := []string{"field", "value", "id", "status", "project-dir"}
	for _, arg := range args {
		if !strings.HasPrefix(arg, "-") {
			continue
		}
		name := strings.TrimLeft(arg, "-")
		if idx := strings.Index(name, "="); idx >= 0 {
			name = name[:idx]
		}
		if name == "" {
			continue
		}
		isKnown := false
		for _, k := range known {
			if name == k {
				isKnown = true
				break
			}
		}
		if !isKnown {
			best, bestDist := "", 999
			for _, k := range known {
				if d := editDistance(name, k); d < bestDist {
					bestDist = d
					best = k
				}
			}
			if bestDist <= 3 && best != "" {
				fmt.Fprintf(os.Stderr, "doey-ctl: unknown flag '--%s'. Did you mean '--%s'?\n", name, best)
			}
		}
	}
	fmt.Fprintf(os.Stderr, "Try: doey-ctl task update -field status -value done <ID>\n")
}

// editDistance computes Levenshtein distance between two strings.
func editDistance(a, b string) int {
	la, lb := len(a), len(b)
	if la == 0 {
		return lb
	}
	if lb == 0 {
		return la
	}
	prev := make([]int, lb+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= la; i++ {
		curr := make([]int, lb+1)
		curr[0] = i
		for j := 1; j <= lb; j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			del := prev[j] + 1
			ins := curr[j-1] + 1
			sub := prev[j-1] + cost
			min := del
			if ins < min {
				min = ins
			}
			if sub < min {
				min = sub
			}
			curr[j] = min
		}
		prev = curr
	}
	return prev[lb]
}

// resolveTask looks up a task by DB ID or title substring.
// Returns the task, or nil with a helpful error including suggestions.
func resolveTask(s *store.Store, input string) (*store.Task, error) {
	// Try as DB ID first.
	if id, err := strconv.ParseInt(input, 10, 64); err == nil {
		if t, err := s.GetTask(id); err == nil {
			return t, nil
		}
	}

	// Try case-insensitive title substring match.
	tasks, err := s.ListTasks("")
	if err != nil {
		return nil, fmt.Errorf("failed to list tasks: %v", err)
	}
	lower := strings.ToLower(input)
	var matches []store.Task
	for _, t := range tasks {
		if strings.Contains(strings.ToLower(t.Title), lower) {
			matches = append(matches, t)
		}
	}
	if len(matches) == 1 {
		return &matches[0], nil
	}
	if len(matches) > 1 {
		hint := fmt.Sprintf("multiple tasks match %q:\n", input)
		for _, t := range matches {
			hint += fmt.Sprintf("  #%d [%s] %s\n", t.ID, t.Status, t.Title)
		}
		hint += "Specify a unique ID or more specific title substring."
		return nil, fmt.Errorf("%s", hint)
	}

	return nil, fmt.Errorf("task %q not found\n%s", input, suggestTasks(s))
}

// resolveSubtask looks up a subtask by DB ID, seq number, or title substring.
func resolveSubtask(s *store.Store, taskID int64, input string) (*store.Subtask, error) {
	// Try as integer: first seq, then DB ID.
	if num, err := strconv.ParseInt(input, 10, 64); err == nil {
		if st, err := s.GetSubtaskBySeq(taskID, int(num)); err == nil {
			return st, nil
		}
		if st, err := s.GetSubtaskByID(num); err == nil && st.TaskID == taskID {
			return st, nil
		}
	}

	// Try case-insensitive title substring match.
	subtasks, err := s.ListSubtasks(taskID)
	if err != nil {
		return nil, fmt.Errorf("failed to list subtasks: %v", err)
	}
	lower := strings.ToLower(input)
	var matches []store.Subtask
	for _, st := range subtasks {
		if strings.Contains(strings.ToLower(st.Title), lower) {
			matches = append(matches, st)
		}
	}
	if len(matches) == 1 {
		return &matches[0], nil
	}
	if len(matches) > 1 {
		hint := fmt.Sprintf("multiple subtasks match %q:\n", input)
		for _, st := range matches {
			hint += fmt.Sprintf("  #%d (seq %d) [%s] %s\n", st.ID, st.Seq, st.Status, st.Title)
		}
		hint += "Specify a unique seq number or more specific title substring."
		return nil, fmt.Errorf("%s", hint)
	}

	return nil, fmt.Errorf("subtask %q not found for task #%d\n%s", input, taskID, suggestSubtasks(s, taskID))
}

// suggestTasks returns a formatted list of recent tasks for error messages.
func suggestTasks(s *store.Store) string {
	tasks, err := s.ListTasks("")
	if err != nil || len(tasks) == 0 {
		return "No tasks found. Create one with: doey task create --title \"...\""
	}
	limit := 10
	if len(tasks) < limit {
		limit = len(tasks)
	}
	var b strings.Builder
	b.WriteString("Recent tasks:\n")
	for _, t := range tasks[:limit] {
		fmt.Fprintf(&b, "  #%-6d [%-10s] %s\n", t.ID, t.Status, t.Title)
	}
	if len(tasks) > limit {
		fmt.Fprintf(&b, "  ... and %d more\n", len(tasks)-limit)
	}
	return b.String()
}

// suggestSubtasks returns a formatted list of subtasks for a task.
func suggestSubtasks(s *store.Store, taskID int64) string {
	subtasks, err := s.ListSubtasks(taskID)
	if err != nil || len(subtasks) == 0 {
		return fmt.Sprintf("Task #%d has no subtasks.", taskID)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Available subtasks for task #%d:\n", taskID)
	for _, st := range subtasks {
		fmt.Fprintf(&b, "  #%-6d (seq %d) [%-10s] %s\n", st.ID, st.Seq, st.Status, st.Title)
	}
	fmt.Fprintf(&b, "\nTry: doey task subtask update --task-id %d --subtask-id <SEQ>", taskID)
	return b.String()
}

// resolveTaskID parses a task ID string via resolveTask and returns the int64 ID.
// On failure, fatals with helpful suggestions.
func resolveTaskID(s *store.Store, input, cmdName string) int64 {
	t, err := resolveTask(s, input)
	if err != nil {
		fatal("%s: %v\n", cmdName, err)
	}
	return t.ID
}

// runNudgeCmd sends Escape + re-prompt to unstick Claude instances.
func runNudgeCmd(args []string) {
	fs := flag.NewFlagSet("nudge", flag.ExitOnError)
	all := fs.Bool("all", false, "nudge all stuck panes (skips READY and RESERVED)")
	cascade := fs.Bool("cascade", false, "after nudging target, also nudge Subtaskmaster (W.0) and Taskmaster")
	session := fs.String("session", "", "tmux session name")
	rt := fs.String("runtime", "", "runtime directory")
	prompt := fs.String("prompt", "Check your messages and resume.", "re-prompt text")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")

	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: doey-ctl nudge [flags] [pane]\n\n")
		fmt.Fprintf(os.Stderr, "Examples:\n")
		fmt.Fprintf(os.Stderr, "  doey-ctl nudge doey-doey:3.1    Nudge a single pane\n")
		fmt.Fprintf(os.Stderr, "  doey-ctl nudge 3.1              Nudge pane (uses session from env)\n")
		fmt.Fprintf(os.Stderr, "  doey-ctl nudge --cascade 3.1    Nudge pane, then Subtaskmaster, then Taskmaster\n")
		fmt.Fprintf(os.Stderr, "  doey-ctl nudge --all            Nudge all stuck panes\n\n")
		fmt.Fprintf(os.Stderr, "Flags:\n")
		fs.PrintDefaults()
	}

	fs.Parse(args)

	sess := sessionName(*session)
	client := ctl.NewTmuxClient(sess)
	rtDir := runtimeDirOpt(*rt)

	if *all {
		nudgeAll(client, runtimeDir(*rt), *prompt)
		return
	}

	if fs.NArg() < 1 {
		fatal("nudge: missing pane target\nTry: doey-ctl nudge <pane> or doey-ctl nudge --all\n")
	}

	pane := resolvePane(fs.Arg(0))

	nudgePaneStateAware(client, sess, rtDir, pane, *prompt, true)

	if *cascade {
		// Nudge the Subtaskmaster (pane 0 of the target's window)
		win := pane[:strings.Index(pane, ".")]
		sm := win + ".0"
		if sm != pane {
			nudgePaneStateAware(client, sess, rtDir, sm, *prompt, true)
		}
		// Nudge the Taskmaster (from session.env or default 1.0)
		tm := readTaskmasterPane(rtDir)
		if tm != pane && tm != sm {
			nudgePaneStateAware(client, sess, rtDir, tm, *prompt, true)
		}
	}
}

// resolvePane normalizes a pane argument to W.P format.
func resolvePane(raw string) string {
	pane := raw
	if idx := strings.LastIndex(pane, ":"); idx >= 0 {
		pane = pane[idx+1:]
	}
	if !strings.Contains(pane, ".") {
		if converted := safeToPaneID(pane); converted != "" {
			pane = converted
		}
	}
	return pane
}

// isUserPane returns true if the pane is in the DOEY_USER_PANES list (default: Boss 0.1).
func isUserPane(pane string) bool {
	userPanes := os.Getenv("DOEY_USER_PANES")
	if userPanes == "" {
		userPanes = "0.1"
	}
	for _, up := range strings.Split(userPanes, ",") {
		if strings.TrimSpace(up) == pane {
			return true
		}
	}
	return false
}

// readContextPct reads context % from the statusline-written file for a pane.
func readContextPct(rtDir, pane string) int {
	if rtDir == "" {
		return 0
	}
	// pane is "W.P" — file is context_pct_W_P
	safe := strings.ReplaceAll(pane, ".", "_")
	data, err := os.ReadFile(filepath.Join(rtDir, ctl.StatusSubdir, "context_pct_"+safe))
	if err != nil {
		return 0
	}
	s := strings.TrimSpace(string(data))
	// Strip any non-digit suffix (e.g. "72%")
	for i, c := range s {
		if c < '0' || c > '9' {
			s = s[:i]
			break
		}
	}
	n, _ := strconv.Atoi(s)
	return n
}

// readTaskmasterPane reads TASKMASTER_PANE from session.env (default 1.0).
func readTaskmasterPane(rtDir string) string {
	if rtDir == "" {
		return "1.0"
	}
	data, err := os.ReadFile(filepath.Join(rtDir, "session.env"))
	if err != nil {
		return "1.0"
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "TASKMASTER_PANE=") {
			v := strings.TrimPrefix(line, "TASKMASTER_PANE=")
			v = strings.Trim(v, "\"' ")
			if v != "" {
				return v
			}
		}
	}
	return "1.0"
}

// nudgePaneStateAware checks pane state before nudging. Skips user panes and
// BUSY panes. If context > 70%, sends /compact instead of the nudge text.
func nudgePaneStateAware(client *ctl.TmuxClient, sess, rtDir, pane, prompt string, verbose bool) {
	// Never nudge user-facing panes
	if isUserPane(pane) {
		if verbose {
			fmt.Fprintf(os.Stderr, "nudge: %s is a user pane — skipping\n", pane)
		}
		return
	}

	// Check status — skip BUSY panes
	if rtDir != "" {
		paneSafe := strings.NewReplacer(":", "_", "-", "_", ".", "_").Replace(sess + ":" + pane)
		entry, err := ctl.ReadStatus(rtDir, paneSafe)
		if err == nil && entry.Status == ctl.StatusBusy {
			if verbose {
				fmt.Fprintf(os.Stderr, "nudge: %s is BUSY — skipping\n", pane)
			}
			return
		}
	}

	// Check context % — send /compact instead if > 70%
	ctxPct := readContextPct(rtDir, pane)
	if ctxPct > 70 {
		if verbose {
			fmt.Fprintf(os.Stderr, "nudge: %s context at %d%% — sending /compact instead\n", pane, ctxPct)
		}
		_ = nudgePane(client, pane, "/compact", verbose)
		return
	}

	if err := nudgePane(client, pane, prompt, verbose); err != nil {
		if verbose {
			fmt.Fprintf(os.Stderr, "nudge: %s: %v\n", pane, err)
		}
	}
}

func nudgePane(client *ctl.TmuxClient, pane, prompt string, verbose bool) error {
	if verbose {
		fmt.Fprintf(os.Stderr, "Nudging %s... sending Escape... ", pane)
	}

	// Exit copy-mode / cancel current input
	if err := client.SendKeys(pane, "Escape"); err != nil {
		return fmt.Errorf("send Escape to %s: %w", pane, err)
	}

	if verbose {
		fmt.Fprintf(os.Stderr, "waiting... ")
	}
	time.Sleep(200 * time.Millisecond)

	if verbose {
		fmt.Fprintf(os.Stderr, "sending prompt... ")
	}
	if err := client.SendKeys(pane, prompt, "Enter"); err != nil {
		return fmt.Errorf("send prompt to %s: %w", pane, err)
	}

	if verbose {
		fmt.Fprintln(os.Stderr, "done")
	}
	return nil
}

func nudgeAll(client *ctl.TmuxClient, rtDir, prompt string) {
	statusDir := filepath.Join(rtDir, ctl.StatusSubdir)
	pattern := filepath.Join(statusDir, "*"+ctl.StatusExt)
	matches, err := filepath.Glob(pattern)
	if err != nil {
		fatal("nudge --all: glob: %v\n", err)
	}

	var nudged []string
	for _, path := range matches {
		base := strings.TrimSuffix(filepath.Base(path), ctl.StatusExt)
		entry, err := ctl.ReadStatus(rtDir, base)
		if err != nil {
			continue
		}
		// Skip panes that don't need nudging
		switch entry.Status {
		case ctl.StatusReady, ctl.StatusReserved:
			continue
		}

		paneTarget := safeToPaneID(base)
		if paneTarget == "" {
			continue
		}
		if isUserPane(paneTarget) {
			continue
		}

		// Context-aware: send /compact if context > 70%
		actualPrompt := prompt
		if ctxPct := readContextPct(rtDir, paneTarget); ctxPct > 70 {
			fmt.Fprintf(os.Stderr, "nudge: %s context at %d%% — sending /compact\n", paneTarget, ctxPct)
			actualPrompt = "/compact"
		}

		if err := nudgePane(client, paneTarget, actualPrompt, true); err != nil {
			fmt.Fprintf(os.Stderr, "nudge: skipping %s: %v\n", paneTarget, err)
			continue
		}
		nudged = append(nudged, paneTarget)
	}

	if jsonOutput {
		printJSON(map[string]any{"nudged": nudged, "count": len(nudged)})
	} else {
		if len(nudged) == 0 {
			fmt.Println("No panes needed nudging")
		} else {
			fmt.Printf("Nudged %d panes: %s\n", len(nudged), strings.Join(nudged, ", "))
		}
	}
}

// safeToPaneID converts a safe pane name like "doey_doey_3_1" to tmux pane
// format "3.1" by extracting the last two numeric underscore-separated segments.
func safeToPaneID(safe string) string {
	parts := strings.Split(safe, "_")
	if len(parts) < 2 {
		return ""
	}
	win := parts[len(parts)-2]
	pane := parts[len(parts)-1]
	// Verify both are numeric
	if _, err := strconv.Atoi(win); err != nil {
		return ""
	}
	if _, err := strconv.Atoi(pane); err != nil {
		return ""
	}
	return win + "." + pane
}

// runTmuxCmd dispatches tmux sub-subcommands.
func runTmuxCmd(args []string) {
	if len(args) == 0 {
		fatal("tmux: missing subcommand: panes, send, capture, env")
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
		fatal("tmux: unknown subcommand: %s", args[0])
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
	// Clear copy-mode before sending text
	_ = client.SendKeys(pane, "Escape")
	time.Sleep(200 * time.Millisecond)
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

func printTaskHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl task <subcommand> [flags]

Subcommands:
  create    Create a new task
  update    Update task fields
  list      List tasks
  get       Show task details
  delete    Delete a task
  subtask   Manage subtasks (add, update, list)
  log       Manage task log entries (add, list)
  decision  Add a decision log entry

Run 'doey-ctl task <subcommand> -h' for help.
`)
}

func printTaskSubtaskHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl task subtask <subcommand> [flags]

Subcommands:
  add       Add a subtask to a task
  update    Update a subtask's status or title
  list      List subtasks for a task

Run 'doey-ctl task subtask <subcommand> -h' for help.
`)
}

func printTaskLogHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl task log <subcommand> [flags]

Subcommands:
  add       Add a log entry to a task
  list      List log entries for a task

Run 'doey-ctl task log <subcommand> -h' for help.
`)
}
