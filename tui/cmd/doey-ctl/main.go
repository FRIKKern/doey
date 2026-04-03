package main

import (
	"encoding/json"
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

// jsonOutput controls whether output is JSON or human-readable.
var jsonOutput bool

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "msg":
		runMsgCmd(os.Args[2:])
	case "status":
		runStatusCmd(os.Args[2:])
	case "health":
		runHealthCmd(os.Args[2:])
	case "task":
		runTaskCmd(os.Args[2:])
	case "tmux":
		if len(os.Args) >= 3 && isHelp(os.Args[2]) {
			printTmuxHelp()
			return
		}
		runTmuxCmd(os.Args[2:])
	case "plan":
		runPlanCmd(os.Args[2:])
	case "team":
		runTeamCmd(os.Args[2:])
	case "config":
		runConfigCmd(os.Args[2:])
	case "agent":
		runAgentCmd(os.Args[2:])
	case "event":
		runEventCmd(os.Args[2:])
	case "nudge":
		runNudgeCmd(os.Args[2:])
	case "migrate":
		runMigrateCmd(os.Args[2:])
	case "--help", "-h", "help":
		printUsage()
	default:
		fatal("unknown command: %q. Valid: msg, status, health, task, tmux, plan, team, config, agent, event, nudge, migrate\nRun 'doey-ctl --help' for usage.\n", os.Args[1])
	}
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `doey-ctl — fast orchestration CLI for Doey

Usage: doey-ctl <command> [options]

Commands:
  msg      Send, read, and manage IPC messages (auto-detects DB)
  status   Get, set, and list pane statuses (auto-detects DB)
  health   Check pane liveness
  task     Manage project tasks
  tmux     Tmux session operations
  plan     Manage plans (list, get, create, update, delete)
  team     Manage teams (list, get, set)
  config   Manage config (get, set, list, delete)
  agent    Manage agents (list, get, set, delete)
  event    Log and list events
  nudge    Unstick Claude instances (Escape + re-prompt)
  migrate  Run database migrations

Environment:
  DOEY_RUNTIME   Runtime directory (default: /tmp/doey/<project>/)
  SESSION_NAME   Tmux session name

Flags:
  --json   Output JSON instead of human-readable text
  --help   Show this help
`)
}

// openStoreIfExists opens .doey/doey.db if it exists under dir.
// Returns (nil, nil) if the DB file does not exist — callers should fall back to file mode.
func openStoreIfExists(dir string) (*store.Store, error) {
	dbPath := filepath.Join(dir, ".doey", "doey.db")
	if _, err := os.Stat(dbPath); err != nil {
		return nil, nil
	}
	return store.Open(dbPath)
}

// --- msg subcommand ---

func runMsgCmd(args []string) {
	if len(args) < 1 {
		printMsgHelp()
		fatal("msg: missing subcommand: send, read, read-all, list, count, clean, trigger\nRun 'doey-ctl msg --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printMsgHelp()
		return
	}
	switch args[0] {
	case "send":
		msgSend(args[1:])
	case "read":
		msgRead(args[1:])
	case "list":
		msgList(args[1:])
	case "read-all":
		msgReadAll(args[1:])
	case "count":
		msgCount(args[1:])
	case "clean":
		msgClean(args[1:])
	case "trigger":
		msgTrigger(args[1:])
	default:
		fatal("msg: unknown subcommand: %q. Valid: send, read, read-all, list, count, clean, trigger\nRun 'doey-ctl msg --help' for usage.\n", args[0])
	}
}

func msgSend(args []string) {
	fs := flag.NewFlagSet("msg send", flag.ExitOnError)
	to := fs.String("to", "", "Target pane safe name")
	from := fs.String("from", "", "Sender identifier")
	subject := fs.String("subject", "", "Message subject")
	body := fs.String("body", "", "Message body")
	taskID := fs.Int64("task-id", 0, "Associated task ID (DB mode)")
	rt := fs.String("runtime", "", "Runtime directory")
	dir := fs.String("project-dir", "", "Project directory")
	noNudge := fs.Bool("no-nudge", false, "Skip tmux send-keys nudge to target pane")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *to == "" || *from == "" || *subject == "" {
		fatal("msg send: --to, --from, and --subject are required\nRun 'doey-ctl msg send -h' for usage.\n")
	}

	sentViaDB := false
	// Try DB first
	s, err := openStoreIfExists(projectDir(*dir))
	if err == nil && s != nil {
		defer s.Close()
		m := &store.Message{
			FromPane: *from,
			ToPane:   *to,
			Subject:  *subject,
			Body:     *body,
		}
		if *taskID != 0 {
			m.TaskID = taskID
		}
		if _, err := s.SendMessage(m); err != nil {
			fatal("msg send: db: %v\n", err)
		}
		sentViaDB = true
	}

	// Fall back to file if no DB
	if !sentViaDB {
		rtDir := runtimeDir(*rt)
		if err := ctl.WriteMsg(rtDir, *to, *from, *subject, *body); err != nil {
			fatal("msg send: %v\n", err)
		}
	}

	// Always fire trigger (wake mechanism) — best-effort
	if rtDir := runtimeDirOpt(*rt); rtDir != "" {
		_ = ctl.FireTrigger(rtDir, *to)
	}

	// Nudge target pane via tmux send-keys unless --no-nudge
	if !*noNudge {
		msgNudgePane(*to, runtimeDirOpt(*rt))
	}

	if jsonOutput {
		printJSON(map[string]string{"status": "sent", "to": *to})
	} else {
		fmt.Println("sent")
	}
}

func msgRead(args []string) {
	fs := flag.NewFlagSet("msg read", flag.ExitOnError)
	pane := fs.String("pane", "", "Pane safe name")
	rt := fs.String("runtime", "", "Runtime directory")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *pane == "" {
		fatal("msg read: --pane is required\nRun 'doey-ctl msg read -h' for usage.\n")
	}

	// Try DB first
	s, err := openStoreIfExists(projectDir(*dir))
	if err == nil && s != nil {
		defer s.Close()
		msgs, err := s.ListMessages(*pane, false)
		if err != nil {
			fatal("msg read: db: %v\n", err)
		}
		if jsonOutput {
			printJSON(msgs)
			return
		}
		for _, m := range msgs {
			read := " "
			if m.Read {
				read = "*"
			}
			fmt.Printf("id=%d from=%s subject=%s read=%s\n%s\n---\n", m.ID, m.FromPane, m.Subject, read, m.Body)
		}
		return
	}

	// Fall back to file
	msgs, err := ctl.ReadMsgs(runtimeDir(*rt), *pane)
	if err != nil {
		fatal("msg read: %v\n", err)
	}
	if jsonOutput {
		printJSON(msgs)
		return
	}
	for _, m := range msgs {
		fmt.Printf("from=%s subject=%s file=%s\n%s\n---\n", m.From, m.Subject, m.Filename, m.Body)
	}
}

func msgList(args []string) {
	fs := flag.NewFlagSet("msg list", flag.ExitOnError)
	to := fs.String("to", "", "Recipient pane (optional)")
	unread := fs.Bool("unread", false, "Only unread messages")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	s, err := openStoreIfExists(projectDir(*dir))
	if err != nil || s == nil {
		fatal("msg list: requires DB (.doey/doey.db)\n")
	}
	defer s.Close()

	msgs, err := s.ListMessages(*to, *unread)
	if err != nil {
		fatal("msg list: %v\n", err)
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

func msgReadAll(args []string) {
	fs := flag.NewFlagSet("msg read-all", flag.ExitOnError)
	to := fs.String("to", "", "Recipient pane (required)")
	pane := fs.String("pane", "", "Recipient pane (alias for --to)")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	// --pane is an alias for --to
	if *to == "" && *pane != "" {
		*to = *pane
	}

	if *to == "" {
		fatal("msg read-all: --to (or --pane) is required\nRun 'doey-ctl msg read-all -h' for usage.\n")
	}

	s, err := openStoreIfExists(projectDir(*dir))
	if err != nil || s == nil {
		fatal("msg read-all: requires DB (.doey/doey.db)\n")
	}
	defer s.Close()

	if err := s.MarkAllRead(*to); err != nil {
		fatal("msg read-all: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "read-all", "to": *to})
	} else {
		fmt.Println("read-all")
	}
}

func msgCount(args []string) {
	fs := flag.NewFlagSet("msg count", flag.ExitOnError)
	to := fs.String("to", "", "Recipient pane (required)")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *to == "" {
		fatal("msg count: --to is required\nRun 'doey-ctl msg count -h' for usage.\n")
	}

	s, err := openStoreIfExists(projectDir(*dir))
	if err != nil || s == nil {
		fatal("msg count: requires DB (.doey/doey.db)\n")
	}
	defer s.Close()

	count, err := s.CountUnread(*to)
	if err != nil {
		fatal("msg count: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]int{"unread": count})
	} else {
		fmt.Println(count)
	}
}

func msgClean(args []string) {
	fs := flag.NewFlagSet("msg clean", flag.ExitOnError)
	pane := fs.String("pane", "", "Pane safe name")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *pane == "" {
		fatal("msg clean: --pane is required\nRun 'doey-ctl msg clean -h' for usage.\n")
	}
	if err := ctl.CleanupMsgs(runtimeDir(*rt), *pane); err != nil {
		fatal("msg clean: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "cleaned", "pane": *pane})
	} else {
		fmt.Println("cleaned")
	}
}

func msgTrigger(args []string) {
	fs := flag.NewFlagSet("msg trigger", flag.ExitOnError)
	pane := fs.String("pane", "", "Pane safe name")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *pane == "" {
		fatal("msg trigger: --pane is required\nRun 'doey-ctl msg trigger -h' for usage.\n")
	}
	rtDir := runtimeDir(*rt)
	if err := ctl.FireTrigger(rtDir, *pane); err != nil {
		fatal("msg trigger: %v\n", err)
	}
	// Also nudge via send-keys
	msgNudgePane(*pane, rtDir)
	if jsonOutput {
		printJSON(map[string]string{"status": "triggered", "pane": *pane})
	} else {
		fmt.Println("triggered")
	}
}

// msgNudgePane resolves the target pane and sends a tmux send-keys nudge
// so the recipient processes the message immediately. Skips if BUSY.
// Best-effort: errors are silently ignored.
func msgNudgePane(targetPane, rtDir string) {
	// Resolve session name
	session := os.Getenv("DOEY_SESSION")
	if session == "" {
		session = os.Getenv("SESSION_NAME")
	}
	if session == "" {
		return // can't nudge without a session
	}

	// Resolve pane ID: convert safe name (doey_doey_3_1) to W.P format if needed
	paneID := targetPane
	if strings.Contains(paneID, ":") {
		// Strip session prefix (e.g. "doey-doey:3.1" → "3.1")
		paneID = paneID[strings.LastIndex(paneID, ":")+1:]
	}
	if !strings.Contains(paneID, ".") {
		if converted := safeToPaneID(paneID); converted != "" {
			paneID = converted
		} else {
			return // can't resolve pane
		}
	}

	// Check if BUSY — skip nudge if so
	if rtDir != "" {
		// Build safe name for status file lookup
		paneSafe := strings.NewReplacer(":", "_", "-", "_", ".", "_").Replace(session + ":" + paneID)
		entry, err := ctl.ReadStatus(rtDir, paneSafe)
		if err == nil && entry.Status == ctl.StatusBusy {
			return
		}
	}

	// Nudge via existing nudgePane (uses TmuxClient send-keys)
	client := ctl.NewTmuxClient(session)
	prompt := fmt.Sprintf("Check your messages — run: doey-ctl msg read --pane %s", targetPane)
	_ = nudgePane(client, paneID, prompt, false)
}

// --- status subcommand ---

func runStatusCmd(args []string) {
	if len(args) < 1 {
		printStatusHelp()
		fatal("status: missing subcommand: get, set, list\nRun 'doey-ctl status --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printStatusHelp()
		return
	}
	switch args[0] {
	case "get":
		statusGet(args[1:])
	case "set":
		statusSet(args[1:])
	case "list":
		statusList(args[1:])
	default:
		fatal("status: unknown subcommand: %q. Valid: get, set, list\nRun 'doey-ctl status --help' for usage.\n", args[0])
	}
}

func statusGet(args []string) {
	fs := flag.NewFlagSet("status get", flag.ExitOnError)
	rt := fs.String("runtime", "", "Runtime directory")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("status get: <pane> argument required\nRun 'doey-ctl status get -h' for usage.\n")
	}
	pane := fs.Arg(0)

	// Try DB first
	s, err := openStoreIfExists(projectDir(*dir))
	if err == nil && s != nil {
		defer s.Close()
		ps, err := s.GetPaneStatus(pane)
		if err == nil {
			if jsonOutput {
				printJSON(ps)
			} else {
				fmt.Printf("pane_id=%s window_id=%s role=%s status=%s agent=%s updated_at=%d\n",
					ps.PaneID, ps.WindowID, ps.Role, ps.Status, ps.Agent, ps.UpdatedAt)
			}
			return
		}
		// DB didn't have this pane — fall through to file
	}

	// Fall back to file
	entry, err := ctl.ReadStatus(runtimeDir(*rt), pane)
	if err != nil {
		fatal("status get: %v\n", err)
	}
	if jsonOutput {
		printJSON(entry)
		return
	}
	fmt.Printf("pane=%s\nstatus=%s\ntask=%s\nupdated=%s\nstale=%v\n",
		entry.Pane, entry.Status, entry.Task, entry.Updated, entry.IsStale)
}

func statusSet(args []string) {
	fs := flag.NewFlagSet("status set", flag.ExitOnError)
	pane := fs.String("pane", "", "Pane ID (e.g. W1.2)")
	// Also accept --pane-id for backward compat with db-status callers
	paneID := fs.String("pane-id", "", "Pane ID (alias for --pane)")
	status := fs.String("status", "", "Status value")
	task := fs.String("task", "", "Current task description")
	taskTitle := fs.String("task-title", "", "Task title (alias for --task)")
	role := fs.String("role", "", "Pane role (DB mode)")
	agent := fs.String("agent", "", "Agent name (DB mode)")
	windowID := fs.String("window-id", "", "Window ID (DB mode)")
	taskIDFlag := fs.Int64("task-id", 0, "Task ID (DB mode)")
	rt := fs.String("runtime", "", "Runtime directory")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	// Merge --pane-id into --pane for backward compat
	if *pane == "" && *paneID != "" {
		*pane = *paneID
	}
	// Merge --task-title into --task
	if *task == "" && *taskTitle != "" {
		*task = *taskTitle
	}

	// Accept positional args as fallback: status set <pane> <status>
	if *pane == "" && fs.NArg() >= 1 {
		*pane = fs.Arg(0)
	}
	if *status == "" && fs.NArg() >= 2 {
		*status = fs.Arg(1)
	}

	if *pane == "" || *status == "" {
		fatal("status set: --pane and --status are required\nRun 'doey-ctl status set -h' for usage.\n")
	}

	// Try DB
	s, err := openStoreIfExists(projectDir(*dir))
	if err == nil && s != nil {
		defer s.Close()
		wid := *windowID
		if wid == "" {
			wid = windowFromPaneID(*pane)
		}
		ps := &store.PaneStatus{
			PaneID:    *pane,
			WindowID:  wid,
			Role:      *role,
			Status:    *status,
			TaskTitle: *task,
			Agent:     *agent,
		}
		if *taskIDFlag != 0 {
			ps.TaskID = taskIDFlag
		}
		if err := s.UpsertPaneStatus(ps); err != nil {
			fatal("status set: db: %v\n", err)
		}
	}

	// Always write-through to file (tmux border scripts depend on this)
	if err := ctl.WriteStatus(runtimeDir(*rt), *pane, *pane, *status, *task); err != nil {
		fatal("status set: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "written", "pane": *pane, "value": *status})
	} else {
		fmt.Println("written")
	}
}

func statusList(args []string) {
	fs := flag.NewFlagSet("status list", flag.ExitOnError)
	window := fs.Int("window", -1, "Window index")
	windowIDFlag := fs.String("window-id", "", "Window ID (DB mode, overrides --window)")
	rt := fs.String("runtime", "", "Runtime directory")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	// Try DB first
	s, err := openStoreIfExists(projectDir(*dir))
	if err == nil && s != nil {
		defer s.Close()
		wid := *windowIDFlag
		if wid == "" && *window >= 0 {
			wid = strconv.Itoa(*window)
		}
		statuses, err := s.ListPaneStatuses(wid)
		if err != nil {
			fatal("status list: db: %v\n", err)
		}
		if jsonOutput {
			printJSON(statuses)
			return
		}
		for _, ps := range statuses {
			fmt.Printf("%-12s %-10s %-10s %-30s %d\n",
				ps.PaneID, ps.Role, ps.Status, ps.TaskTitle, ps.UpdatedAt)
		}
		return
	}

	// Fall back to file
	if *window < 0 {
		fatal("status list: --window is required\nRun 'doey-ctl status list -h' for usage.\n")
	}
	entries, err := ctl.ListStatuses(runtimeDir(*rt), *window)
	if err != nil {
		fatal("status list: %v\n", err)
	}
	if jsonOutput {
		printJSON(entries)
		return
	}
	for _, e := range entries {
		fmt.Printf("%-12s %-10s %-30s %s\n", e.Pane, e.Status, e.Task, e.Updated)
	}
}

// --- health subcommand ---

func runHealthCmd(args []string) {
	if len(args) < 1 {
		printHealthHelp()
		fatal("health: missing subcommand: check\nRun 'doey-ctl health --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printHealthHelp()
		return
	}
	switch args[0] {
	case "check":
		healthCheck(args[1:])
	default:
		fatal("health: unknown subcommand: %q. Valid: check\nRun 'doey-ctl health --help' for usage.\n", args[0])
	}
}

func healthCheck(args []string) {
	fs := flag.NewFlagSet("health check", flag.ExitOnError)
	staleness := fs.String("staleness", "120s", "Staleness threshold (e.g. 120s, 2m)")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("health check: <pane_safe> argument required\nRun 'doey-ctl health check -h' for usage.\n")
	}
	paneSafe := fs.Arg(0)

	dur, err := time.ParseDuration(*staleness)
	if err != nil {
		fatal("health check: invalid staleness %q: %v\n", *staleness, err)
	}

	alive, err := ctl.IsAlive(runtimeDir(*rt), paneSafe, dur)
	if err != nil {
		fatal("health check: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]any{"pane": paneSafe, "alive": alive})
	} else if alive {
		fmt.Println("alive")
	} else {
		fmt.Println("stale")
	}

	if !alive {
		os.Exit(1)
	}
}

// --- shared helpers (used by commands.go too) ---

// runtimeDir returns the runtime directory from a flag value or DOEY_RUNTIME env.
func runtimeDir(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if v := os.Getenv("DOEY_RUNTIME"); v != "" {
		return v
	}
	fatal("runtime dir not set: use --runtime or DOEY_RUNTIME env\n")
	return ""
}

// runtimeDirOpt returns the runtime directory or empty string if not available (no fatal).
func runtimeDirOpt(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	return os.Getenv("DOEY_RUNTIME")
}

// sessionName returns the tmux session name from a flag value or SESSION_NAME env.
func sessionName(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if v := os.Getenv("SESSION_NAME"); v != "" {
		return v
	}
	fatal("session name not set: use --session or SESSION_NAME env\n")
	return ""
}

// projectDir returns the project directory from a flag or the current working dir.
func projectDir(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	dir, err := os.Getwd()
	if err != nil {
		fatal("project dir: %v\n", err)
	}
	return dir
}

// fatal prints an error to stderr and exits with code 1.
func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "doey-ctl: "+format, args...)
	os.Exit(1)
}

// printJSON marshals v to JSON and prints to stdout.
func printJSON(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		fatal("json encode: %v\n", err)
	}
}

// atoiOrFatal parses a string to int or calls fatal.
func atoiOrFatal(s, label string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		fatal("%s: invalid integer %q\n", label, s)
	}
	return n
}

// isHelp returns true if the argument is a help flag or the word "help".
func isHelp(arg string) bool {
	return arg == "--help" || arg == "-h" || arg == "-help" || arg == "help"
}

// printTmuxHelp prints help for the tmux subcommand.
func printTmuxHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl tmux <subcommand> [options]

Subcommands:
  panes    List panes in a window
  send     Send keys to a pane
  capture  Capture pane output
  env      Read tmux environment variable

Run 'doey-ctl tmux <subcommand> -h' for help.
`)
}

func printMsgHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl msg <subcommand> [flags]

Subcommands:
  send      Send a message between panes
  read      Read messages for a pane
  read-all  Read all messages for a pane (mark as read)
  list      List messages (DB mode)
  count     Count unread messages
  clean     Clean processed messages
  trigger   Touch trigger file for pane

Run 'doey-ctl msg <subcommand> -h' for help.
`)
}

func printStatusHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl status <subcommand> [flags]

Subcommands:
  get   Get status for a pane
  set   Set status for a pane
  list  List statuses for a window

Run 'doey-ctl status <subcommand> -h' for help.
`)
}

func printHealthHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl health <subcommand> [flags]

Subcommands:
  check  Check if a pane is alive (not stale)

Run 'doey-ctl health <subcommand> -h' for help.
`)
}
